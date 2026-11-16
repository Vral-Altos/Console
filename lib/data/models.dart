import 'package:freezed_annotation/freezed_annotation.dart';

part 'models.freezed.dart';

/// What a conversation is for (`threads/{id}.purpose`), as the namer files
/// it; the Console groups by it.
enum ChatPurpose {
  build('Build'),
  fix('Fix'),
  research('Research'),
  plan('Plan'),
  advice('Advice'),
  ops('Ops'),
  admin('Admin'),
  other('Other');

  const ChatPurpose(this.label);
  final String label;

  static ChatPurpose? parse(Object? v) => values.where((p) => p.name == v).firstOrNull;
}

/// A conversation with one agent (`threads/{id}` in the platform database).
/// [title] is its topic; the Console shows it as [ChatNaming.name].
@freezed
abstract class ChatThread with _$ChatThread {
  const ChatThread._();
  const factory ChatThread({
    required String id,
    required String agent,
    required String title,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? lastMessage,
    @Default(false) bool closed,
    @Default(false) bool pinned,
    @Default(false) bool archived,

    /// A chat project's name; null = General.
    String? project,
    ChatPurpose? purpose,

    /// Every reply's API-equivalent cost plus the naming run's (workers).
    @Default(0) double costUsd,

    /// The namer has filed it (project, purpose, topic).
    DateTime? namedAt,

    /// The agent that posted it, for a conversation between agents.
    String? from,
  }) = _ChatThread;

  /// The project it is listed under.
  String get projectName => project ?? 'General';
}

/// A project conversations are filed under (`chat_projects/{id}`).
@freezed
abstract class ChatProject with _$ChatProject {
  const factory ChatProject({required String id, required String name, DateTime? createdAt}) = _ChatProject;
}

/// An account's usage windows when a reply finished (`messages/{id}.quota`).
@freezed
abstract class QuotaView with _$QuotaView {
  const factory QuotaView({UsageView? fiveHour, UsageView? sevenDay}) = _QuotaView;
}

enum MessageStatus { queued, running, done, failed, cancelled }

/// A file attached to an operator message: an object in the attachments
/// bucket (`attachments/<upload id>/<name>`).
@freezed
abstract class AttachmentRef with _$AttachmentRef {
  const AttachmentRef._();
  const factory AttachmentRef({
    required String path,
    required String name,
    String? contentType,
    int? size,
  }) = _AttachmentRef;

  bool get isImage => const {'image/png', 'image/jpeg', 'image/gif', 'image/webp'}.contains(contentType);

  Map<String, Object?> toFirestore() => {'path': path, 'name': name, 'contentType': ?contentType, 'size': ?size};
}

enum MentionKind { thread, project, agent }

/// Something an operator message @mentions: the worker gives the agent its
/// context (a conversation's messages, a project's Devstation, an agent to
/// consult).
@freezed
abstract class MentionRef with _$MentionRef {
  const MentionRef._();
  const factory MentionRef({required MentionKind kind, required String id, required String label}) = _MentionRef;

  /// How it reads in the message text.
  String get token => '@$label';

  Map<String, Object?> toFirestore() => {'kind': kind.name, 'id': id, 'label': label};
}

/// One message of a thread (`messages/{id}`).
@freezed
abstract class ChatMessage with _$ChatMessage {
  const factory ChatMessage({
    required String id,
    required String threadId,
    required bool fromOperator,
    required String text,
    @Default('turn') String kind,
    DateTime? createdAt,
    MessageStatus? status,
    String? claimedBy,
    DateTime? claimedAt,
    DateTime? finishedAt,
    String? error,
    String? placement,
    String? accountId,

    /// While running: the reply so far, and what the agent is doing.
    String? partial,
    String? activity,
    @Default(<String>[]) List<String> tools,
    @Default(false) bool cancelRequested,

    /// Agent replies: what the turn cost (API-equivalent), produced and took.
    double? costUsd,
    int? outputTokens,
    int? contextTokens,
    int? durationMs,
    String? model,

    /// The account's 5-hour and 7-day usage after the turn.
    QuotaView? quota,

    /// The operator stopped the turn; this is what it had written.
    @Default(false) bool stopped,

    /// Operator messages: files and @mentions sent with the text.
    @Default(<AttachmentRef>[]) List<AttachmentRef> attachments,
    @Default(<MentionRef>[]) List<MentionRef> mentions,
  }) = _ChatMessage;
}

/// A host's latest load reading (`status/<host>.metrics`).
@freezed
abstract class HostMetricsView with _$HostMetricsView {
  const factory HostMetricsView({
    DateTime? at,
    @Default(0) int cores,
    double? cpu,
    int? memUsed,
    int? memTotal,
    int? diskUsed,
    int? diskTotal,
    double? load1,
    int? rss,
  }) = _HostMetricsView;
}

/// One point of a host's recent load (CPU and memory fractions).
@freezed
abstract class MetricPoint with _$MetricPoint {
  const factory MetricPoint({required DateTime at, double? cpu, double? mem}) = _MetricPoint;
}

