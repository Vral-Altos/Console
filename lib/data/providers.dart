import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'console_repository.dart';
import 'models.dart';

/// Overridden in main() with the initialised services (null: not configured).
final firebaseAuthProvider = Provider<FirebaseAuth?>((ref) => null);
final firestoreProvider = Provider<FirebaseFirestore?>((ref) => null);

final authStateProvider = StreamProvider<User?>((ref) {
  final auth = ref.watch(firebaseAuthProvider);
  return auth == null ? Stream.value(null) : auth.authStateChanges();
});

final repositoryProvider = Provider<ConsoleRepository?>((ref) {
  final db = ref.watch(firestoreProvider);
  return db == null ? null : ConsoleRepository(db);
});

ConsoleRepository _repo(Ref ref) => ref.watch(repositoryProvider)!;

final threadsProvider = StreamProvider<List<ChatThread>>((ref) => _repo(ref).threads());
final messagesProvider = StreamProvider.family<List<ChatMessage>, String>(
  (ref, threadId) => _repo(ref).messages(threadId),
);
final macStatusProvider = StreamProvider<HostStatus?>((ref) => _repo(ref).hostStatus('mac'));
final cloudStatusProvider = StreamProvider<HostStatus?>((ref) => _repo(ref).hostStatus('cloud'));
final meshProvider = StreamProvider<MeshView?>((ref) => _repo(ref).mesh());
final portfolioSyncProvider = StreamProvider<PortfolioSync?>((ref) => _repo(ref).portfolioSync());
final devstationsProvider = StreamProvider<List<Devstation>>((ref) => _repo(ref).devstations());

/// The selected thread on the Chat page (null: a new conversation).
final selectedThreadProvider = NotifierProvider<SelectedThread, String?>(SelectedThread.new);

class SelectedThread extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

/// Whether the Mac worker is serving: its heartbeat is fresh.
bool macIsOn(HostStatus? mac, DateTime now) =>
    mac?.lastSeen != null && now.difference(mac!.lastSeen!) < const Duration(minutes: 2);
