import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';

/// Gmail sign-in using an App Password.
///
/// An App Password is used rather than Google OAuth because `gmail.readonly` is
/// a restricted scope: a published OAuth app would need a paid Google security
/// assessment, while an App Password needs nothing but the user's own account.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final GlobalKey<FormState> _form = GlobalKey<FormState>();

  bool _busy = false;
  bool _obscure = true;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_form.currentState?.validate() ?? false)) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final error = await appState.signIn(
      email: _email.text,
      appPassword: _password.text,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Form(
            key: _form,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                const SizedBox(height: 24),
                Icon(
                  Icons.mark_email_unread_outlined,
                  size: 56,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(height: 16),
                Text(
                  'Important Mail',
                  style: theme.textTheme.headlineSmall,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                Text(
                  'Connect your Gmail inbox. The app reads it, scores every '
                  'message against your rules, and notifies you about '
                  'interviews, offers and assessments.',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                TextFormField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  autocorrect: false,
                  decoration: const InputDecoration(
                    labelText: 'Gmail address',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.alternate_email),
                  ),
                  validator: (String? value) {
                    final text = value?.trim() ?? '';
                    if (!text.contains('@') || !text.contains('.')) {
                      return 'Enter a full email address.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _password,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    labelText: 'App Password (16 characters)',
                    border: const OutlineInputBorder(),
                    prefixIcon: const Icon(Icons.key),
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: (String? value) {
                    final stripped = (value ?? '').replaceAll(
                      RegExp(r'\s+'),
                      '',
                    );
                    if (stripped.length != 16) {
                      return 'App Passwords are exactly 16 characters.';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 8),
                const _AppPasswordHelp(),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(
                          Icons.error_outline,
                          color: theme.colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _error!,
                            style: TextStyle(
                              color: theme.colorScheme.onErrorContainer,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _busy ? null : _submit,
                  icon: _busy
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.login),
                  label: Text(_busy ? 'Checking…' : 'Connect'),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
                const SizedBox(height: 16),
                Text(
                  'The password is stored in the Android Keystore on this '
                  'device only. Nothing is sent anywhere except to '
                  'imap.gmail.com.',
                  style: theme.textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _AppPasswordHelp extends StatelessWidget {
  const _AppPasswordHelp();

  static const String _url =
      'https://myaccount.google.com/apppasswords';

  @override
  Widget build(BuildContext context) => Theme(
    // Removes the divider lines an ExpansionTile draws by default, which look
    // out of place inside a form.
    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
    child: ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 8),
      leading: const Icon(Icons.help_outline),
      title: const Text('How do I get an App Password?'),
      children: <Widget>[
        const Align(
          alignment: Alignment.centerLeft,
          child: Text(
            '1. Turn on 2-Step Verification for your Google account. App '
            'Passwords do not exist without it.\n'
            '2. Open the App Passwords page.\n'
            '3. Type any name, for example "Important Mail", and create it.\n'
            '4. Copy the 16-character code Google shows and paste it above. '
            'Spaces are ignored.\n\n'
            'This is not your Google account password. It grants mail access '
            'only, and you can revoke it from the same page at any time.',
          ),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('Copy the App Passwords link'),
            onPressed: () async {
              await Clipboard.setData(const ClipboardData(text: _url));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Link copied: $_url')),
              );
            },
          ),
        ),
      ],
    ),
  );
}
