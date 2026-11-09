import 'dart:io';
import 'package:anx_reader/service/chatgpt/secure_transport.dart';
Future<void> main() async {
 final client=HttpClient()..connectionTimeout=const Duration(seconds:30);
 client.connectionFactory=(u,p,pp)=>chatGptConnection(u,p,pp,connectNormally:(_,__)async{throw const SocketException('Forced resolver/network failure before HTTP');});
 try {final response=await(await client.getUrl(Uri.parse('https://auth.openai.com/.well-known/openid-configuration'))).close();
 print('forced fallback HTTPS status: ${response.statusCode}');await response.drain<void>();
 }finally{client.close(force:true);}
}
