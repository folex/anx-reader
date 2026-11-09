import 'dart:io';
import 'dart:convert';

import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/service/book_player/book_player_server.dart';
import 'package:anx_reader/utils/get_path/get_base_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class NetworkTestBinding extends AutomatedTestWidgetsFlutterBinding {
  @override
  bool get overrideHttpClient => false;
}

void main() {
  NetworkTestBinding();
  late Directory root;
  late HttpClient client;
  late File book;
  late File secret;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    root = await Directory.systemTemp.createTemp('anx-security-');
    documentPath = root.path;
    getFileDir().createSync(recursive: true);
    getBgimgDir().createSync(recursive: true);
    book = File('${getFileDir().path}/book.epub')..writeAsStringSync('book-data');
    secret = File('${root.path}/private-settings')..writeAsStringSync('secret-key');
    await Server().start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await Server().stop();
    await root.delete(recursive: true);
  });

  Future<HttpClientResponse> get(String url) async =>
      (await client.getUrl(Uri.parse(url))).close();

  test('unauthenticated localhost cannot read a private file', () async {
    final response = await get('http://127.0.0.1:${Server().port}/book/${Uri.encodeComponent(secret.path)}');
    expect(response.statusCode, 404);
    await response.drain<void>();
  });

  test('authenticated library book loads without wildcard CORS', () async {
    final response = await get('${Server().baseUrl}/book/${Uri.encodeComponent(book.path)}');
    expect(response.statusCode, 200);
    expect(response.headers.value('access-control-allow-origin'), isNull);
    expect(response.headers.value('referrer-policy'), 'no-referrer');
    expect(response.headers.value('x-content-type-options'), 'nosniff');
    expect(await response.transform(utf8.decoder).join(), 'book-data');
  });

  test('even a valid session cannot request private settings', () async {
    final response = await get('${Server().baseUrl}/book/${Uri.encodeComponent(secret.path)}');
    expect(response.statusCode, 404);
    await response.drain<void>();
  });

  test('symlink in library cannot escape its directory', () async {
    final link = Link('${getFileDir().path}/escape.epub');
    await link.create(secret.path);
    final response = await get('${Server().baseUrl}/book/${Uri.encodeComponent(link.path)}');
    expect(response.statusCode, 404);
    await response.drain<void>();
  });

  test('background path traversal is rejected', () async {
    final response = await get('${Server().baseUrl}/bgimg/local/${Uri.encodeComponent('../private-settings')}');
    expect(response.statusCode, 404);
    await response.drain<void>();
  });

  test('temporary imported book needs the same session capability', () async {
    final name = Server().setTempFile(book);
    final response = await get('${Server().baseUrl}/$name');
    expect(response.statusCode, 200);
    await response.drain<void>();
    final unauthenticated = await get('http://127.0.0.1:${Server().port}/$name');
    expect(unauthenticated.statusCode, 404);
    await unauthenticated.drain<void>();
  });
}
