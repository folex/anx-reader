import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:crypto/crypto.dart';
import 'package:anx_reader/service/extensions/extension_manager.dart';
import 'package:anx_reader/service/extensions/extension_package.dart';
import 'package:anx_reader/service/extensions/extension_runtime.dart';

const _permissionLabels = {
  'books.read': 'Read book content',
  'books.write': 'Modify books and annotations',
  'ui': 'Open extension screens',
  'network': 'Connect to declared websites'
};

class ExtensionsPage extends StatefulWidget {
  const ExtensionsPage({super.key});
  @override
  State<ExtensionsPage> createState() => _ExtensionsPageState();
}

class _ExtensionsPageState extends State<ExtensionsPage> {
  final manager = ExtensionManager.instance;
  String? error;
  bool busy = true;
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await manager.initialize();
    } catch (_) {
      error = 'Could not load extensions';
    }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _install() async {
    try {
      final result = await FilePicker.platform
          .pickFiles(type: FileType.any, withData: true);
      if (result == null) return;
      final selected = result.files.single;
      if (selected.size > 1024 * 1024) {
        throw StateError('Extension exceeds 1 MB');
      }
      final Uint8List bytes =
          selected.bytes ?? await File(selected.path!).readAsBytes();
      final extension = ReaderExtension.decode(bytes);
      final approved = extension.permissions.toSet();
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => StatefulBuilder(
              builder: (context, update) => AlertDialog(
                    title:
                        Text('Install ${extension.name} ${extension.version}?'),
                    content: SizedBox(
                        width: 400,
                        child: SingleChildScrollView(
                            child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                              const Text(
                                  'Install only extensions whose author you trust. The extension can use the permissions you grant below.'),
                              for (final permission in extension.permissions)
                                CheckboxListTile(
                                    title: Text(_permissionLabels[permission] ??
                                        permission),
                                    value: approved.contains(permission),
                                    onChanged: (value) => update(() =>
                                        value == true
                                            ? approved.add(permission)
                                            : approved.remove(permission))),
                              Text(
                                  'Network origins:\n${extension.origins.join('\n')}'),
                              if (extension.authOrigins.length >
                                  extension.origins.length)
                                Text(
                                    'Sign-in pages only:\n${extension.authOrigins.where((o) => !extension.origins.contains(o)).join('\n')}'),
                              const SizedBox(height: 12),
                              SelectableText(
                                  'Package SHA256:\n${sha256.convert(bytes)}',
                                  style: Theme.of(context).textTheme.bodySmall),
                            ]))),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel')),
                      FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Install'))
                    ],
                  )));
      if (confirmed != true) return;
      await manager.install(bytes, approved);
      if (mounted) setState(() => error = null);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> _signIn(ReaderExtension extension) async {
    try {
      await openExtensionSignIn(extension);
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  Future<void> _artifacts(ReaderExtension extension) async {
    try {
      final items = await extensionChannel.invokeListMethod<dynamic>(
              'artifacts', {'extensionId': extension.id}) ??
          [];
      if (!mounted) return;
      await showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (context) => SafeArea(
              child: ConstrainedBox(
                  constraints: BoxConstraints(
                      maxHeight: MediaQuery.sizeOf(context).height * .6),
                  child: ListView(shrinkWrap: true, children: [
                    const ListTile(title: Text('Downloaded audio')),
                    if (items.isEmpty)
                      const ListTile(title: Text('No downloaded audio yet')),
                    for (final item in items)
                      ListTile(
                          leading: const Icon(Icons.play_circle_outline),
                          title: Text(item['name'].toString()),
                          onTap: () async {
                            Navigator.pop(context);
                            try {
                              await extensionChannel.invokeMethod(
                                  'openArtifact', {
                                'extensionId': extension.id,
                                'id': item['id']
                              });
                            } catch (e) {
                              if (mounted) {
                                setState(
                                    () => error = 'Could not open audio: $e');
                              }
                            }
                          }),
                  ]))));
    } catch (e) {
      if (mounted) setState(() => error = e.toString());
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Extensions')),
        body: busy
            ? const Center(child: CircularProgressIndicator())
            : ListView(padding: const EdgeInsets.all(16), children: [
                const Text(
                    'Extensions add AI tools and connect directly to external services. No Anx backend is involved.'),
                const SizedBox(height: 12),
                FilledButton.icon(
                    onPressed: Platform.isAndroid ? _install : null,
                    icon: const Icon(Icons.extension_outlined),
                    label: const Text('Install extension (.anxplugin)')),
                if (!Platform.isAndroid)
                  const Text('Extension execution currently requires Android.'),
                if (error != null)
                  Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(error!)),
                for (final extension in manager.installed.values)
                  Card(
                      child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                ListTile(
                                    contentPadding: EdgeInsets.zero,
                                    leading:
                                        const Icon(Icons.extension_outlined),
                                    title: Text(extension.name),
                                    subtitle: Text(
                                        '${extension.version} · ${extension.tools.length} AI tools')),
                                for (final permission in extension.permissions)
                                  SwitchListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(
                                          _permissionLabels[permission] ??
                                              permission),
                                      value: manager.grants[extension.id]
                                              ?.contains(permission) ??
                                          false,
                                      onChanged: (value) async {
                                        try {
                                          await manager.setPermission(
                                              extension.id, permission, value);
                                          if (mounted) setState(() {});
                                        } catch (e) {
                                          if (mounted) {
                                            setState(
                                                () => error = e.toString());
                                          }
                                        }
                                      }),
                                if (extension.manifest['authUrl'] != null)
                                  OutlinedButton.icon(
                                      onPressed: () => _signIn(extension),
                                      icon: const Icon(Icons.login),
                                      label: const Text('Sign in')),
                                TextButton.icon(
                                    onPressed: () => _artifacts(extension),
                                    icon: const Icon(Icons.headphones),
                                    label: const Text('Downloaded audio')),
                                const Text(
                                    'After signing in, return to the AI chat to use this extension.'),
                              ]))),
              ]),
      );
}
