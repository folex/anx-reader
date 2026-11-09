import 'dart:io';

import 'package:flutter/services.dart';
import 'package:pubspec_parse/pubspec_parse.dart';

Future<String> getAppVersion() async {
  if (Platform.isAndroid) {
    try {
      const channel = MethodChannel(
        'com.anxcye.anx_reader.folex/personal_updates',
      );
      final info =
          await channel.invokeMapMethod<String, dynamic>('installedInfo');
      final name = info?['versionName'];
      final code = info?['versionCode'];
      if (name is String && name.isNotEmpty && code is int) {
        return '$name+$code';
      }
    } on PlatformException {
      // Fall back for non-personal Android builds without this bridge.
    } on MissingPluginException {
      // Fall back when the Android bridge is unavailable.
    }
  }
  final pubspecContent = await rootBundle.loadString('pubspec.yaml');
  final pubspec = Pubspec.parse(pubspecContent);
  return pubspec.version.toString();
}
