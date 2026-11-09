import 'dart:convert';

/// Arbitrary user categories; shared by tool inputs and per-book filter settings.
Map<String, List<String>> normalizeHintTags(Object? raw,
    {int maxCategories = 16, int maxValues = 16}) {
  if (raw == null) return {};
  if (raw is! Map || raw.length > maxCategories) {
    throw FormatException('Use up to $maxCategories tag categories');
  }
  final result = <String, List<String>>{};
  for (final entry in raw.entries) {
    if (entry.key is! String)
      throw const FormatException('Invalid tag category');
    final key = (entry.key as String).trim().toLowerCase();
    if (key.isEmpty ||
        key.length > 32 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(key) ||
        result.containsKey(key)) {
      throw const FormatException(
          'Tag categories must be unique and 1–32 characters');
    }
    final values = entry.value;
    if (values is! List || values.isEmpty || values.length > maxValues) {
      throw FormatException('Use 1–$maxValues values per tag category');
    }
    final unique = <String, String>{};
    for (final value in values) {
      if (value is! String ||
          value.trim().isEmpty ||
          value.trim().length > 64 ||
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        throw const FormatException('Tag values must be 1–64 characters');
      }
      unique.putIfAbsent(value.trim().toLowerCase(), () => value.trim());
    }
    result[key] = unique.values.toList()..sort();
  }
  return {for (final key in result.keys.toList()..sort()) key: result[key]!};
}

Map<String, List<String>> _filterTags(Object? raw) =>
    normalizeHintTags(raw, maxCategories: 128, maxValues: 512);

class ReaderHintFilter {
  ReaderHintFilter(
      {Map<String, List<String>> only = const {},
      Map<String, List<String>> exclude = const {},
      Map<String, List<String>> catalog = const {}})
      : only = _filterTags(only),
        exclude = _filterTags(exclude),
        catalog = _filterTags(catalog);
  final Map<String, List<String>> only, exclude, catalog;
  factory ReaderHintFilter.fromJson(String? source) {
    try {
      final value = jsonDecode(source ?? '{}') as Map;
      final catalog = ReaderHintFilter(catalog: _filterTags(value['catalog']))
          .tagsWith(_filterTags(value['include']));
      return ReaderHintFilter(
          only: _filterTags(value['only']),
          exclude: _filterTags(value['exclude']),
          catalog: catalog);
    } catch (_) {
      return ReaderHintFilter();
    }
  }
  Map<String, dynamic> toMap() =>
      {'version': 2, 'only': only, 'exclude': exclude, 'catalog': catalog};
  Map<String, dynamic> toRules() => {'only': only, 'exclude': exclude};
  String toJson() => jsonEncode(toMap());
  bool get active => only.isNotEmpty || exclude.isNotEmpty;
  Map<String, List<String>> tagsWith(Map<String, List<String>> discovered) {
    final merged = <String, List<String>>{};
    for (final source in [catalog, only, exclude, discovered]) {
      for (final entry in source.entries) {
        final values = merged.putIfAbsent(entry.key, () => []);
        for (final value in entry.value) {
          if (!values
              .any((existing) => existing.toLowerCase() == value.toLowerCase()))
            values.add(value);
        }
      }
    }
    return merged;
  }

  bool _contains(
          Map<String, List<String>> tags, String category, String value) =>
      tags[category]?.any((v) => v.toLowerCase() == value.toLowerCase()) ??
      false;
  bool isHidden(String category, String value) =>
      _contains(exclude, category, value);
  bool isOnly(String category, String value) =>
      _contains(only, category, value);

  ReaderHintFilter choose(String category, String value, String choice) {
    if (!['show', 'hide', 'only'].contains(choice))
      throw const FormatException('Unknown tag action');
    final one = _filterTags({
      category: [value]
    });
    final key = one.keys.single, label = one.values.single.single;
    Map<String, List<String>> changed(
        Map<String, List<String>> source, bool add) {
      final result = {
        for (final e in source.entries) e.key: [...e.value]
      };
      result[key]?.removeWhere((v) => v.toLowerCase() == label.toLowerCase());
      if (add) result.putIfAbsent(key, () => []).add(label);
      result.removeWhere((_, values) => values.isEmpty);
      return result;
    }

    return ReaderHintFilter(
        only: choice == 'only' ? changed(only, !isOnly(key, label)) : only,
        exclude: choice == 'only' && isOnly(key, label)
            ? exclude
            : changed(exclude, choice == 'hide'),
        catalog: tagsWith(one));
  }
}
