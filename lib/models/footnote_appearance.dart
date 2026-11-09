import 'dart:convert';

/// Popup controls are deliberately independent of the book font multiplier.
class FootnoteAppearance {
  const FootnoteAppearance({
    this.fontSize = 16,
    this.backgroundOpacity = 1,
    this.blur = 0,
  });
  final double fontSize;
  final double backgroundOpacity;
  final double blur;
  static double _number(
    dynamic value,
    double fallback,
    double min,
    double max,
  ) => value is num && value.isFinite
      ? value.toDouble().clamp(min, max)
      : fallback;
  factory FootnoteAppearance.fromMap(Map<String, dynamic> map) =>
      FootnoteAppearance(
        fontSize: _number(map['fontSize'], 16, 12, 28),
        backgroundOpacity: _number(map['backgroundOpacity'], 1, .2, 1),
        blur: _number(map['blur'], 0, 0, 16),
      );
  factory FootnoteAppearance.fromJson(String? value) {
    try {
      return FootnoteAppearance.fromMap(
        Map<String, dynamic>.from(jsonDecode(value ?? '{}') as Map),
      );
    } catch (_) {
      return const FootnoteAppearance();
    }
  }
  FootnoteAppearance copyWith({
    double? fontSize,
    double? backgroundOpacity,
    double? blur,
  }) => FootnoteAppearance.fromMap({
    'fontSize': fontSize ?? this.fontSize,
    'backgroundOpacity': backgroundOpacity ?? this.backgroundOpacity,
    'blur': blur ?? this.blur,
  });
  Map<String, double> toMap() => {
    'fontSize': fontSize,
    'backgroundOpacity': backgroundOpacity,
    'blur': blur,
  };
  String toJson() => jsonEncode(toMap());
}