/// A worker's last report (`status/mac`, `status/cloud`,
/// `status/devstation-<id>`).
@freezed
abstract class HostStatus with _$HostStatus {
  const factory HostStatus({
    DateTime? lastSeen,
    String? host,
    @Default(<String>[]) List<String> agents,

    /// Agent name → its one-line description.
    @Default(<String, String>{}) Map<String, String> agentInfo,
    DateTime? startedAt,
    String? revision,
    DateTime? lastRunAt,
    String? lastResult,
    String? claudeVersion,
    String? devstation,
    HostMetricsView? metrics,
    @Default(<MetricPoint>[]) List<MetricPoint> history,

    /// The Mac's own services (launchd jobs `com.vralaltos.*`).
    @Default(<LocalServiceView>[]) List<LocalServiceView> localServices,
  }) = _HostStatus;
}

/// One of the Mac's launchd services; [connected] for a Skyhorse bridge.
@freezed
abstract class LocalServiceView with _$LocalServiceView {
  const factory LocalServiceView({
    required String label,
    required bool running,
    int? lastExit,
    bool? connected,
    String? detail,
  }) = _LocalServiceView;
}

/// Everything Vral Altos and the operator's other projects are made of
/// (`topology/current`, kept by the Mac worker).
@freezed
abstract class TopologyInventory with _$TopologyInventory {
  const factory TopologyInventory({
    DateTime? at,
    @Default(<GcpProjectView>[]) List<GcpProjectView> projects,
    @Default(<CloudResource>[]) List<CloudResource> resources,
    @Default(<RepoView>[]) List<RepoView> repos,
    @Default(<String>[]) List<String> errors,
  }) = _TopologyInventory;
}

@freezed
abstract class GcpProjectView with _$GcpProjectView {
  const factory GcpProjectView({
    required String id,
    required String name,
    String? number,

    /// `full`, or `limited` when the operator can see but not read it.
    @Default('full') String access,
    @Default(<String, String>{}) Map<String, String> labels,
  }) = _GcpProjectView;
}

/// A cloud resource; [health] is `ok`/`warn`/`bad`/`idle` or null when
/// Google reports none.
@freezed
abstract class CloudResource with _$CloudResource {
  const factory CloudResource({
    required String id,
    required String project,
    required String type,
    required String name,
    String? location,
    String? state,
    @Default(false) bool public,
    @Default(<String>[]) List<String> publicRoles,
    @Default(<String, String>{}) Map<String, String> labels,
    String? url,
    String? ingress,
    String? health,
    String? detail,
    String? schedule,
    DateTime? lastRun,
  }) = _CloudResource;
}

/// A git checkout on the Mac.
@freezed
abstract class RepoView with _$RepoView {
  const factory RepoView({
    required String name,
    required String path,
    String? host,
    String? owner,
    String? repo,
    String? branch,
    DateTime? lastCommit,
    @Default(false) bool dirty,
    @Default(<String>[]) List<String> stack,
  }) = _RepoView;
}

@freezed
abstract class UsageView with _$UsageView {
  const factory UsageView({required double utilization, DateTime? resetsAt, String? status}) =
      _UsageView;
}

@freezed
abstract class AccountView with _$AccountView {
  const factory AccountView({
    required String id,
    required String label,
    UsageView? fiveHour,
    UsageView? sevenDay,
    DateTime? limitedUntil,
  }) = _AccountView;
}

@freezed
abstract class SessionView with _$SessionView {
  const factory SessionView({
    required String sessionId,
    required String agent,
    required String taskId,
    required String accountId,
    required String status,
    required int contextTokens,
    required int turns,
    required int compactions,
    @Default(0) double costUsd,
    @Default(0) int outputTokens,
    DateTime? createdAt,
    DateTime? lastUsedAt,
  }) = _SessionView;
}

/// The agent session registry (`agent_mesh/state`).
@freezed
abstract class MeshView with _$MeshView {
  const factory MeshView({
    @Default(<AccountView>[]) List<AccountView> accounts,
    @Default(<SessionView>[]) List<SessionView> sessions,
    DateTime? updatedAt,
  }) = _MeshView;
}

/// The Autobench copy's freshness (`autobench/latest`).
@freezed
abstract class PortfolioSync with _$PortfolioSync {
  const factory PortfolioSync({DateTime? syncedAt, String? source, String? account}) =
      _PortfolioSync;
}

/// Turn counts and cost for one slice (an agent, a host, an account).
@freezed
abstract class UsageSlice with _$UsageSlice {
  const factory UsageSlice({
    @Default(0) int turns,
    @Default(0) double costUsd,
    @Default(0) int failed,
  }) = _UsageSlice;
}

/// Chat turn totals (`stats/usage`), written by the workers.
@freezed
abstract class UsageStats with _$UsageStats {
  const factory UsageStats({
    @Default(0) int turns,
    @Default(0) double costUsd,
    @Default(0) int outputTokens,
    @Default(0) int durationMs,
    @Default(0) int failed,
    @Default(<String, UsageSlice>{}) Map<String, UsageSlice> byAgent,
    @Default(<String, UsageSlice>{}) Map<String, UsageSlice> byPlacement,
    @Default(<String, UsageSlice>{}) Map<String, UsageSlice> byAccount,
  }) = _UsageStats;
}

