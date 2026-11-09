package com.anxcye.anx_reader

import android.app.Activity
import android.os.Bundle
import android.webkit.WebView
import android.webkit.WebViewClient
import android.webkit.WebResourceRequest
import android.widget.Button
import android.widget.LinearLayout
import java.net.URI

/** Interactive first-party sign-in. No reader APIs or JavaScript interfaces are exposed here. */
class ReaderExtensionAuthActivity : Activity() {
    private var web: WebView? = null
    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        val origins = intent.getStringArrayExtra("origins")?.toSet() ?: emptySet()
        val url = intent.getStringExtra("url") ?: return finish()
        fun allowed(value: String): Boolean = try {
            val uri = URI(value)
            uri.scheme == "https" && uri.rawUserInfo == null &&
                origins.contains("https://${uri.host}" + if (uri.port != -1 && uri.port != 443) ":${uri.port}" else "")
        } catch (_: Exception) { false }
        if (!allowed(url)) return finish()
        val layout = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
        layout.addView(Button(this).apply { text = "Done — return to Anx"; setOnClickListener { finish() } })
        val view = WebView(this)
        web = view
        view.settings.apply {
            javaScriptEnabled = true; domStorageEnabled = true
            allowFileAccess = false; allowContentAccess = false
            userAgentString = USER_AGENT
        }
        view.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                !allowed(request.url.toString())
        }
        layout.addView(view, LinearLayout.LayoutParams(-1, 0, 1f))
        setContentView(layout)
        view.loadUrl(url)
    }
    override fun onDestroy() { web?.destroy(); web = null; super.onDestroy() }
    companion object {
        const val USER_AGENT = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36"
    }
}
