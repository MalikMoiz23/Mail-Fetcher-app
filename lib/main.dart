import 'package:flutter/material.dart';

import 'services/background.dart';
import 'state/app_state.dart';
import 'ui/home_screen.dart';
import 'ui/login_screen.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const InboxTriageApp());
}

class InboxTriageApp extends StatelessWidget {
  const InboxTriageApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Important Mail',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    home: const _Boot(),
  );
}

/// Runs one-time startup in order: WorkManager must be initialized before
/// [AppState.boot] can register the periodic task.
class _Boot extends StatefulWidget {
  const _Boot();

  @override
  State<_Boot> createState() => _BootState();
}

class _BootState extends State<_Boot> {
  late final Future<void> _startup = _run();

  Future<void> _run() async {
    await BackgroundScheduler.initialize();
    await appState.boot();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: _startup,
    builder: (BuildContext context, AsyncSnapshot<void> snapshot) {
      if (snapshot.hasError) {
        return _StartupError(error: snapshot.error!);
      }
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: _Splash());
      }
      return ListenableBuilder(
        listenable: appState,
        builder: (BuildContext context, Widget? child) =>
            appState.isSignedIn ? const HomeScreen() : const LoginScreen(),
      );
    },
  );
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Icon(
            Icons.mark_email_unread_outlined,
            size: 40,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 20),
          const SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ],
      ),
    );
  }
}

class _StartupError extends StatelessWidget {
  const _StartupError({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const Icon(Icons.error_outline, size: 48),
          const SizedBox(height: 16),
          Text(
            'The app failed to start.',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text('$error', textAlign: TextAlign.center),
        ],
      ),
    ),
  );
}
