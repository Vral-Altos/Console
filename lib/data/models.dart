import 'package:freezed_annotation/freezed_annotation.dart';

part 'models.freezed.dart';

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

    /// Agent name → its own model and effort (`agent.json`, `settings.json`).
    @Default(<String, String>{}) Map<String, String> agentModels,
    @Default(<String, String>{}) Map<String, String> agentEfforts,
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
