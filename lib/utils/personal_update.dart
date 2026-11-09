import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:anx_reader/main.dart';
import 'package:anx_reader/utils/log/common.dart';
import 'package:anx_reader/utils/personal_update_manifest.dart';
import 'package:anx_reader/utils/toast/common.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';

class PersonalUpdater extends ChangeNotifier {
  static final instance = PersonalUpdater();
  static const _channel = MethodChannel('$personalPackage/personal_updates');
  final _client = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 15),
      receiveTimeout: const Duration(seconds: 30),
      followRedirects: false,
    ),
  );
  PersonalUpdateManifest? available;
  bool checking = false;
  bool busy = false;
  double? progress;
  String? error;
  DateTime? _lastAttempt;
  DateTime? _lastSuccessfulCheck;

  Future<Map<String, dynamic>> _installedInfo() async =>
      (await _channel.invokeMapMethod<String, dynamic>('installedInfo'))!;

  Future<ResponseBody> _open(Uri uri) async {
    for (var redirects = 0; redirects <= 5; redirects++) {
      if (!isPersonalUpdateUrl(uri))
        throw const FormatException('Untrusted update URL');
      final response = await _client.getUri<ResponseBody>(
        uri,
        options: Options(
          responseType: ResponseType.stream,
          headers: {'Cache-Control': 'no-cache'},
          validateStatus: (code) => code != null && code >= 200 && code < 400,
        ),
      );
      final body = response.data!;
      if (response.statusCode == 200) return body;
      await body.stream.listen((_) {}).cancel();
      final location = response.headers.value('location');
      if (location == null)
        throw const FormatException('Invalid update redirect');
      uri = uri.resolve(location);
    }
    throw const FormatException('Too many update redirects');
  }

  Future<void> check({bool manual = false}) async {
    if (!Platform.isAndroid || checking || busy) return;
    final now = DateTime.now();
    if (!manual &&
        ((_lastSuccessfulCheck != null &&
                now.difference(_lastSuccessfulCheck!) <
                    const Duration(hours: 4)) ||
            (_lastAttempt != null &&
                now.difference(_lastAttempt!) < const Duration(minutes: 5))))
      return;
    _lastAttempt = now;
    checking = true;
    try {
      final body = await _open(
        Uri.parse(personalManifestUrl).replace(
          queryParameters: {'t': now.millisecondsSinceEpoch.toString()},
        ),
      );
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in body.stream) {
        if (bytes.length + chunk.length > 65536)
          throw const FormatException('Manifest too large');
        bytes.add(chunk);
      }
      final manifest = PersonalUpdateManifest.parse(
        jsonDecode(utf8.decode(bytes.takeBytes())),
      );
      final installed = await _installedInfo();
      final current = installed['versionCode'];
      if (current is! int)
        throw const FormatException('Invalid installed version code');
      available = manifest.versionCode > current ? manifest : null;
      error = null;
      _lastSuccessfulCheck = now;
      if (manual) {
        if (available == null)
          AnxToast.show('Anx Reader Personal is up to date.');
        else
          _showUpdate();
      }
    } catch (exception) {
      AnxLog.warning('Personal update check failed: $exception');
      if (manual)
        AnxToast.show(
          'Could not check for updates. Check your connection and try again.',
        );
    } finally {
      checking = false;
      notifyListeners();
    }
  }

  void _showUpdate() {
    final manifest = available;
    final context = navigatorKey.currentContext;
    if (manifest == null || context == null) return;
    SmartDialog.show(
      builder: (dialogContext) => AlertDialog(
        title: Text('Anx Reader Personal ${manifest.versionName}'),
        content: SingleChildScrollView(
          child: Text(
            '${manifest.releaseNotes}\n\nAndroid will ask you to confirm installation. '
            'Updating preserves your books and settings.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => SmartDialog.dismiss(),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: () {
              SmartDialog.dismiss();
              downloadAndInstall();
            },
            child: const Text('Update'),
          ),
        ],
      ),
    );
  }

  Future<bool> _validFile(File file, String digest) async =>
      await file.exists() &&
      await file.length() <= 128 * 1024 * 1024 &&
      (await crypto.sha256.bind(file.openRead()).first).toString() == digest;

  Future<void> downloadAndInstall() async {
    final manifest = available;
    if (manifest == null || busy) return;
    busy = true;
    error = null;
    progress = null;
    notifyListeners();
    File? partial;
    try {
      final installed = await _installedInfo();
      if (manifest.versionCode <= (installed['versionCode'] as int)) {
        available = null;
        return;
      }
      final directory = Directory(installed['directory'] as String);
      await directory.create(recursive: true);
      final apk = File('${directory.path}/update.apk');
      if (!await _validFile(apk, manifest.sha256)) {
        partial = File('${directory.path}/update.apk.part');
        final body = await _open(manifest.apkUrl);
        final expected = int.tryParse(
          body.headers['content-length']?.first ?? '',
        );
        if (expected != null && expected > 128 * 1024 * 1024) {
          await body.stream.listen((_) {}).cancel();
          throw const FormatException('Update APK too large');
        }
        final sink = partial.openWrite();
        var received = 0;
        var lastNotify = DateTime.now();
        try {
          await for (final chunk in body.stream) {
            received += chunk.length;
            if (received > 128 * 1024 * 1024)
              throw const FormatException('Update APK too large');
            sink.add(chunk);
            if (DateTime.now().difference(lastNotify).inMilliseconds > 150) {
              progress = expected != null && expected > 0
                  ? (received / expected).clamp(0.0, 1.0)
                  : null;
              notifyListeners();
              lastNotify = DateTime.now();
            }
          }
        } finally {
          await sink.close();
        }
        if (!await _validFile(partial, manifest.sha256))
          throw const FormatException('APK checksum mismatch');
        if (await apk.exists()) await apk.delete();
        await partial.rename(apk.path);
        partial = null;
      }
      progress = 1;
      notifyListeners();
      // Android independently checks archive package, integer version, digest and signing certificate.
      final result = await _channel.invokeMethod<String>('installUpdate', {
        'sha256': manifest.sha256,
        'versionCode': manifest.versionCode,
        'openPermissionSettings': true,
      });
      if (result == 'permission_required') {
        AnxToast.show(
          'Allow Anx Reader Personal to install updates, then return and tap Update again.',
        );
      }
    } catch (exception) {
      error = 'Update failed. Tap to retry.';
      AnxLog.warning('Personal update failed: $exception');
      AnxToast.show(error!);
    } finally {
      try {
        if (partial != null && await partial.exists()) await partial.delete();
      } catch (cleanupError) {
        AnxLog.warning('Could not remove partial update: $cleanupError');
      } finally {
        busy = false;
        notifyListeners();
      }
    }
  }
}

class PersonalUpdateButton extends StatelessWidget {
  const PersonalUpdateButton({super.key});
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: PersonalUpdater.instance,
    builder: (context, _) {
      final updater = PersonalUpdater.instance;
      if (updater.available == null) return const SizedBox.shrink();
      final label = updater.busy
          ? (updater.progress == null
                ? 'Downloading…'
                : 'Update ${(updater.progress! * 100).round()}%')
          : updater.error == null
          ? 'Update'
          : 'Retry update';
      return Tooltip(
        message: updater.error ?? 'Update Anx Reader Personal',
        child: FilledButton.icon(
          onPressed: updater.busy ? null : updater.downloadAndInstall,
          icon: updater.busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.system_update),
          label: Text(label),
        ),
      );
    },
  );
}
