const personalPackage = 'com.anxcye.anx_reader.folex';
const personalCertificate =
    'b6c259cad8a3082aeb1d91c47edb5466dd6c46275e6d1ad2475651c68c41a439';
const personalManifestUrl =
    'https://github.com/folex/anx-reader-personal-releases/releases/latest/download/update.json';

bool isPersonalUpdateUrl(Uri uri, {bool apk = false}) {
  if (uri.scheme != 'https' ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment ||
      uri.port != 443)
    return false;
  if (!apk &&
      const {
        'release-assets.githubusercontent.com',
        'objects.githubusercontent.com',
      }.contains(uri.host))
    return true;
  final parts = uri.pathSegments;
  if (uri.host != 'github.com' ||
      parts.length != 6 ||
      parts[0] != 'folex' ||
      parts[1] != 'anx-reader-personal-releases' ||
      parts[2] != 'releases')
    return false;
  if (apk) {
    return parts[3] == 'download' &&
        parts[4].isNotEmpty &&
        parts[5].endsWith('.apk') &&
        !parts.any((p) => p.contains('/'));
  }
  return (parts[3] == 'download' && parts[4].isNotEmpty) ||
      (parts[3] == 'latest' && parts[4] == 'download');
}

class PersonalUpdateManifest {
  final int versionCode;
  final String versionName;
  final Uri apkUrl;
  final String sha256;
  final String releaseNotes;
  const PersonalUpdateManifest(
    this.versionCode,
    this.versionName,
    this.apkUrl,
    this.sha256,
    this.releaseNotes,
  );

  factory PersonalUpdateManifest.parse(Object? data) {
    if (data is! Map<String, dynamic> ||
        data['schemaVersion'] is! int ||
        data['schemaVersion'] != 1 ||
        data['packageName'] != personalPackage) {
      throw const FormatException('Not a personal Anx update manifest');
    }
    final code = data['versionCode'];
    final name = data['versionName'];
    final url = data['apkUrl'];
    final digest = data['sha256'];
    final notes = data['releaseNotes'];
    if (code is! int ||
        code <= 0 ||
        code > 2147483647 ||
        name is! String ||
        name.isEmpty ||
        name.length > 100 ||
        url is! String ||
        digest is! String ||
        !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(digest) ||
        (notes != null && notes is! String)) {
      throw const FormatException('Invalid personal update fields');
    }
    final uri = Uri.tryParse(url);
    if (uri == null || !isPersonalUpdateUrl(uri, apk: true)) {
      throw const FormatException(
        'APK must belong to the personal release repository',
      );
    }
    return PersonalUpdateManifest(
      code,
      name,
      uri,
      digest.toLowerCase(),
      (notes as String?) ?? '',
    );
  }
}
