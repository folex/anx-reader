import 'package:anx_reader/service/voice/reader_voice.dart';
import 'package:flutter/material.dart';

class ReaderVoiceToolbar extends StatelessWidget {
  const ReaderVoiceToolbar({
    super.key,
    required this.controller,
    required this.assistantContext,
    this.disabled = false,
  });
  final ReaderVoiceController controller;
  final Map<String, String> Function() assistantContext;
  final bool disabled;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 4,
          children: [
            IconButton(
              tooltip: controller.canStop
                  ? 'Stop dictation'
                  : 'Android dictation',
              onPressed: disabled || (controller.busy && !controller.canStop)
                  ? null
                  : () => controller.canStop
                        ? controller.stopDictation()
                        : controller.startDictation(),
              icon: Icon(
                controller.canStop
                    ? Icons.stop_circle_outlined
                    : Icons.mic_none,
              ),
            ),
            IconButton(
              tooltip: 'System assistant',
              onPressed: disabled || controller.busy
                  ? null
                  : () => controller.startAssistant(assistantContext()),
              icon: const Icon(Icons.assistant_outlined),
            ),
            DropdownButton<String>(
              value: controller.language,
              underline: const SizedBox(),
              items: const [
                DropdownMenuItem(value: 'ru-RU', child: Text('RU')),
                DropdownMenuItem(value: 'es-ES', child: Text('ES')),
                DropdownMenuItem(value: 'en-US', child: Text('EN')),
              ],
              onChanged: disabled || controller.busy
                  ? null
                  : (value) {
                      if (value != null) {
                        controller.setLanguage(value);
                      }
                    },
            ),
            if (controller.busy)
              IconButton(
                tooltip: 'Cancel voice input',
                onPressed: controller.cancel,
                icon: const Icon(Icons.close),
              ),
          ],
        ),
        if (controller.preview.isNotEmpty)
          Text(
            controller.preview,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontStyle: FontStyle.italic),
          ),
        if (controller.status.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              controller.status,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
      ],
    ),
  );
}
