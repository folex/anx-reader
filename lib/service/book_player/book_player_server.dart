import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as io;

class Server {
  static final Server _singleton = Server._internal();

  factory Server() {
    return _singleton;
  }

  Server._internal();

  HttpServer? _server;
  final String _accessToken = List<int>.generate(
    32,
    (_) => Random.secure().nextInt(256),
  ).map((v) => v.toRadixString(16).padLeft(2, '0')).join();

  String get baseUrl => 'http://127.0.0.1:$port/$_accessToken';

  Future start() async {
    if (_server != null) {
      AnxLog.info(
        'Server: Existing instance detected on port ${_server?.port}, restarting',
      );
      await stop();
    }

    final handler = const shelf.Pipeline().addHandler(_authorizeRequests);

    int port = Prefs().lastServerPort;

    try {
      _server = await io.serve(handler, '127.0.0.1', port);
    } catch (e, s) {
      AnxLog.warning(
        'Server: Failed to bind to port $port, trying random port $e',
        s,
      );
      _server = await io.serve(handler, '127.0.0.1', 0);
    }

    Prefs().lastServerPort = _server!.port;
    AnxLog.info(
      'Server: Serving at http://${_server?.address.host}:${_server?.port}',
    );
  }

  int get port {
    return _server!.port;
  }

  Future stop() async {
    if (_server == null) {
      return;
    }
    final stoppedPort = _server!.port;
    await _server?.close(force: true);
    _server = null;
    AnxLog.info('Server: Server stopped (port $stoppedPort)');
  }

  Future<String> _loadAsset(String path) async {
    return await rootBundle.loadString(path);
  }

  File? _tempFile;
  String? _tempFileName;

  String setTempFile(File file) {
    _tempFile = file;
    _tempFileName =
        '${DateTime.now().millisecondsSinceEpoch}.${file.path.split('.').last}';
    return _tempFileName!;
  }

  Future<shelf.Response> _authorizeRequests(shelf.Request request) async {
    if (request.requestedUri.host != '127.0.0.1' ||
        request.url.pathSegments.isEmpty ||
        request.url.pathSegments.first != _accessToken) {
      return shelf.Response.notFound('Not found');
    }
    if (request.method != 'GET' && request.method != 'HEAD') {
      return shelf.Response(405);
    }
    try {
      final response = await _handleRequests(
        request.change(path: _accessToken),
      );
      return shelf.Response(
        response.statusCode,
        body: response.read(),
        context: response.context,
        headers:
            {
              ...response.headers,
              'Referrer-Policy': 'no-referrer',
              'X-Content-Type-Options': 'nosniff',
            }..removeWhere(
              (key, _) => key.toLowerCase() == 'access-control-allow-origin',
            ),
      );
    } on FileSystemException {
      return shelf.Response.notFound('Not found');
    } on FormatException {
      return shelf.Response(400);
    }
  }

  File? _containedFile(Directory directory, String candidate) {
    try {
      final root = directory.resolveSymbolicLinksSync();
      final resolved = File(candidate).resolveSymbolicLinksSync();
      if (!path.isWithin(root, resolved)) return null;
      return File(resolved);
    } on FileSystemException {
      return null;
    }
  }

  Future<shelf.Response> _handleRequests(shelf.Request request) async {
    final uriPath = '/${request.url.path}';

    if (_tempFileName != null && uriPath == "/${_tempFileName!}") {
      return shelf.Response.ok(
        _tempFile?.openRead(),
        headers: {
          'Content-Type': 'application/epub+zip',
          'Access-Control-Allow-Origin': '*',
        },
      );
    }

    if (uriPath.startsWith('/book/')) {
      return _handleBookRequest(request);
    } else if (uriPath.startsWith('/js/')) {
      String content = await _loadAsset('assets/js/${path.basename(uriPath)}');
      return shelf.Response.ok(
        content,
        headers: {'Content-Type': 'application/javascript'},
      );
    } else if (uriPath.startsWith('/fonts/')) {
      Directory fontDir = getFontDir();
      final file = File(
        '${fontDir.path}/${path.basename(Uri.decodeComponent(uriPath))}',
      );
      if (!file.existsSync()) {
        return shelf.Response.notFound('Font not found');
      }
      return shelf.Response.ok(
        file.openRead(),
        headers: {
          'Content-Type': 'font/opentype',
          'Access-Control-Allow-Origin': '*',
          'cache-control': 'public, max-age=31536000',
        },
      );
    } else if (uriPath.startsWith('/foliate-js/')) {
      if (uriPath.endsWith('.epub')) {
        final file = await rootBundle.load(
          'assets/foliate-js/${uriPath.substring(12)}',
        );
        return shelf.Response.ok(
          file.buffer.asUint8List(),
          headers: {
            'Content-Type': 'application/epub+zip',
            'Access-Control-Allow-Origin': '*', // Add this line
          },
        );
      }
      String content = await _loadAsset(
        'assets/foliate-js/${uriPath.substring(12)}',
      );

      // Determine content type based on file extension
      String contentType;
      if (uriPath.endsWith('.html')) {
        contentType = 'text/html';
      } else if (uriPath.endsWith('.css')) {
        contentType = 'text/css';
      } else if (uriPath.endsWith('.js')) {
        contentType = 'application/javascript';
      } else if (uriPath.endsWith('.json')) {
        contentType = 'application/json';
      } else {
        contentType = 'application/octet-stream';
      }

      return shelf.Response.ok(content, headers: {'Content-Type': contentType});
    } else if (uriPath.startsWith('/bgimg/')) {
      return await _handleBgimgRequest(request);
    } else {
      return shelf.Response.ok(
        'Request for "${request.url}"',
        headers: {'Access-Control-Allow-Origin': '*'},
      );
    }
  }

  shelf.Response _handleBookRequest(shelf.Request request) {
    final bookPath = Uri.decodeComponent(request.url.path.substring(5));
    final file = _containedFile(getFileDir(), bookPath);
    if (file == null || !file.existsSync()) {
      return shelf.Response.notFound('Book not found');
    }
    final headers = {
      'Content-Type': 'application/epub+zip',
      'Access-Control-Allow-Origin': '*',
      'Cache-Control': 'no-store',
    };
    return shelf.Response.ok(file.openRead(), headers: headers);
  }

  Future<shelf.Response> _handleBgimgRequest(shelf.Request request) async {
    final bgimgPath = Uri.decodeComponent(request.url.path.substring(6));
    ByteBuffer? file;
    if (bgimgPath.startsWith('assets/')) {
      file = (await rootBundle.load(bgimgPath.substring(7))).buffer;
    } else if (bgimgPath.startsWith('local/')) {
      final imagePath =
          getBgimgDir().path + Platform.pathSeparator + bgimgPath.substring(6);
      final image = _containedFile(getBgimgDir(), imagePath);
      if (image == null) return shelf.Response.notFound('Bgimg not found');
      file = (await image.readAsBytes()).buffer;
    } else {
      return shelf.Response.notFound('Bgimg not found');
    }
    final headers = {
      'Content-Type': 'image/png',
      'Access-Control-Allow-Origin': '*',
    };
    return shelf.Response.ok(file.asUint8List(), headers: headers);
  }
}
