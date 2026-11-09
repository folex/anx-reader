import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:anx_reader/service/reader_edits/book_image_filter.dart';
import 'book_image_generation_settings.dart';

Future<void> showBookIllustrations(
  BuildContext context, {
  required Future<Map<String, dynamic>> Function(Map<String, dynamic>) handle,
  required void Function(String) onImported,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          BookIllustrationsSheet(handle: handle, onImported: onImported),
    );

class BookIllustrationsSheet extends StatefulWidget {
  const BookIllustrationsSheet(
      {super.key, required this.handle, required this.onImported});
  final Future<Map<String, dynamic>> Function(Map<String, dynamic>) handle;
  final void Function(String) onImported;
  @override
  State<BookIllustrationsSheet> createState() => _BookIllustrationsSheetState();
}

class _BookIllustrationsSheetState extends State<BookIllustrationsSheet> {
  List<Map> _images = [];
  bool _busy = true;
  String? _error;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await widget.handle({'action': 'list'});
      if (mounted)
        setState(() {
          _images = (result['images'] as List? ?? []).whereType<Map>().toList();
          _error = null;
        });
    } catch (_) {
      if (mounted)
        setState(() => _error =
            'Could not read chapter images. Reopen the chapter and try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _adjust(Map image, String action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.handle({
        'action': 'edit',
        'operationId': 'image-${DateTime.now().microsecondsSinceEpoch}',
        'imageId': image['imageId'],
        'target': 'dark',
        if (action == 'restore')
          'restore': true
        else
          'filters': {'preset': action == 'paper' ? 'dark-paper' : 'darken'},
      });
      await _load();
    } catch (_) {
      if (mounted)
        setState(() => _error =
            'Could not adjust this image. The original is retained. Try asking the assistant for a supported correction.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final picked = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
          allowMultiple: false);
      if (picked == null || !mounted) return;
      final file = picked.files.single;
      if (file.size > maxBookImageBytes)
        throw const FormatException('Image exceeds 12 MB');
      final Uint8List bytes =
          file.bytes ?? await File(file.path!).readAsBytes();
      final result = await widget.handle({'action': 'import', 'bytes': bytes});
      if (!mounted) return;
      final id = result['imageId'] as String;
      Navigator.pop(context);
      widget.onImported(id);
    } catch (_) {
      if (mounted)
        setState(() => _error =
            'Could not import the image. Use a still PNG, JPEG, WebP or GIF up to 12 MB and 12 megapixels.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
          child: ConstrainedBox(
        constraints:
            BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * .8),
        child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.image_outlined),
                      title: Text('Illustrations',
                          style: Theme.of(context).textTheme.titleLarge)),
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.add_photo_alternate_outlined),
                      title: const Text('Import and insert image'),
                      onTap: _busy ? null : _import),
                  ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.auto_awesome_outlined),
                      title: const Text('Image generation'),
                      subtitle: const Text('Separate Image API settings'),
                      onTap: _busy
                          ? null
                          : () => showBookImageGenerationSettings(context)),
                  const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                          'Ask the assistant to illustrate a passage or adjust a picture. Color adjustments run locally; the original image stays in your EPUB.')),
                  if (_busy) const LinearProgressIndicator(),
                  if (_error != null)
                    Text(_error!,
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.error)),
                  if (!_busy && _images.isEmpty)
                    const Padding(
                        padding: EdgeInsets.symmetric(vertical: 12),
                        child: Text('No embedded images in this chapter yet.')),
                  for (final image in _images)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.photo_outlined),
                      title: Text(
                          (image['alt']?.toString() ?? '').isNotEmpty
                              ? image['alt'] as String
                              : 'Illustration ${(image['index'] as int) + 1}',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      subtitle: Text(image['visible'] == true
                          ? 'On this page'
                          : image['filename']?.toString() ?? ''),
                      trailing: PopupMenuButton<String>(
                          enabled: !_busy && image['localEditing'] == true,
                          tooltip: 'Image adjustments',
                          onSelected: (value) => _adjust(image, value),
                          itemBuilder: (_) => const [
                                PopupMenuItem(
                                    value: 'paper',
                                    child: Text('Adapt drawing for dark mode')),
                                PopupMenuItem(
                                    value: 'dim',
                                    child: Text('Dim photo in dark mode')),
                                PopupMenuItem(
                                    value: 'restore',
                                    child: Text('Restore original')),
                              ]),
                    ),
                ])),
      ));
}
