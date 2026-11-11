import 'package:anx_reader/config/shared_preference_provider.dart';
import 'package:anx_reader/enums/lang_list.dart';
import 'package:anx_reader/service/translate/index.dart';
import 'package:flutter/material.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

class TranslationMenu extends StatefulWidget {
  const TranslationMenu({
    super.key,
    required this.content,
    required this.decoration,
    required this.axis,
    this.contextText,
  });
  final String content;
  final BoxDecoration decoration;
  final Axis axis;
  final String? contextText;

  @override
  State<TranslationMenu> createState() => _TranslationMenuState();
}

class _TranslationMenuState extends State<TranslationMenu> {
  Widget _langPicker(bool isFrom) {
    final MenuController menuController = MenuController();

    return PointerInterceptor(
      child: MenuAnchor(
        style: MenuStyle(
          backgroundColor: WidgetStateProperty.all(
            Theme.of(context).colorScheme.secondaryContainer,
          ),
          maximumSize: WidgetStateProperty.all(const Size(300, 300)),
        ),
        controller: menuController,
        menuChildren: [
          for (var lang in LangListEnum.values)
            PointerInterceptor(
              child: MenuItemButton(
                onPressed: () {
                  setState(() {
                    if (isFrom) {
                      Prefs().translateFrom = lang;
                    } else {
                      Prefs().translateTo = lang;
                    }
                  });
                },
                child: Text(lang.getNative(context)),
              ),
            ),
        ],
        builder: (context, controller, child) {
          return TextButton(
            onPressed: controller.isOpen ? controller.close : controller.open,
            child: Text(
              isFrom
                  ? Prefs().translateFrom.getNative(context)
                  : Prefs().translateTo.getNative(context),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final prefs = Prefs();
    final service = prefs.translateService;
    final vertical = widget.axis == Axis.vertical;
    return Container(
      width: vertical ? 220 : double.infinity,
      constraints: BoxConstraints(
        maxHeight: service.isWebView ? 440 : 220,
      ),
      decoration: widget.decoration,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _langPicker(true),
                const Icon(Icons.arrow_forward, size: 16),
                _langPicker(false),
              ],
            ),
            KeyedSubtree(
              key: ValueKey((
                service,
                prefs.translateFrom,
                prefs.translateTo,
                widget.content,
                widget.contextText,
              )),
              child: translateText(
                widget.content,
                service: service,
                contextText: widget.contextText,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
