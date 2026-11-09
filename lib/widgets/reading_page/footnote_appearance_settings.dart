import 'dart:ui';
import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/models/footnote_appearance.dart';
import 'package:flutter/material.dart';

class FootnoteAppearanceSettings extends StatefulWidget {
  const FootnoteAppearanceSettings({super.key, required this.onChanged});
  final ValueChanged<FootnoteAppearance> onChanged;
  @override
  State<FootnoteAppearanceSettings> createState() =>
      _FootnoteAppearanceSettingsState();
}

class _FootnoteAppearanceSettingsState
    extends State<FootnoteAppearanceSettings> {
  FootnoteAppearance appearance = Prefs().footnoteAppearance;
  void change(FootnoteAppearance value) {
    setState(() {
      appearance = value;
    });
    Prefs().saveFootnoteAppearance(value);
    widget.onChanged(value);
  }

  Widget slider(
    String title,
    double value,
    double min,
    double max,
    int divisions,
    String label,
    ValueChanged<double> onChanged,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('$title: $label'),
      Slider(
        value: value,
        min: min,
        max: max,
        divisions: divisions,
        onChanged: onChanged,
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final theme = Prefs().readTheme;
    Color parse(String hex, Color fallback) {
      try {
        return Color(int.parse(hex.replaceFirst('#', ''), radix: 16));
      } catch (_) {
        return fallback;
      }
    }

    final foreground = parse(
      theme.textColor,
      Theme.of(context).colorScheme.onSurface,
    );
    final background = parse(
      theme.backgroundColor,
      Theme.of(context).colorScheme.surface,
    );
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Footnotes',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
              TextButton(
                onPressed: () => change(const FootnoteAppearance()),
                child: const Text('Reset'),
              ),
            ],
          ),
          const Text(
            'Footnote text size is independent of book text size. Colors follow the reading theme.',
          ),
          const SizedBox(height: 16),
          slider(
            'Text size',
            appearance.fontSize,
            12,
            28,
            16,
            '${appearance.fontSize.round()} px',
            (value) => change(appearance.copyWith(fontSize: value)),
          ),
          slider(
            'Background opacity',
            appearance.backgroundOpacity,
            .2,
            1,
            16,
            '${(appearance.backgroundOpacity * 100).round()}%',
            (value) => change(appearance.copyWith(backgroundOpacity: value)),
          ),
          slider(
            'Backdrop blur',
            appearance.blur,
            0,
            16,
            16,
            appearance.blur == 0 ? 'off' : '${appearance.blur.round()} px',
            (value) => change(appearance.copyWith(blur: value)),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 128,
            width: double.infinity,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: ColoredBox(
                      color: background,
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Text(
                          'La lectura nos permite descubrir nuevos mundos.\nEl significado depende del contexto.',
                          style: TextStyle(color: foreground, fontSize: 18),
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: BackdropFilter(
                          filter: ImageFilter.blur(
                            sigmaX: appearance.blur,
                            sigmaY: appearance.blur,
                          ),
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: background.withValues(
                                alpha: appearance.backgroundOpacity,
                              ),
                              border: Border.all(
                                color: foreground.withValues(alpha: .3),
                              ),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(10),
                              child: Text(
                                'acostumbrarse a — to get used to something. The preposition a is part of the construction.',
                                style: TextStyle(
                                  fontSize: appearance.fontSize,
                                  color: foreground,
                                  height: 1.4,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
