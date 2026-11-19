import 'core_models.dart';

class CoreUnavailableException implements Exception {
  const CoreUnavailableException([this.message = 'Core is unavailable.']);
  final String message;

  @override
  String toString() => message;
}

abstract interface class OchesCoreClient {
  Future<CoreInspectionSnapshot> connectAndInspect();

  Future<ScopePreviewDraft> previewScope(String workspacePath);

  Future<ProjectProfileSummary> analyzeWorkspace({
    required String scopeDigest,
    required String requestId,
  });

  Future<List<RecommendationCandidate>> fetchRecommendations(
    RevisionRef profileRevision,
  );

  Future<TemplateDraftState> validateTemplateDraft(TemplateDraftState draft);

  Future<ExportDiffPlan> planConfigExport({
    required RevisionRef instanceRevision,
  });

  Future<ApplyConfigResult> applyConfigExport({
    required ExportDiffPlan plan,
    required String applyApprovalId,
    required String requestId,
  });

  Future<ExecutionAttemptView> prepareAndStartRun({
    required String taskId,
    required String executionApprovalId,
    String? transferApprovalId,
    required String requestId,
  });

  Future<ExecutionAttemptView> requestCancel({
    required String attemptId,
    required String requestId,
  });

  Future<ExecutionAttemptView> pollObservation({
    required String attemptId,
    required int afterSequence,
  });

  Future<ExecutionAttemptView> fetchSnapshotForAttempt(String attemptId);

  Future<List<EvaluationHistoryItem>> fetchEvaluationHistory(
    String workspaceId,
  );

  Future<CostSummaryView> fetchCostSummary(String workspaceId);
}

class FailClosedMacOSCoreClient implements OchesCoreClient {
  const FailClosedMacOSCoreClient();

  Never _fail() => throw const CoreUnavailableException();

  @override
  Future<CoreInspectionSnapshot> connectAndInspect() async =>
      const CoreInspectionSnapshot(
        connected: false,
        workspaceId: '',
        protocolVersion: 'unavailable',
        activeAttempt: null,
      );

  @override
  Future<ScopePreviewDraft> previewScope(String workspacePath) async => _fail();

  @override
  Future<ProjectProfileSummary> analyzeWorkspace({
    required String scopeDigest,
    required String requestId,
  }) async => _fail();

  @override
  Future<List<RecommendationCandidate>> fetchRecommendations(
    RevisionRef profileRevision,
  ) async => _fail();

  @override
  Future<TemplateDraftState> validateTemplateDraft(
    TemplateDraftState draft,
  ) async => _fail();

  @override
  Future<ExportDiffPlan> planConfigExport({
    required RevisionRef instanceRevision,
  }) async => _fail();

  @override
  Future<ApplyConfigResult> applyConfigExport({
    required ExportDiffPlan plan,
    required String applyApprovalId,
    required String requestId,
  }) async => _fail();

  @override
  Future<ExecutionAttemptView> prepareAndStartRun({
    required String taskId,
    required String executionApprovalId,
    String? transferApprovalId,
    required String requestId,
  }) async => _fail();

  @override
  Future<ExecutionAttemptView> requestCancel({
    required String attemptId,
    required String requestId,
  }) async => _fail();

  @override
  Future<ExecutionAttemptView> pollObservation({
    required String attemptId,
    required int afterSequence,
  }) async => _fail();

  @override
  Future<ExecutionAttemptView> fetchSnapshotForAttempt(
    String attemptId,
  ) async => _fail();

  @override
  Future<List<EvaluationHistoryItem>> fetchEvaluationHistory(
    String workspaceId,
  ) async => _fail();

  @override
  Future<CostSummaryView> fetchCostSummary(String workspaceId) async => _fail();
}
