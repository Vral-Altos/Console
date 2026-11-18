import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'console_repository.dart';
import 'models.dart';
import 'telemetry.dart';

/// Overridden in main() with the initialised services (null: not configured).
final firebaseAuthProvider = Provider<FirebaseAuth?>((ref) => null);
final firestoreProvider = Provider<FirebaseFirestore?>((ref) => null);

/// An attachment's bytes, for previews and downloads (kept while shown).
final authStateProvider = StreamProvider<User?>((ref) {
  final auth = ref.watch(firebaseAuthProvider);
  return auth == null ? Stream.value(null) : auth.authStateChanges();
});

final repositoryProvider = Provider<ConsoleRepository?>((ref) {
  final db = ref.watch(firestoreProvider);
  return db == null ? null : ConsoleRepository(db);
});

ConsoleRepository _repo(Ref ref) => ref.watch(repositoryProvider)!;

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

/// The Console's pages.
enum ConsolePage { overview, projects, topology, billing, logs, system }

final pageProvider = NotifierProvider<PageNotifier, ConsolePage>(PageNotifier.new);

class PageNotifier extends Notifier<ConsolePage> {
  @override
  ConsolePage build() => ConsolePage.overview;
  void go(ConsolePage page) => state = page;
}

/// Genie (genie.vraltos.dev), the agentic chat: conversations open there.
const genieUrl = 'https://genie.vraltos.dev/';

/// Opens [threadId] in Genie, or a new conversation with [agent] (in
/// [folder]), in a new tab.
void openInGenie({String? threadId, String? agent, String? folder}) {
  final uri = Uri.parse(genieUrl).replace(queryParameters: {
    't': ?threadId,
    if (threadId == null) 'a': ?agent,
    if (threadId == null) 'f': ?folder,
  });
  unawaited(launchUrl(uri, webOnlyWindowName: '_blank'));
}

/// Whether a worker is serving: its heartbeat is fresh (2 minutes).
bool isFresh(HostStatus? host, DateTime now) =>
    host?.lastSeen != null && now.difference(host!.lastSeen!) < const Duration(minutes: 2);

bool macIsOn(HostStatus? mac, DateTime now) => isFresh(mac, now);

/// The operator's day (`yyyy-mm-dd`, UTC+8), as the workers count usage.
String operatorDay(DateTime t) =>
    t.toUtc().add(const Duration(hours: 8)).toIso8601String().substring(0, 10);
