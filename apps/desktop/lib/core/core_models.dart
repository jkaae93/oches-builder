import 'package:flutter/foundation.dart';

@immutable
class RevisionRef {
  const RevisionRef({
    required this.objectId,
    required this.storeGeneration,
    required this.revision,
  });

  final String objectId;
  final String storeGeneration;
  final String revision;

  @override
  bool operator ==(Object other) =>
      other is RevisionRef &&
      other.objectId == objectId &&
      other.storeGeneration == storeGeneration &&
      other.revision == revision;

  @override
  int get hashCode => Object.hash(objectId, storeGeneration, revision);
}

enum DesktopLocale { ko, en }

enum WorkflowStage {
  scope,
  profile,
  recommendations,
  template,
  exportDiff,
  runApproval,
  monitor,
  evaluation,
}

enum CoreConnectionState {
  checking,
  unavailable,
  connected,
  disconnected,
  reconnecting,
}

enum CapabilityBadgeStatus { supported, unsupported, unknown }

enum CostStatus {
  authoritativeBilling,
  providerReportedEstimate,
  rateTableEstimate,
  subscriptionIncluded,
  unknown,
}

enum TaskUiState {
  ready,
  prepared,
  running,
  cancelRequested,
  evaluating,
  succeeded,
  failed,
  cancelled,
  blocked,
  unknown,
}

@immutable
class ScopePreviewDraft {
  const ScopePreviewDraft({
    required this.workspaceId,
    required this.workspacePath,
    required this.scopeDigest,
    required this.includedFileCount,
    required this.excludedPatterns,
    required this.symlinkPaths,
  });

  final String workspaceId;
  final String workspacePath;
  final String scopeDigest;
  final int includedFileCount;
  final List<String> excludedPatterns;
  final List<String> symlinkPaths;
}

@immutable
class ProjectProfileSummary {
  const ProjectProfileSummary({
    required this.profileRevision,
    required this.limitsReached,
    required this.partial,
    required this.summaryNote,
    required this.uncertainties,
  });

  final RevisionRef profileRevision;
  final bool limitsReached;
  final bool partial;
  final String summaryNote;
  final List<String> uncertainties;
}

@immutable
class RecommendationCandidate {
  const RecommendationCandidate({
    required this.patternId,
    required this.title,
    required this.isSingleAgentBaseline,
    required this.capabilityStatus,
    required this.executableSupported,
    required this.claim,
    required this.alternativeNote,
    required this.uncertainties,
  });

  final String patternId;
  final String title;
  final bool isSingleAgentBaseline;
  final CapabilityBadgeStatus capabilityStatus;
  final bool executableSupported;
  final String claim;
  final String alternativeNote;
  final List<String> uncertainties;
}

@immutable
class TemplateDraftState {
  const TemplateDraftState({
    required this.instanceId,
    required this.canonicalRevision,
    required this.draftBody,
    required this.localDraftDirty,
    required this.stale,
    required this.validated,
    required this.validationErrors,
  });

  final String instanceId;
  final RevisionRef canonicalRevision;
  final String draftBody;
  final bool localDraftDirty;
  final bool stale;
  final bool validated;
  final List<String> validationErrors;

  TemplateDraftState copyWith({
    RevisionRef? canonicalRevision,
    String? draftBody,
    bool? localDraftDirty,
    bool? stale,
    bool? validated,
    List<String>? validationErrors,
  }) => TemplateDraftState(
    instanceId: instanceId,
    canonicalRevision: canonicalRevision ?? this.canonicalRevision,
    draftBody: draftBody ?? this.draftBody,
    localDraftDirty: localDraftDirty ?? this.localDraftDirty,
    stale: stale ?? this.stale,
    validated: validated ?? this.validated,
    validationErrors: validationErrors ?? this.validationErrors,
  );
}

enum MappingFidelity { exact, lossy, unsupported, unknown }

@immutable
class ExportFieldMapping {
  const ExportFieldMapping({
    required this.fieldName,
    required this.fidelity,
    required this.detail,
  });

  final String fieldName;
  final MappingFidelity fidelity;
  final String detail;
}

@immutable
class ExportDiffPlan {
  const ExportDiffPlan({
    required this.planId,
    required this.planDigest,
    required this.instanceRevision,
    required this.targetPath,
    required this.diffPreview,
    required this.mappings,
    required this.stale,
    required this.blockedByUnsupportedRequiredProperty,
  });

