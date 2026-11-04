import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/console_repository.dart';
import 'data/firebase.dart';
import 'data/telemetry.dart';
import 'data/providers.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final firebase = await initializeFirebase();
  // The Console's own errors go to the logs (source `console`).
  if (firebase != null) ClientErrors(ConsoleRepository(firebase.db)).install();
  runApp(
    ProviderScope(
      overrides: [
        firebaseAuthProvider.overrideWithValue(firebase?.auth),
        firestoreProvider.overrideWithValue(firebase?.db),
      ],
      child: const ConsoleApp(),
    ),
  );
}
