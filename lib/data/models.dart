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
  }) = _ChatThread;
}

enum MessageStatus { queued, running, done, failed }

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
    String? error,
    String? placement,
    String? accountId,
  }) = _ChatMessage;
}

/// The Mac worker's or the cloud runner's last report (`status/mac`,
/// `status/cloud`).
@freezed
abstract class HostStatus with _$HostStatus {
  const factory HostStatus({
    DateTime? lastSeen,
    String? host,
    @Default(<String>[]) List<String> agents,
    DateTime? startedAt,
    String? revision,
    DateTime? lastRunAt,
    String? lastResult,
    String? claudeVersion,
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
    String? error,
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
    DateTime? createdAt,
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
