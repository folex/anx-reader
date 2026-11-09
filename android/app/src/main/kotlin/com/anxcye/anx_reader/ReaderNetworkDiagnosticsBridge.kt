package com.anxcye.anx_reader

import android.Manifest
import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.system.ErrnoException
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.URL
import java.net.UnknownHostException
import java.net.SocketTimeoutException
import java.util.concurrent.Executors
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLException

/** Anonymous fixed endpoint only; never receives or prints credentials/addresses. */
class ReaderNetworkDiagnosticsBridge(activity: Activity, engine: FlutterEngine) {
    private val context=activity.applicationContext
    private val channel=MethodChannel(engine.dartExecutor.binaryMessenger,"com.anxcye.anx_reader/network_diagnostics")
    private val main=Handler(Looper.getMainLooper())
    private val workers=Executors.newFixedThreadPool(3)
    private var running=false
    private var closed=false
    init {
        channel.setMethodCallHandler { call,result ->
            if(call.method!="probe") { result.notImplemented(); return@setMethodCallHandler }
            if(running||closed) {result.error("BUSY","Diagnostics unavailable",null);return@setMethodCallHandler}
            running=true
            val output=java.util.concurrent.ConcurrentHashMap<String,String>()
            val dns=workers.submit { output["native.dns"]=try{
                val addresses=InetAddress.getAllByName("auth.openai.com")
                "ok v4=${addresses.count { it is Inet4Address }} v6=${addresses.count { it is Inet6Address }}"
            }catch(error:Exception){safeError(error)} }
            val https=workers.submit { output["native.https"]=https("https://auth.openai.com/.well-known/openid-configuration") }
            val control=workers.submit { output["native.control"]=https("https://connectivitycheck.gstatic.com/generate_204") }
            val deadline=System.currentTimeMillis()+8500
            fun finish() {
                if(closed)return
                if((dns.isDone&&https.isDone&&control.isDone)||System.currentTimeMillis()>=deadline){
                    if(!dns.isDone){dns.cancel(true);output["native.dns"]="timeout"}
                    if(!https.isDone){https.cancel(true);output["native.https"]="timeout"}
                    if(!control.isDone){control.cancel(true);output["native.control"]="timeout"}
                    networkInfo(output)
                    running=false;result.success(HashMap(output))
                }else main.postDelayed({finish()},100)
            }
            finish()
        }
    }
    private fun https(endpoint:String):String {
        var connection:HttpsURLConnection?=null
        return try{
            connection=URL(endpoint).openConnection() as HttpsURLConnection
            connection.connectTimeout=4000;connection.readTimeout=4000;connection.instanceFollowRedirects=false
            connection.requestMethod="GET"
            "http_${connection.responseCode}"
        }catch(error:Exception){safeError(error)}finally{connection?.disconnect()}
    }
    private fun networkInfo(out:MutableMap<String,String>) {
        if(Build.VERSION.SDK_INT>=28) {
            try { val manager=context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
              out["native.appBackgroundRestricted"]=if(manager.isBackgroundRestricted)"yes" else "no"
            } catch(_:Exception) {out["native.appBackgroundRestricted"]="unknown"}
        }
        if(context.checkSelfPermission(Manifest.permission.ACCESS_NETWORK_STATE)!=PackageManager.PERMISSION_GRANTED){out["native.accessNetworkState"]="denied";return}
        out["native.accessNetworkState"]="ok"
        try{
            val manager=context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val network=manager.activeNetwork
            out["native.network"]=if(network==null)"none" else "ok"
            val caps=manager.getNetworkCapabilities(network)
            out["native.internet"]=if(caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)==true)"yes" else "no"
            out["native.validated"]=if(caps?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)==true)"yes" else "no"
            out["native.vpn"]=if(caps?.hasTransport(NetworkCapabilities.TRANSPORT_VPN)==true)"yes" else "no"
            out["native.metered"]=if(manager.isActiveNetworkMetered)"yes" else "no"
            if(Build.VERSION.SDK_INT>=24) out["native.background"]=when(manager.restrictBackgroundStatus){
                ConnectivityManager.RESTRICT_BACKGROUND_STATUS_ENABLED->"enabled"
                ConnectivityManager.RESTRICT_BACKGROUND_STATUS_WHITELISTED->"whitelisted"
                ConnectivityManager.RESTRICT_BACKGROUND_STATUS_DISABLED->"disabled"
                else->"unknown"
            }
        }catch(_:SecurityException){out["native.accessNetworkState"]="denied"}catch(_:Exception){out["native.network"]="unknown"}
    }
    private fun safeError(error:Exception):String {
        if(error is UnknownHostException)return "dns"
        if(error is SocketTimeoutException)return "timeout"
        if(error is SSLException)return "tls"
        var cause:Throwable?=error
        repeat(5){ if(cause is ErrnoException)return "socket errno=${(cause as ErrnoException).errno}";cause=cause?.cause }
        return "connect"
    }
    fun close(){closed=true;main.removeCallbacksAndMessages(null);workers.shutdownNow();channel.setMethodCallHandler(null)}
}
