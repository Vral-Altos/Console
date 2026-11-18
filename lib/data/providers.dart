import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'attachments.dart';
import 'console_repository.dart';
import 'models.dart';
import 'telemetry.dart';

/// Overridden in main() with the initialised services (null: not configured).
final firebaseAuthProvider = Provider<FirebaseAuth?>((ref) => null);
final firestoreProvider = Provider<FirebaseFirestore?>((ref) => null);

/// Chat attachments' storage (null: not configured).
final attachmentStoreProvider = Provider<AttachmentStore?>((ref) => null);

/// An attachment's bytes, for previews and downloads (kept while shown).
final attachmentBytesProvider = FutureProvider.autoDispose.family<Uint8List?, AttachmentRef>((ref, a) async {
  final store = ref.watch(attachmentStoreProvider);
  return store?.read(a);
});

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
final chatProjectsProvider = StreamProvider<List<ChatProject>>((ref) => _repo(ref).chatProjects());
final messagesProvider = StreamProvider.family<List<ChatMessage>, String>(
  (ref, threadId) => _repo(ref).messages(threadId),
);
final activeMessagesProvider = StreamProvider<List<ChatMessage>>((ref) => _repo(ref).activeMessages());
final macStatusProvider = StreamProvider<HostStatus?>((ref) => _repo(ref).hostStatus('mac'));
final cloudStatusProvider = StreamProvider<HostStatus?>((ref) => _repo(ref).hostStatus('cloud'));
final allStatusProvider = StreamProvider<Map<String, HostStatus>>((ref) => _repo(ref).allStatus());
final meshProvider = StreamProvider<MeshView?>((ref) => _repo(ref).mesh());
final topologyProvider = StreamProvider<TopologyInventory?>((ref) => _repo(ref).topology());
final portfolioSyncProvider = StreamProvider<PortfolioSync?>((ref) => _repo(ref).portfolioSync());
final usageStatsProvider = StreamProvider<UsageStats?>((ref) => _repo(ref).usageStats());
final usageDaysProvider = StreamProvider<List<UsageDay>>((ref) => _repo(ref).usageDays());
final billingProvider = StreamProvider<BillingView?>((ref) => _repo(ref).billing());
final billingBreakdownProvider = StreamProvider<BillingBreakdown?>((ref) => _repo(ref).billingBreakdown());
final devstationsProvider = StreamProvider<List<Devstation>>((ref) => _repo(ref).devstations());
final factoryRequestsProvider =
    StreamProvider<List<FactoryRequest>>((ref) => _repo(ref).factoryRequests());
final approvalsProvider = StreamProvider<List<Approval>>((ref) => _repo(ref).approvals());
final logsProvider = StreamProvider.family<List<LogEntry>, LogQuery>(
  (ref, q) => _repo(ref).logs(
    from: q.from,
    source: q.source,
    severities: q.severities.isEmpty ? null : q.severities,
    components: q.components.isEmpty ? null : q.components,
    limit: q.limit,
  ),
);

/// Metric hours since the given UTC hour (the caller rounds it, so the
/// stream is reused across rebuilds).
final metricsProvider = StreamProvider.family<List<MetricHour>, DateTime>((ref, from) => _repo(ref).metrics(from: from));

/// Ticks every 15 s, so freshness ("is the Mac serving?") is re-judged even
/// when nothing in the database changes (a stopped worker writes nothing).
final clockProvider = StreamProvider<DateTime>(
  (ref) => Stream.periodic(const Duration(seconds: 15), (_) => DateTime.now()),
);

/// Every agent some host runs, with its description; Genie first.
final agentsProvider = Provider<List<({String name, String? description})>>((ref) {
  final hosts = ref.watch(allStatusProvider).value ?? const {};
  final info = <String, String?>{'genie': null};
  for (final h in hosts.values) {
    for (final a in h.agents) {
      info[a] = h.agentInfo[a] ?? info[a];
    }
  }
  final names = info.keys.toList()
    ..sort((a, b) => a == 'genie' ? -1 : (b == 'genie' ? 1 : a.compareTo(b)));
  return [for (final n in names) (name: n, description: info[n])];
});

/// Each agent's own model and effort, as its hosts report them.
final agentDefaultsProvider = Provider<Map<String, ({String? model, String? effort})>>((ref) {
  final hosts = ref.watch(allStatusProvider).value ?? const {};
  final out = <String, ({String? model, String? effort})>{};
  for (final h in hosts.values) {
    for (final a in h.agents) {
      final prev = out[a];
      out[a] = (model: h.agentModels[a] ?? prev?.model, effort: h.agentEfforts[a] ?? prev?.effort);
    }
  }
  return out;
});

/// The Console's pages.
enum ConsolePage { overview, chat, projects, topology, billing, logs, system }

final pageProvider = NotifierProvider<PageNotifier, ConsolePage>(PageNotifier.new);

class PageNotifier extends Notifier<ConsolePage> {
  @override
  ConsolePage build() => ConsolePage.overview;
  void go(ConsolePage page) => state = page;
}

/// The selected thread on the Chat page (null: a new conversation).
final selectedThreadProvider = NotifierProvider<SelectedThread, String?>(SelectedThread.new);

class SelectedThread extends Notifier<String?> {
  @override
  String? build() => null;
  void select(String? id) => state = id;
}

/// The agent a new conversation goes to.
final newChatAgentProvider = NotifierProvider<NewChatAgent, String>(NewChatAgent.new);

class NewChatAgent extends Notifier<String> {
  @override
  String build() => 'genie';
  void set(String agent) => state = agent;
}

/// Opens the Chat page on [threadId], or on a new conversation with [agent].
void openChat(WidgetRef ref, {String? threadId, String? agent}) {
  if (agent != null) ref.read(newChatAgentProvider.notifier).set(agent);
  ref.read(selectedThreadProvider.notifier).select(threadId);
  ref.read(pageProvider.notifier).go(ConsolePage.chat);
}

/// How the conversations are grouped in the sidebar.
enum ThreadGrouping { recent, project, purpose }

final threadGroupingProvider = NotifierProvider<ThreadGroupingNotifier, ThreadGrouping>(ThreadGroupingNotifier.new);

class ThreadGroupingNotifier extends Notifier<ThreadGrouping> {
  @override
  ThreadGrouping build() => ThreadGrouping.project;
  void set(ThreadGrouping g) => state = g;
}

/// The project a new conversation is filed under: null = let the namer
/// choose; `(project: null)` = General.
final newChatProjectProvider = NotifierProvider<NewChatProject, ({String? project})?>(NewChatProject.new);

class NewChatProject extends Notifier<({String? project})?> {
  @override
  ({String? project})? build() => null;
  void set(({String? project})? filing) => state = filing;
}

/// Unsent text per conversation (key `new` for a new one), kept while the
/// Console is open.
final draftsProvider = NotifierProvider<Drafts, Map<String, String>>(Drafts.new);

class Drafts extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => const {};
  void set(String key, String text) => state = {...state, key: text};
}

/// Whether a worker is serving: its heartbeat is fresh (2 minutes).
bool isFresh(HostStatus? host, DateTime now) =>
    host?.lastSeen != null && now.difference(host!.lastSeen!) < const Duration(minutes: 2);

bool macIsOn(HostStatus? mac, DateTime now) => isFresh(mac, now);

/// The operator's day (`yyyy-mm-dd`, UTC+8), as the workers count usage.
String operatorDay(DateTime t) =>
    t.toUtc().add(const Duration(hours: 8)).toIso8601String().substring(0, 10);
