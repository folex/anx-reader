import 'package:anx_reader/service/chatgpt/network_error.dart';
import 'package:anx_reader/service/chatgpt/network_diagnostics.dart';
import 'package:anx_reader/utils/app_version.dart';
import 'package:flutter/services.dart';
import 'package:anx_reader/service/chatgpt/chatgpt_plan.dart';
import 'package:flutter/material.dart';
import 'package:langchain_core/chat_models.dart';

Future<void> showChatGptPlanSettings(BuildContext context) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const SingleChildScrollView(
        child: Padding(padding: EdgeInsets.all(16), child: ChatGptPlanCard()),
      ),
    );

class ChatGptPlanCard extends StatefulWidget {
  const ChatGptPlanCard({super.key});
  @override
  State<ChatGptPlanCard> createState() => _ChatGptPlanCardState();
}

class _ChatGptPlanCardState extends State<ChatGptPlanCard> {
  final plan = ChatGptPlan.instance;
  bool busy = false;
  String? status;
  late final Future<String> appVersion = getAppVersion();
  @override
  void initState() {
    super.initState();
    plan.addListener(_changed);
    _run(plan.initialize);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    plan.removeListener(_changed);
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    if (busy) return;
    setState(() {
      busy = true;
      status = null;
    });
    try {
      await action();
    } catch (error) {
      if (mounted)
        setState(() {
          status = chatGptConnectionError(error);
        });
    } finally {
      if (mounted)
        setState(() {
          busy = false;
        });
    }
  }

  Future<void> _diagnostics() async {
    final version = await appVersion.catchError((_) => 'unknown');
    final networkReport = await ChatGptNetworkDiagnostics.run();
    final report = 'Anx Reader $version\n$networkReport';
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Network diagnostics'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: SelectableText(
              report,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: report));
              if (dialogContext.mounted) {
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('Report copied')),
                );
              }
            },
            child: const Text('Copy report'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _models() async {
    final account = plan.active;
    final models = await plan.models();
    if (!mounted || account != plan.active) return;
    if (models.isEmpty) {
      setState(() {
        status = 'No models available.';
      });
      return;
    }
    final selected = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('ChatGPT model'),
        children: models
            .map(
              (model) => SimpleDialogOption(
                onPressed: () => Navigator.pop(context, model['slug']),
                child: Text(
                  '${model['name']}${model['slug'] == account?.model ? ' ✓' : ''}',
                ),
              ),
            )
            .toList(),
      ),
    );
    if (selected != null && account == plan.active)
      await plan.setModel(selected);
  }

  @override
  Widget build(BuildContext context) {
    final account = plan.active;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'ChatGPT · my subscription',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        FutureBuilder<String>(
          future: appVersion,
          builder: (context, snapshot) => Text(
            'Anx version: ${snapshot.data ?? (snapshot.hasError ? 'unknown' : '…')}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Works directly on your phone. Anx keeps a separate chat for each book and account. Usage counts toward your ChatGPT subscription limits.',
        ),
        if (plan.accounts.isNotEmpty) ...[
          const SizedBox(height: 8),
          DropdownButton<String>(
            isExpanded: true,
            value: account?.id,
            hint: const Text('Select an account'),
            items: plan.accounts
                .map(
                  (a) => DropdownMenuItem(
                    value: a.id,
                    child: Text(a.label, overflow: TextOverflow.ellipsis),
                  ),
                )
                .toList(),
            onChanged: busy
                ? null
                : (value) {
                    if (value != null) _run(() => plan.selectAccount(value));
                  },
          ),
        ],
        if (account != null) ...[
          Text(
            !account.signedIn
                ? 'Account disconnected'
                : account.planAllowed
                ? 'Connected. The first response confirms access.'
                : 'Signed in, but subscription access was not granted.',
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Use ChatGPT in the reader'),
            value: plan.enabled,
            onChanged: busy || !account.signedIn
                ? null
                : (value) => _run(() => plan.setEnabled(value)),
          ),
          Text(
            'Model: ${account.model.isEmpty ? 'not selected' : account.model}',
          ),
        ],
        if (plan.initializationError != null)
          TextButton(
            onPressed: busy ? null : () => _run(plan.resetBrokenConnection),
            child: const Text(
              'Reset connection and sign in again',
            ),
          ),
        Wrap(
          spacing: 8,
          children: [
            FilledButton(
              onPressed: busy
                  ? null
                  : () => _run(() async {
                      await plan.signIn();
                      if (plan.active?.planAllowed == true) await _models();
                    }),
              child: const Text('Continue with ChatGPT'),
            ),
            if (plan.hasPendingRegistration)
              TextButton(
                onPressed: busy
                    ? null
                    : () => _run(() async {
                        await plan.signIn(retryRegistration: true);
                        if (plan.active?.planAllowed == true) await _models();
                      }),
                child: const Text('Resume sign-in'),
              ),
            if (account != null)
              TextButton(
                onPressed: busy
                    ? null
                    : () => _run(() async {
                        await plan.signIn(returning: account);
                        if (plan.active?.planAllowed == true) await _models();
                      }),
                child: const Text('Reconnect'),
              ),
            if (account?.signedIn == true)
              TextButton(
                onPressed: busy ? null : () => _run(_models),
                child: const Text('Choose model'),
              ),
            if (account?.signedIn == true && account?.model.isNotEmpty == true)
              TextButton(
                onPressed: busy
                    ? null
                    : () => _run(() async {
                        await for (final _ in plan.generate([
                          ChatMessage.humanText('Reply exactly: OK'),
                        ])) {}
                        if (mounted)
                          setState(() {
                            status = 'Response completed: your subscription works in Anx.';
                          });
                      }),
                child: const Text('Test response'),
              ),
            if (account?.signedIn == true)
              TextButton(
                onPressed: busy
                    ? null
                    : () => _run(() async {
                        final revoked = await plan.signOut();
                        if (mounted)
                          setState(() {
                            status = revoked
                                ? 'Signed out of ChatGPT.'
                                : 'Signed out locally. Server revocation was not confirmed; you can disconnect the app in ChatGPT settings.';
                          });
                      }),
                child: const Text('Sign out'),
              ),
            if (plan.signingIn)
              TextButton(
                onPressed: plan.cancelSignIn,
                child: const Text('Cancel sign-in'),
              ),
          ],
        ),
        TextButton.icon(
          onPressed: busy ? null : () => _run(_diagnostics),
          icon: const Icon(Icons.network_check),
          label: const Text('Network diagnostics'),
        ),
        const Text(
          'Checks connectivity without signing in or querying your account. You can copy the report.',
        ),
        if (busy) const LinearProgressIndicator(),
        if (status != null)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text(status!)),
      ],
    );
  }
}
