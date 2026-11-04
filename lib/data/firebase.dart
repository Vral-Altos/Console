import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

typedef FirebaseServices = ({FirebaseAuth auth, FirebaseFirestore db});

/// The platform database (the `(default)` one is Financier's).
const platformDatabase = 'platform';

/// The operator's Google accounts: the only ones the Console (and the
/// platform database's rules, `firestore.rules`) let in.
const ownerEmails = {'obsidian.infinitum@gmail.com', 'siddharth.chitikela@gmail.com'};

/// Connects to Firebase from compile-time values (`--dart-define-from-file=.env`).
/// Debug builds use the local emulators only; release builds the live
/// project. Returns null when no Firebase configuration was compiled in.
Future<FirebaseServices?> initializeFirebase() async {
  const apiKey = String.fromEnvironment('FIREBASE_API_KEY');
  const appId = String.fromEnvironment('FIREBASE_APP_ID');
  const senderId = String.fromEnvironment('FIREBASE_MESSAGING_SENDER_ID');
  const projectId = String.fromEnvironment('FIREBASE_PROJECT_ID');
  const authDomain = String.fromEnvironment('FIREBASE_AUTH_DOMAIN');
  if (apiKey.isEmpty || appId.isEmpty || projectId.isEmpty) return null;

  final app = await Firebase.initializeApp(
    options: FirebaseOptions(
      apiKey: apiKey,
      appId: appId,
      messagingSenderId: senderId,
      projectId: projectId,
      authDomain: authDomain.isEmpty ? null : authDomain,
    ),
  );
  final auth = FirebaseAuth.instanceFor(app: app);
  final db = FirebaseFirestore.instanceFor(app: app, databaseId: platformDatabase);
  db.settings = const Settings(webExperimentalAutoDetectLongPolling: true);
  if (kDebugMode) {
    await auth.useAuthEmulator('localhost', 9099);
    db.useFirestoreEmulator('localhost', 8080);
  }
  return (auth: auth, db: db);
}
