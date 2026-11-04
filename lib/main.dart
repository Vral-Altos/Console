import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'data/firebase.dart';
import 'data/providers.dart';
import 'ui/app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final firebase = await initializeFirebase();
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
