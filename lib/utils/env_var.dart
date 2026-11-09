import 'dart:io';

class EnvVar {
  static const bool isAppStore =
      String.fromEnvironment('isAppStore', defaultValue: 'false') == 'true';

  static const bool isPlayStore =
      String.fromEnvironment('isPlayStore', defaultValue: 'false') == 'true';
  static const bool isFdroid =
      String.fromEnvironment('isFdroid', defaultValue: 'false') == 'true';
  static const bool isOhosStore =
      String.fromEnvironment('isOhosStore', defaultValue: 'false') == 'true';

  static bool get _isChineseMainlandLocale =>
      Platform.localeName == 'zh_Hans_CN';

  static bool get isStoreBuild => isAppStore || isPlayStore;

  static bool get showIapPlaceHolder => isOhosStore;

  // Personal Android releases use our signed update channel.
  static bool get enableCheckUpdate => Platform.isAndroid;
  static bool get enableDonation => !isStoreBuild && !isOhosStore;
  static bool get enableInAppPurchase => isStoreBuild;

  static bool get showBeian =>
      (isAppStore && _isChineseMainlandLocale) || isOhosStore;
  static bool get enableOpenAiConfig => !showBeian;
  static bool get showTelegramLink => !showBeian;

  static bool get enableAIFeature => !isOhosStore;
}
