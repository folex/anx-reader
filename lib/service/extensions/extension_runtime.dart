import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'extension_manager.dart';
import 'extension_package.dart';

const extensionChannel = MethodChannel('com.anxcye.anx_reader/extensions');
typedef ExtensionReaderCall = Future<Object?> Function(
    String method, Map<String, dynamic> arguments);

/// A new isolated WebView for each invocation. Direct WebView networking and
/// filesystem access are disabled; every host capability goes through dispatch.
class ExtensionRuntime {
  Future<Object?> invoke(
      ReaderExtension extension, String tool, Map<String, dynamic> arguments,
      {required ExtensionReaderCall reader,
      required bool Function() isCurrent}) async {
    if (!Platform.isAndroid) {
      throw StateError('Extensions currently require Android');
    }
    final manager = ExtensionManager.instance;
    final revision = manager.revision;
    final ready = Completer<InAppWebViewController>();
    final output = Completer<Object?>();
    void guard() {
      if (!isCurrent() ||
          manager.revision != revision ||
          manager.installed[extension.id] != extension) {
        throw StateError(
            'Extension invocation canceled or permissions changed');
      }
    }

    final web = HeadlessInAppWebView(
      initialData: InAppWebViewInitialData(
          data: '<!doctype html><meta charset="utf-8">'),
      initialSettings: InAppWebViewSettings(
          javaScriptEnabled: true,
          blockNetworkLoads: true,
          allowFileAccess: false,
          allowContentAccess: false,
          allowFileAccessFromFileURLs: false,
          allowUniversalAccessFromFileURLs: false,
          isInspectable: false,
          javaScriptCanOpenWindowsAutomatically: false,
          useShouldOverrideUrlLoading: true,
          useShouldInterceptRequest: true),
      shouldOverrideUrlLoading: (_, action) async =>
          NavigationActionPolicy.CANCEL,
      shouldInterceptRequest: (_, request) async => WebResourceResponse(
          statusCode: 403,
          reasonPhrase: 'Forbidden',
          contentType: 'text/plain'),
      onConsoleMessage: (_, message) {
        if (message.message.contains('SyntaxError') && !output.isCompleted) {
          output.completeError(StateError(
              'Extension JavaScript is incompatible with this WebView'));
        }
      },
      onWebViewCreated: (controller) {
        controller.addJavaScriptHandler(
            handlerName: 'extensionApi',
            callback: (args) async {
              try {
                guard();
                if (args.length != 2 || args[0] is! String || args[1] is! Map) {
                  throw const FormatException('Invalid extension API request');
                }
                final method = args[0] as String;
                final input = Map<String, dynamic>.from(args[1]);
                Object? value;
                if (method.startsWith('reader.')) {
                  requireExtensionPermission(
                      extension,
                      manager.grants[extension.id] ?? {},
                      method == 'reader.edit' ? 'books.write' : 'books.read');
                  value = await reader(method, input);
                } else if (method == 'network.request' ||
                    method == 'files.download') {
                  final url = input['url'];
                  if (url is! String) {
                    throw const FormatException('URL required');
                  }
                  requireExtensionPermission(
                      extension, manager.grants[extension.id] ?? {}, 'network',
                      url: url);
                  value = await extensionChannel.invokeMethod(
                      method == 'files.download' ? 'download' : 'request', {
                    'extensionId': extension.id,
                    'origins': extension.origins,
                    'url': url,
                    'method': input['method'] ?? 'GET',
                    'body': input['body'],
                    'filename': input['filename'],
                    'sessionScope': input['sessionScope'],
                  });
                } else if (method == 'storage.get') {
                  value = await manager.readValue(
                      extension.id, input['key'] as String);
                } else if (method == 'storage.claim') {
                  value = await manager.claimValue(
                      extension.id, input['key'] as String, input['value']);
                } else if (method == 'storage.set') {
                  await manager.writeValue(
                      extension.id, input['key'] as String, input['value']);
                  value = true;
                } else {
                  throw StateError('Unknown extension API method');
                }
                guard();
                return {'ok': true, 'value': value};
              } catch (error) {
                return {
                  'ok': false,
                  'error': error is PlatformException
                      ? 'Google connection failed. Check connection or sign in again.'
                      : error.toString()
                };
              }
            });
        controller.addJavaScriptHandler(
            handlerName: 'extensionResult',
            callback: (args) {
              if (output.isCompleted || args.isEmpty) return null;
              try {
                guard();
                final data = Map<String, dynamic>.from(args.first as Map);
                if (data['ok'] != true) {
                  throw StateError(
                      data['error']?.toString() ?? 'Extension failed');
                }
                final value = data['value'];
                if (utf8.encode(jsonEncode(value)).length > 100 * 1024) {
                  throw StateError('Extension result exceeds 100 KB');
                }
                output.complete(value);
              } catch (error, stack) {
                output.completeError(error, stack);
              }
              return null;
            });
      },
      onLoadStop: (controller, _) {
        if (!ready.isCompleted) ready.complete(controller);
      },
    );
    // Attach immediately, even if initialization fails before we await output.
    unawaited(output.future
        .then<void>((_) {}, onError: (Object _, StackTrace __) {}));
    try {
      guard();
      await web.run();
      final controller =
          await ready.future.timeout(const Duration(seconds: 15));
      final source = '''(() => {
        for (const name of ['fetch','XMLHttpRequest','WebSocket','EventSource','Worker','SharedWorker','RTCPeerConnection','webkitRTCPeerConnection']) {
          Object.defineProperty(globalThis,name,{value:undefined,writable:false,configurable:false});
        }
        const module = {exports:{}};
        const api = Object.freeze({call: async (method, args = {}) => {
          const response = await window.flutter_inappwebview.callHandler('extensionApi', method, args);
          if (!response.ok) throw new Error(response.error);
          return response.value;
        }});
        try {
          (function(module) { ${extension.script}\n })(module);
          Promise.resolve(module.exports.invoke(${jsonEncode(tool)}, ${jsonEncode(arguments)}, api))
            .then(value => window.flutter_inappwebview.callHandler('extensionResult', {ok:true,value}))
            .catch(error => window.flutter_inappwebview.callHandler('extensionResult', {ok:false,error:String(error)}));
        } catch(error) {
          window.flutter_inappwebview.callHandler('extensionResult', {ok:false,error:String(error)});
        }
      })()''';
      await controller.evaluateJavascript(source: source);
      return await output.future.timeout(const Duration(minutes: 3));
    } finally {
      await web.dispose();
    }
  }
}

Future<void> openExtensionSignIn(ReaderExtension extension) async {
  final manager = ExtensionManager.instance;
  requireExtensionPermission(
      extension, manager.grants[extension.id] ?? {}, 'ui');
  final url = extension.manifest['authUrl'] as String?;
  if (url == null) {
    throw StateError('Extension does not declare a sign-in page');
  }
  requireExtensionPermission(
      extension, manager.grants[extension.id] ?? {}, 'network',
      url: url);
  await extensionChannel
      .invokeMethod('signIn', {'url': url, 'origins': extension.authOrigins});
}