/// One operator day of chat turns (`usage_days/<yyyy-mm-dd>`, UTC+8).
@freezed
abstract class UsageDay with _$UsageDay {
  const factory UsageDay({
    required String day,
    @Default(0) int turns,
    @Default(0) double costUsd,
    @Default(0) int outputTokens,
    @Default(0) int durationMs,
    @Default(0) int failed,
    @Default(<String, UsageSlice>{}) Map<String, UsageSlice> byAgent,
  }) = _UsageDay;
}

/// GCP spend this month from the budget's notifications (`billing/current`).
@freezed
abstract class BillingView with _$BillingView {
  const factory BillingView({
    required double costAmount,
    double? budgetAmount,
    String? currencyCode,
    String? month,
    DateTime? updatedAt,

    /// Day (`yyyy-mm-dd`) → month-to-date cost at that day's last update.
    @Default(<String, double>{}) Map<String, double> days,
  }) = _BillingView;
}

/// Cost by project, service and SKU from the Cloud Billing export
/// (`billing/breakdown`, kept by the cloud runner). Months are invoice
/// months (`yyyy-mm`); amounts are net of credits, in [currency].
@freezed
abstract class BillingBreakdown with _$BillingBreakdown {
  const factory BillingBreakdown({
    /// `ok`, `no-export` (not switched on) or `empty` (on, nothing landed).
    required String status,
    DateTime? at,
    DateTime? exportedAt,
    String? dataset,
    String? table,
    String? currency,
    String? month,
    String? previousMonth,
    @Default(0) double total,
    @Default(0) double cost,
    @Default(0) double credits,
    @Default(0) double previousTotal,
    @Default(<BillingProject>[]) List<BillingProject> projects,
    @Default(<BillingService>[]) List<BillingService> services,
    @Default(<BillingSku>[]) List<BillingSku> skus,

    /// Operator day (`yyyy-mm-dd`) → project id (`~account` for
    /// account-level charges) → net cost that day.
    @Default(<String, Map<String, double>>{}) Map<String, Map<String, double>> days,
  }) = _BillingBreakdown;
}

@freezed
abstract class BillingProject with _$BillingProject {
  const factory BillingProject({
    required String id,
    required String name,
    @Default(0) double net,
    @Default(0) double cost,
    @Default(0) double credits,
    @Default(0) double previous,
  }) = _BillingProject;
}

@freezed
abstract class BillingService with _$BillingService {
  const factory BillingService({
    required String name,
    @Default(0) double net,
    @Default(0) double previous,
    @Default(<String, double>{}) Map<String, double> projects,
  }) = _BillingService;
}

@freezed
abstract class BillingSku with _$BillingSku {
  const factory BillingSku({
    required String service,
    required String sku,
    required String project,
    @Default(0) double net,
  }) = _BillingSku;
}

/// A Devstation (`devstations/{id}`), written by the Factory's provisioning.
@freezed
abstract class Devstation with _$Devstation {
  const factory Devstation({
    required String id,
    required String project,
    required String state,
    required String desired,
    String? machineType,
    int? diskGb,
    String? zone,
    String? repoUrl,
    String? instance,

    /// The service account it runs as (`va-ds-<id>` or `va-devstation`).
    String? identity,
    String? ip,
    String? error,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) = _Devstation;
}

/// A Factory request (`factory_requests/{id}`): queued by the Console,
/// applied by the cloud runner through Cloud Build.
@freezed
abstract class FactoryRequest with _$FactoryRequest {
  const factory FactoryRequest({
    required String id,
    required String action,
    required String devstationId,
    required String status,
    String? project,
    DateTime? createdAt,
    DateTime? finishedAt,
    String? error,
    String? buildId,
  }) = _FactoryRequest;
}

/// An agent's request for the operator's approval (`approvals/{id}`).
@freezed
abstract class Approval with _$Approval {
  const factory Approval({
    required String id,
    required String requestedBy,
    required String action,
    required String details,
    required String status,
    DateTime? createdAt,
    DateTime? decidedAt,
  }) = _Approval;
}

enum LogSeverity { debug, info, warning, error }

/// One structured log entry (`logs/{id}`), from any service or the Console.
@freezed
abstract class LogEntry with _$LogEntry {
  const factory LogEntry({
    required String id,
    required DateTime at,
    required String source,
    required String component,
    required LogSeverity severity,
    required String message,
    String? host,
    @Default(<String, Object?>{}) Map<String, Object?> fields,
  }) = _LogEntry;
}

/// One source's metrics for one UTC hour (`metrics/{source}~{yyyyMMddHH}`):
/// hour totals and per-minute values (counters added, gauges set).
@freezed
abstract class MetricHour with _$MetricHour {
  const factory MetricHour({
    required String source,
    required DateTime hour,
    @Default(<String, double>{}) Map<String, double> totals,

    /// Minute of the hour (0–59) → metric name → value.
    @Default(<int, Map<String, double>>{}) Map<int, Map<String, double>> minutes,
  }) = _MetricHour;
}
