import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:anx_reader/utils/personal_update_manifest.dart';

void main() {
  const apk = 'https://github.com/folex/anx-reader-personal-releases/releases/download/personal.4/Anx-Reader-personal-arm64.apk';
  Map<String, dynamic> manifest() => {'schemaVersion': 1, 'packageName': personalPackage,
    'versionCode': 6325, 'versionName': '1.14.0-personal.4', 'apkUrl': apk,
    'sha256': 'a' * 64, 'releaseNotes': 'A personal update'};
  test('parses our release and compares numeric build codes', () {
    final parsed = PersonalUpdateManifest.parse(jsonDecode(jsonEncode(manifest())));
    expect(parsed.versionCode, 6325);
    expect(parsed.versionCode > 6324, true);
    expect(parsed.versionCode > 9999, false);
    expect(parsed.apkUrl.toString(), apk);
  });
  for (final pair in <(String, Object)>[
    ('schemaVersion', 1.0), ('schemaVersion', 2), ('packageName', 'com.anxcye.anx_reader'),
    ('versionCode', '6325'), ('versionCode', 6325.0), ('versionCode', -1),
    ('versionCode', 2147483648), ('versionName', ''), ('sha256', '0' * 63),
    ('sha256', 'g' * 64), ('releaseNotes', 123),
    ('apkUrl', apk.replaceFirst('https:', 'http:')),
    ('apkUrl', apk.replaceFirst('github.com', 'github.com.evil.test')),
    ('apkUrl', apk.replaceFirst('github.com', 'evil@github.com')),
    ('apkUrl', apk.replaceFirst('/folex/', '/someone/')),
    ('apkUrl', apk.replaceFirst('personal-releases', 'reader')),
    ('apkUrl', '$apk#fragment'), ('apkUrl', apk.replaceFirst('.apk', '.zip')),
  ]) {
    test('rejects invalid ${pair.$1} ${pair.$2}', () {
      expect(() => PersonalUpdateManifest.parse(manifest()..[pair.$1] = pair.$2), throwsFormatException);
    });
  }
  test('redirects stay on HTTPS and the repository / known GitHub asset hosts', () {
    expect(isPersonalUpdateUrl(Uri.parse(personalManifestUrl)), true);
    expect(isPersonalUpdateUrl(Uri.parse(apk)), true);
    expect(isPersonalUpdateUrl(Uri.parse('https://release-assets.githubusercontent.com/a?signature=public')), true);
    expect(isPersonalUpdateUrl(Uri.parse('https://objects.githubusercontent.com/a')), true);
    for (final url in ['http://release-assets.githubusercontent.com/a',
      'https://release-assets.githubusercontent.com.evil.test/a',
      'https://user:password@objects.githubusercontent.com/a',
      'https://github.com/other/repo/releases/download/v/app.apk',
      'https://github.com:444/folex/anx-reader-personal-releases/releases/download/v/app.apk',
      'file:///data/user/0/com.anxcye.anx_reader.folex/secrets']) {
      expect(isPersonalUpdateUrl(Uri.parse(url)), false, reason: url);
    }
  });
}
