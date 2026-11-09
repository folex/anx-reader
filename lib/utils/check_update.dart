import 'package:anx_reader/utils/personal_update.dart';
export 'package:anx_reader/utils/personal_update.dart'
    show PersonalUpdater, PersonalUpdateButton;

Future<void> checkUpdate(bool manualCheck) =>
    PersonalUpdater.instance.check(manual: manualCheck);