  final String planId;
  final String planDigest;
  final RevisionRef instanceRevision;
  final String targetPath;
  final String diffPreview;
  final List<ExportFieldMapping> mappings;
  final bool stale;
  final bool blockedByUnsupportedRequiredProperty;

  ExportDiffPlan copyWith({bool? stale}) => ExportDiffPlan(
    planId: planId,
    planDigest: planDigest,
    instanceRevision: instanceRevision,
    targetPath: targetPath,
    diffPreview: diffPreview,
    mappings: mappings,
    stale: stale ?? this.stale,
    blockedByUnsupportedRequiredProperty: blockedByUnsupportedRequiredProperty,
  );
}

@immutable
class ApplyConfigResult {
  const ApplyConfigResult({
    required this.applied,
    required this.partialOrUnknown,
    required this.detail,
  });

  final bool applied;
  final bool partialOrUnknown;
  final String detail;
}

@immutable
class ExecutionAttemptView {
  const ExecutionAttemptView({
    required this.runId,
    required this.taskId,
    required this.attemptId,
    required this.providerName,
    required this.taskState,
    required this.events,
    required this.outputTruncated,
    required this.droppedEventsCount,
    required this.cursorSequence,
    required this.cursorExpired,
  });

  final String runId;
  final String taskId;
  final String attemptId;
  final String providerName;
  final TaskUiState taskState;
  final List<String> events;
  final bool outputTruncated;
  final int droppedEventsCount;
  final int cursorSequence;
  final bool cursorExpired;
}

@immutable
class CostSummaryView {
  const CostSummaryView({
    required this.status,
    required this.currency,
    required this.amountMicroUsd,
    required this.sourceBasis,
    required this.unknownCount,
    required this.subscriptionIncludedCount,
  });

  final CostStatus status;
  final String? currency;
  final int? amountMicroUsd;
  final String sourceBasis;
  final int unknownCount;
  final int subscriptionIncludedCount;

  String formattedDisplay(DesktopLocale locale) {
    switch (status) {
      case CostStatus.unknown:
        return locale == DesktopLocale.ko
            ? 'UNKNOWN (금액 미확인 · $sourceBasis)'
            : 'UNKNOWN (amount unverified · $sourceBasis)';
      case CostStatus.subscriptionIncluded:
        return locale == DesktopLocale.ko
            ? 'SUBSCRIPTION_INCLUDED (구독 포함 사용량 · $sourceBasis)'
            : 'SUBSCRIPTION_INCLUDED (plan usage · $sourceBasis)';
      case CostStatus.authoritativeBilling:
      case CostStatus.providerReportedEstimate:
      case CostStatus.rateTableEstimate:
        final amt = amountMicroUsd;
        final curr = currency;
        if (amt == null || curr == null || curr.isEmpty) {
          return locale == DesktopLocale.ko
              ? 'UNKNOWN (통화/금액 누락 · $sourceBasis)'
              : 'UNKNOWN (missing currency or amount · $sourceBasis)';
        }
        final whole = amt ~/ 1000000;
        final cents = (amt % 1000000) ~/ 10000;
        final label = status == CostStatus.authoritativeBilling
            ? 'AUTHORITATIVE'
            : status == CostStatus.providerReportedEstimate
            ? 'ESTIMATE'
            : 'RATE_TABLE_ESTIMATE';
        return '$curr $whole.${cents.toString().padLeft(2, '0')} ($label · $sourceBasis)';
    }
  }
}

@immutable
class EvaluationHistoryItem {
  const EvaluationHistoryItem({
    required this.evaluationId,
    required this.attemptId,
    required this.verdict,
    required this.manifestDigest,
    required this.workspaceDriftDetected,
    required this.summary,
  });

  final String evaluationId;
  final String attemptId;
  final String verdict;
  final String manifestDigest;
  final bool workspaceDriftDetected;
  final String summary;
}

@immutable
class CoreInspectionSnapshot {
  const CoreInspectionSnapshot({
    required this.connected,
    required this.workspaceId,
    required this.protocolVersion,
    required this.activeAttempt,
  });

  final bool connected;
  final String workspaceId;
  final String protocolVersion;
  final ExecutionAttemptView? activeAttempt;
}
