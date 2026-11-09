import 'package:flutter/material.dart';
import 'package:anx_reader/models/reader_hint_filter.dart';

class ReaderHintSettings extends StatefulWidget {
  const ReaderHintSettings(
      {super.key,
      required this.controls,
      required this.tags,
      required this.filter,
      required this.setLevel,
      required this.setFilter,
      this.refresh});
  final List<Map> controls;
  final Map<String, List<String>> tags;
  final ReaderHintFilter filter;
  final Future<bool> Function(String, int) setLevel;
  final Future<void> Function(ReaderHintFilter) setFilter;
  final Future<Map<String, List<String>>> Function()? refresh;
  @override
  State<ReaderHintSettings> createState() => _ReaderHintSettingsState();
}

class _ReaderHintSettingsState extends State<ReaderHintSettings> {
  late ReaderHintFilter _filter = ReaderHintFilter(
      only: widget.filter.only,
      exclude: widget.filter.exclude,
      catalog: widget.filter.tagsWith(widget.tags));
  late Map<String, List<String>> _tags = widget.tags;
  bool _busy = false;
  String? _error;
  Future<void> _save(ReaderHintFilter next) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.setFilter(next);
      if (mounted) setState(() => _filter = next);
    } catch (_) {
      if (mounted)
        setState(() => _error = 'Could not apply filters. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addTag() async {
    var category = '', value = '';
    String? error;
    final added = await showDialog<Map<String, List<String>>>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: const Text('Add tag'),
                  content: SingleChildScrollView(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        onChanged: (text) => category = text,
                        maxLength: 32,
                        decoration: const InputDecoration(
                            labelText: 'Category',
                            hintText: 'difficulty, topic, grammar…')),
                    TextField(
                        onChanged: (text) => value = text,
                        maxLength: 64,
                        decoration: const InputDecoration(
                            labelText: 'Value',
                            hintText: 'C1, food, subjunctive…')),
                    const Text(
                        'Create any category or level. It matches hints saved with that tag; it does not label existing hints automatically.'),
                    if (error != null)
                      Text(error!,
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.error)),
                  ])),
                  actions: [
                    TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Cancel')),
                    TextButton(
                        onPressed: () {
                          try {
                            Navigator.pop(
                                context,
                                normalizeHintTags({
                                  category: [value]
                                }));
                          } on FormatException catch (e) {
                            update(() => error = e.message);
                          }
                        },
                        child: const Text('Add'))
                  ],
                )));
    if (added != null && mounted) {
      try {
        await _save(ReaderHintFilter(
            only: _filter.only,
            exclude: _filter.exclude,
            catalog: _filter.tagsWith(added)));
      } on FormatException catch (_) {
        if (mounted) setState(() => _error = 'Too many saved tags.');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tags = _filter.tagsWith(_tags);
    final categories = tags.keys.toList()..sort();
    return SafeArea(
        child: ConstrainedBox(
      constraints:
          BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .85),
      child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.subtitles_outlined),
                    title: Text('Reading hints',
                        style: Theme.of(context).textTheme.titleLarge)),
                for (final control in widget.controls)
                  Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(control['label']?.toString() ?? 'Hints'),
                            DropdownButton<int>(
                                isExpanded: true,
                                value: [0, 1, 2, 3].contains(control['level'])
                                    ? control['level'] as int
                                    : 3,
                                items: const [
                                  DropdownMenuItem(
                                      value: 0, child: Text('Off')),
                                  DropdownMenuItem(
                                      value: 1, child: Text('Few')),
                                  DropdownMenuItem(
                                      value: 2, child: Text('Some')),
                                  DropdownMenuItem(
                                      value: 3, child: Text('Many'))
                                ],
                                onChanged: _busy
                                    ? null
                                    : (level) async {
                                        if (level == null) return;
                                        setState(() {
                                          _busy = true;
                                          _error = null;
                                        });
                                        try {
                                          if (await widget.setLevel(
                                                  control['id'].toString(),
                                                  level) &&
                                              mounted)
                                            setState(
                                                () => control['level'] = level);
                                        } catch (_) {
                                          if (mounted)
                                            setState(() => _error =
                                                'Could not change hint level.');
                                        } finally {
                                          if (mounted)
                                            setState(() => _busy = false);
                                        }
                                      }),
                          ])),
                if (widget.refresh != null)
                  TextButton.icon(
                      icon: const Icon(Icons.refresh),
                      label: const Text('Refresh hints'),
                      onPressed: _busy
                          ? null
                          : () async {
                              setState(() {
                                _busy = true;
                                _error = null;
                              });
                              try {
                                final tags = await widget.refresh!();
                                if (mounted) setState(() => _tags = tags);
                              } catch (_) {
                                if (mounted)
                                  setState(() =>
                                      _error = 'Could not refresh hints.');
                              } finally {
                                if (mounted) setState(() => _busy = false);
                              }
                            }),
                const Divider(),
                Text('Filter by tags',
                    style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 8),
                const Text(
                    'Eye: show or hide a tag. Focus: show only focused tags (any match). Hidden tags stay hidden.'),
                const SizedBox(height: 8),
                const Text(
                    'Tags are independent. Showing one tag does not hide others. Existing density levels still apply.'),
                Wrap(spacing: 8, children: [
                  TextButton.icon(
                      icon: const Icon(Icons.add),
                      label: const Text('Add tag'),
                      onPressed: _busy ? null : _addTag),
                  TextButton(
                      onPressed: _busy || !_filter.active
                          ? null
                          : () => _save(ReaderHintFilter(catalog: tags)),
                      child: const Text('Clear filters')),
                ]),
                if (_busy) const LinearProgressIndicator(),
                if (_error != null)
                  Text(_error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                if (categories.isEmpty)
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                          'No tagged hints in this chapter yet. You can add your own categories and ask the assistant to use them.')),
                for (final category in categories)
                  ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      initiallyExpanded: true,
                      title: Text(category),
                      children: [
                        for (final value in tags[category]!..sort())
                          Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Row(children: [
                                Expanded(child: Text(value)),
                                const SizedBox(width: 8),
                                IconButton(
                                  tooltip:
                                      '${_filter.isHidden(category, value) ? 'Show' : 'Hide'} $category: $value',
                                  isSelected:
                                      !_filter.isHidden(category, value),
                                  icon:
                                      const Icon(Icons.visibility_off_outlined),
                                  selectedIcon:
                                      const Icon(Icons.visibility_outlined),
                                  onPressed: _busy
                                      ? null
                                      : () => _save(_filter.choose(
                                          category,
                                          value,
                                          _filter.isHidden(category, value)
                                              ? 'show'
                                              : 'hide')),
                                ),
                                IconButton(
                                  tooltip:
                                      '${_filter.isOnly(category, value) ? 'Stop focusing' : 'Only'} $category: $value',
                                  isSelected: _filter.isOnly(category, value),
                                  icon: const Icon(Icons.center_focus_weak),
                                  selectedIcon:
                                      const Icon(Icons.center_focus_strong),
                                  onPressed: _busy
                                      ? null
                                      : () => _save(_filter.choose(
                                          category, value, 'only')),
                                ),
                              ])),
                      ]),
              ])),
    ));
  }
}
