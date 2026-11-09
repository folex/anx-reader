import 'package:flutter/material.dart';
import 'package:anx_reader/service/reader_edits/book_image_generation.dart';

Future<void> showBookImageGenerationSettings(BuildContext context) async {
  BookImageGenerationConfig config;
  try {
    config = await BookImageGenerationConfig.read();
  } catch (_) {
    if (context.mounted)
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not open protected image API settings.')));
    return;
  }
  if (!context.mounted) return;
  final key = TextEditingController(text: config.apiKey);
  final model = TextEditingController(text: config.model);
  String? error;
  var saving = false;
  try {
    await showDialog<void>(
        context: context,
        builder: (context) => StatefulBuilder(
            builder: (context, update) => AlertDialog(
                  title: const Text('Image generation'),
                  content: SingleChildScrollView(
                      child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                        const Text(
                            'Uses the OpenAI Image API with separate API billing. ChatGPT sign-in does not cover image generation. Local image adjustments need no API key.'),
                        const SizedBox(height: 16),
                        TextField(
                            controller: key,
                            obscureText: true,
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: const InputDecoration(
                                labelText: 'API key',
                                border: OutlineInputBorder())),
                        const SizedBox(height: 12),
                        TextField(
                            controller: model,
                            autocorrect: false,
                            enableSuggestions: false,
                            decoration: const InputDecoration(
                                labelText: 'Image model',
                                border: OutlineInputBorder())),
                        if (error != null)
                          Padding(
                              padding: const EdgeInsets.only(top: 12),
                              child: Text(error!,
                                  style: TextStyle(
                                      color: Theme.of(context)
                                          .colorScheme
                                          .error))),
                      ])),
                  actions: [
                    TextButton(
                        onPressed: saving ? null : () => Navigator.pop(context),
                        child: const Text('Cancel')),
                    FilledButton(
                        onPressed: saving
                            ? null
                            : () async {
                                update(() => saving = true);
                                try {
                                  await BookImageGenerationConfig(
                                          apiKey: key.text.trim(),
                                          model: model.text.trim())
                                      .save();
                                  if (context.mounted) Navigator.pop(context);
                                } catch (_) {
                                  if (context.mounted)
                                    update(() => error =
                                        'Could not save image API settings. Check the values and try again.');
                                } finally {
                                  if (context.mounted)
                                    update(() => saving = false);
                                }
                              },
                        child: Text(saving ? 'Saving…' : 'Save')),
                  ],
                )));
  } finally {
    key.dispose();
    model.dispose();
  }
}
