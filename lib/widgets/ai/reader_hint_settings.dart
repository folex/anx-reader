import 'package:flutter/material.dart';
import 'package:anx_reader/models/reader_hint_preview.dart';
import 'package:anx_reader/models/reader_hint_filter.dart';

class ReaderHintSettings extends StatefulWidget {
  const ReaderHintSettings(
      {super.key,
      required this.tags,
      required this.filter,
      required this.preview,
      required this.setFilter,
      this.refresh});
  final Map<String, List<String>> tags;
  final ReaderHintFilter filter;
  final Future<ReaderHintPreview> Function(ReaderHintFilter) preview;
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
      if (mounted) {
        setState(() => _error = 'Could not apply filters. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _preview(ReaderHintFilter filter, String title) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    // Capture the renderer below this sheet, then restore it before showing the
    // snapshot. Opening or closing the preview never saves a different filter.
    try {
      final preview = await widget.preview(filter);
      if (!mounted) return;
      setState(() => _busy = false);
      await showDialog<void>(
          context: context,
          builder: (context) => Dialog(
              insetPadding: const EdgeInsets.all(12),
              child: SizedBox(
                  height: MediaQuery.sizeOf(context).height * .9,
                  child: Column(children: [
                    ListTile(
                        title: Text(title),
                        subtitle: Text(preview.matches == 0
                            ? 'No matching hints in this chapter'
                            : 'Chapter preview · pinch to zoom'),
                        trailing: IconButton(
                            tooltip: 'Close preview',
                            icon: const Icon(Icons.close),
                            onPressed: () => Navigator.pop(context))),
                    Expanded(
                        child: ClipRect(
                            child: InteractiveViewer(
                                maxScale: 4,
                                child: Image.memory(preview.image,
                                    fit: BoxFit.contain,
                                    semanticLabel:
                                        'Book preview with $title')))),
                  ]))));
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not preview hints. Try again.';
        });
      }
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
                FilledButton.tonalIcon(
                    icon: const Icon(Icons.preview_outlined),
                    label: const Text('Preview'),
                    onPressed: _busy
                        ? null
                        : () => _preview(_filter, 'Current filters')),
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
                                if (mounted) {
                                  setState(() =>
                                      _error = 'Could not refresh hints.');
                                }
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
                    'Tags are independent. Tap a tag to preview its hints. Showing one tag does not hide others.'),
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
                      title: Row(children: [
                        Expanded(
                            child: InkWell(
                                onTap: _busy
                                    ? null
                                    : () => _preview(
                                        ReaderHintFilter(
                                            only: {category: tags[category]!}),
                                        category),
                                child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                        vertical: 12),
                                    child: Text(category)))),
                        IconButton(
                            tooltip: 'Preview $category',
                            icon: const Icon(Icons.preview_outlined),
                            onPressed: _busy
                                ? null
                                : () => _preview(
                                    ReaderHintFilter(
                                        only: {category: tags[category]!}),
                                    category)),
                      ]),
                      children: [
                        for (final value in tags[category]!..sort())
                          Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Row(children: [
                                Expanded(
                                    child: InkWell(
                                        onTap: _busy
                                            ? null
                                            : () => _preview(
                                                ReaderHintFilter(only: {
                                                  category: [value]
                                                }),
                                                '$category: $value'),
                                        child: Padding(
                                            padding: const EdgeInsets.symmetric(
                                                vertical: 12),
                                            child: Text(value)))),
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
