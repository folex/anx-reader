import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/footnote_appearance.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('defaults are small opaque independent controls', () {
    expect(FootnoteAppearance.fromJson(null).toMap(), {
      'fontSize': 16.0,
      'backgroundOpacity': 1.0,
      'blur': 0.0,
    });
    expect(
      FootnoteAppearance.fromJson('bad json').toMap(),
      const FootnoteAppearance().toMap(),
    );
  });
  test('out of bounds and malformed values cannot escape controls', () {
    expect(
      FootnoteAppearance.fromMap({
        'fontSize': 999,
        'backgroundOpacity': -1,
        'blur': 100,
      }).toMap(),
      {'fontSize': 28.0, 'backgroundOpacity': .2, 'blur': 16.0},
    );
    expect(
      FootnoteAppearance.fromMap({
        'fontSize': double.nan,
        'backgroundOpacity': '1',
        'blur': double.infinity,
      }).toMap(),
      const FootnoteAppearance().toMap(),
    );
  });
  test('preferences survive reload and never change the book font', () async {
    SharedPreferences.setMockInitialValues({});
    await Prefs().initPrefs();
    final before = Prefs().bookStyle.toJson();
    await Prefs().saveFootnoteAppearance(
      const FootnoteAppearance(fontSize: 22, backgroundOpacity: .75, blur: 6),
    );
    await Prefs().prefs.reload();
    expect(Prefs().footnoteAppearance.toMap(), {
      'fontSize': 22.0,
      'backgroundOpacity': .75,
      'blur': 6.0,
    });
    expect(Prefs().bookStyle.toJson(), before);
    await Prefs().saveFootnoteAppearance(const FootnoteAppearance());
    expect(
      Prefs().footnoteAppearance.toMap(),
      const FootnoteAppearance().toMap(),
    );
  });
}
