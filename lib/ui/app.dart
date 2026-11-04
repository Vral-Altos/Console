import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/firebase.dart';
import '../data/providers.dart';
import 'shell.dart';
import 'theme.dart';

class ConsoleApp extends ConsumerWidget {
  const ConsoleApp({super.key, this.fonts = true});

  /// Load the Console's web fonts (tests use the platform's).
  final bool fonts;

  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
    title: 'Vral Altos Console',
    debugShowCheckedModeBanner: false,
    theme: consoleTheme(Brightness.light, fonts: fonts),
    darkTheme: consoleTheme(Brightness.dark, fonts: fonts),
    themeMode: ref.watch(themeModeProvider),
    home: const AuthGate(),
  );
}

/// Signed-in owner → the Console; anyone else → the sign-in page.
class AuthGate extends ConsumerWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(firebaseAuthProvider);
    if (auth == null) {
      return const _Notice(
        icon: Icons.cloud_off,
        title: 'No Firebase configured',
        body: 'This build has no Firebase configuration. Build with '
            '--dart-define-from-file=.env.',
      );
    }
    return ref.watch(authStateProvider).when(
      loading: () => const Scaffold(body: Center(child: CircularProgressIndicator())),
      error: (e, _) => _Notice(icon: Icons.error_outline, title: 'Sign-in failed', body: '$e'),
      data: (user) {
        if (user == null) return SignInPage(auth: auth);
        if (!ownerEmails.contains(user.email) || !user.emailVerified) {
          return _Notice(
            icon: Icons.lock_outline,
            title: 'Not authorised',
            body: '${user.email} cannot use this Console.',
            action: TextButton(onPressed: auth.signOut, child: const Text('Sign out')),
          );
        }
        return const Shell();
      },
    );
  }
}

class SignInPage extends StatefulWidget {
  const SignInPage({super.key, required this.auth});
  final FirebaseAuth auth;

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  String? _error;
  bool _busy = false;

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.auth.signInWithPopup(GoogleAuthProvider()..setCustomParameters({'prompt': 'select_account'}));
    } on FirebaseAuthException catch (e) {
      if (mounted) setState(() => _error = e.message ?? e.code);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => _Notice(
    icon: Icons.hub_outlined,
    title: 'Vral Altos Console',
    body: _error ?? 'Sign in with your Google account.',
    action: FilledButton.icon(
      onPressed: _busy ? null : _signIn,
      icon: const Icon(Icons.login),
      label: const Text('Sign in with Google'),
    ),
  );
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.title, required this.body, this.action});
  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).extension<Tokens>();
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(28, 32, 28, 28),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        color: scheme.primary.withValues(alpha: .12),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(icon, size: 28, color: scheme.primary),
                    ),
                    const SizedBox(height: 18),
                    Text(title, style: Theme.of(context).textTheme.titleLarge, textAlign: TextAlign.center),
                    const SizedBox(height: 8),
                    Text(body, textAlign: TextAlign.center, style: TextStyle(color: t?.muted)),
                    if (action != null) ...[const SizedBox(height: 22), action!],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
