import 'package:freezed_annotation/freezed_annotation.dart';

part 'models.freezed.dart';

/// A conversation with one agent (`threads/{id}` in the platform database).
@freezed
abstract class ChatThread with _$ChatThread {
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
  }) = _ChatThread;
}

enum MessageStatus { queued, running, done, failed, cancelled }

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

    /// The operator stopped the turn; this is what it had written.
    @Default(false) bool stopped,
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
  }) = _HostStatus;
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

/// A Devstation (`devstations/{id}`), written by the Factory's provisioning.
@freezed
abstract class Devstation with _$Devstation {
  const factory Devstation({
    required String id,
    required String project,
    required String state,
    required String desired,
    String? machineType,
    String? zone,
    String? repoUrl,
    String? instance,
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
