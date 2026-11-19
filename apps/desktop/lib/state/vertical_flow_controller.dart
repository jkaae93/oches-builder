import 'package:flutter/foundation.dart';

import '../core/core_client.dart';
import '../core/core_models.dart';

class VerticalFlowController extends ChangeNotifier {
  VerticalFlowController({
    required this.client,
    this.workspacePath = '/workspace/default',
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  static const Duration minMonitorRefreshInterval = Duration(milliseconds: 250);

  final OchesCoreClient client;
  final String workspacePath;
  final DateTime Function() _now;

  DesktopLocale locale = DesktopLocale.ko;
  WorkflowStage activeStage = WorkflowStage.scope;
  CoreConnectionState connectionState = CoreConnectionState.checking;
  String workspaceId = 'ws-default';

  ScopePreviewDraft? scopePreview;
  ProjectProfileSummary? profile;
  List<RecommendationCandidate> recommendations = const [];
  RecommendationCandidate? selectedCandidate;
  TemplateDraftState? templateDraft;
  ExportDiffPlan? exportPlan;
  ApplyConfigResult? applyResult;
  ExecutionAttemptView? activeAttempt;
  CostSummaryView? costSummary;
  List<EvaluationHistoryItem> evaluations = const [];

  bool cancelPending = false;
  bool cursorResyncPerformed = false;
  String? errorBanner;

  final Set<String> _inFlightOps = <String>{};
  final Map<String, String> _activeRequestIds = <String, String>{};
  int _requestCounter = 0;
  DateTime? _lastMonitorPollAt;

  void toggleLocale() {
    locale = locale == DesktopLocale.ko ? DesktopLocale.en : DesktopLocale.ko;
    notifyListeners();
  }

  void setStage(WorkflowStage stage) {
    activeStage = stage;
    notifyListeners();
  }

  void markDisconnected([String? reason]) {
    connectionState = CoreConnectionState.disconnected;
    errorBanner = reason;
    notifyListeners();
  }

  String _stableRequestId(String opKey) =>
      _activeRequestIds.putIfAbsent(opKey, () => '$opKey-${++_requestCounter}');

  void _releaseRequestId(String opKey) {
    _inFlightOps.remove(opKey);
    _activeRequestIds.remove(opKey);
  }

  Future<void> connect() async {
    connectionState = CoreConnectionState.checking;
    errorBanner = null;
    notifyListeners();
    try {
      final snap = await client.connectAndInspect();
      if (!snap.connected) {
        connectionState = CoreConnectionState.unavailable;
        notifyListeners();
        return;
      }
      connectionState = CoreConnectionState.connected;
      if (snap.workspaceId.isNotEmpty) {
        workspaceId = snap.workspaceId;
      }
      if (snap.activeAttempt != null) {
        activeAttempt = snap.activeAttempt;
      }
      notifyListeners();
    } on Exception {
      connectionState = CoreConnectionState.unavailable;
      errorBanner = 'Core is unavailable.';
      notifyListeners();
    }
  }

  /// Read-only reconnect (V-14): never invokes start or apply.
  Future<void> reconnect() async {
    connectionState = CoreConnectionState.reconnecting;
    errorBanner = null;
    notifyListeners();
    try {
      final snap = await client.connectAndInspect();
      if (!snap.connected) {
        connectionState = CoreConnectionState.disconnected;
        errorBanner = 'Core is disconnected.';
        notifyListeners();
        return;
      }
      connectionState = CoreConnectionState.connected;
      if (snap.activeAttempt != null) {
        activeAttempt = snap.activeAttempt;
      }
      final current = activeAttempt;
      if (current != null) {
        final polled = await client.pollObservation(
          attemptId: current.attemptId,
          afterSequence: current.cursorSequence,
        );
        if (polled.cursorExpired) {
          activeAttempt = await client.fetchSnapshotForAttempt(
            current.attemptId,
          );
          cursorResyncPerformed = true;
        } else {
          activeAttempt = polled;
        }
        _syncCancelPendingFromAttempt();
      }
      notifyListeners();
    } on Exception {
      connectionState = CoreConnectionState.disconnected;
      errorBanner = 'Reconnect failed; read-only recovery deferred.';
      notifyListeners();
    }
  }

  Future<void> loadScopePreview() async {
    errorBanner = null;
    try {
      scopePreview = await client.previewScope(workspacePath);
      notifyListeners();
    } on Exception {
      errorBanner = 'Failed to load scope preview.';
      notifyListeners();
    }
  }

  Future<void> approveScopeAndAnalyze() async {
    final scope = scopePreview;
    if (scope == null || _inFlightOps.contains('analyze')) return;
    _inFlightOps.add('analyze');
    final reqId = _stableRequestId('analyze');
    errorBanner = null;
    notifyListeners();
    try {
      profile = await client.analyzeWorkspace(
        scopeDigest: scope.scopeDigest,
        requestId: reqId,
      );
      activeStage = WorkflowStage.profile;
    } on Exception {
      errorBanner = 'Workspace analysis failed.';
    } finally {
      _releaseRequestId('analyze');
      notifyListeners();
    }
  }

  Future<void> loadRecommendations() async {
    final prof = profile;
    if (prof == null) return;
    errorBanner = null;
    try {
      recommendations = await client.fetchRecommendations(prof.profileRevision);
      if (recommendations.isNotEmpty) {
        selectedCandidate = recommendations.firstWhere(
          (c) => c.isSingleAgentBaseline,
          orElse: () => recommendations.first,
        );
      }
      activeStage = WorkflowStage.recommendations;
      notifyListeners();
    } on Exception {
      errorBanner = 'Failed to load recommendations.';
      notifyListeners();
    }
  }

  void selectCandidate(RecommendationCandidate candidate) {
    selectedCandidate = candidate;
    notifyListeners();
  }

  void initTemplateDraftIfNeeded() {
    if (templateDraft != null) return;
    templateDraft = const TemplateDraftState(
      instanceId: 'inst-1',
      canonicalRevision: RevisionRef(
        objectId: 'arc15/instance/inst-1',
        storeGeneration: 'gen-1',
        revision: '1',
      ),
      draftBody: '{"agent":"single-baseline"}',
      localDraftDirty: false,
      stale: false,
      validated: false,
      validationErrors: [],
    );
    activeStage = WorkflowStage.template;
    notifyListeners();
  }

  void editTemplateLocally(String newBody) {
    final current = templateDraft;
    if (current == null) return;
    templateDraft = current.copyWith(
      draftBody: newBody,
      localDraftDirty: true,
      stale: true,
      validated: false,
    );
    if (exportPlan != null) {
      exportPlan = exportPlan!.copyWith(stale: true);
    }
    notifyListeners();
  }

  Future<void> validateTemplate() async {
    final draft = templateDraft;
    if (draft == null) return;
    errorBanner = null;
    try {
      templateDraft = await client.validateTemplateDraft(draft);
      notifyListeners();
    } on Exception {
      errorBanner = 'Template validation failed.';
      notifyListeners();
    }
  }

  Future<void> buildExportPlan() async {
    final draft = templateDraft;
    if (draft == null) return;
    if (draft.localDraftDirty || !draft.validated) {
      errorBanner = 'Validate local draft before building export plan.';
      notifyListeners();
      return;
    }
    errorBanner = null;
    try {
      exportPlan = await client.planConfigExport(
        instanceRevision: draft.canonicalRevision,
      );
      activeStage = WorkflowStage.exportDiff;
      notifyListeners();
    } on Exception {
      errorBanner = 'Failed to compute export plan.';
      notifyListeners();
    }
  }

  Future<void> applyExportWithApproval(String applyApprovalId) async {
    final plan = exportPlan;
    final draft = templateDraft;
    if (plan == null || draft == null) return;
    if (plan.stale || draft.localDraftDirty || draft.stale) {
      errorBanner =
          'Export plan is stale after local edit; revalidate and re-plan.';
      notifyListeners();
      return;
    }
    if (plan.blockedByUnsupportedRequiredProperty) {
      errorBanner = 'Required property is UNSUPPORTED or UNKNOWN.';
      notifyListeners();
      return;
    }
    if (applyApprovalId.trim().isEmpty) {
      errorBanner = 'Apply approval is required.';
      notifyListeners();
      return;
    }
    if (_inFlightOps.contains('apply')) return;
    _inFlightOps.add('apply');
    final reqId = _stableRequestId('apply');
    errorBanner = null;
    notifyListeners();
    try {
      applyResult = await client.applyConfigExport(
        plan: plan,
        applyApprovalId: applyApprovalId,
        requestId: reqId,
      );
      if (applyResult?.applied == true) {
        activeStage = WorkflowStage.runApproval;
      }
    } on Exception {
      errorBanner = 'Config export apply failed.';
    } finally {
      _releaseRequestId('apply');
      notifyListeners();
    }
  }

  Future<void> startRunWithApprovals({
    required String taskId,
    required String executionApprovalId,
    String? transferApprovalId,
    bool requiresExternalTransfer = true,
  }) async {
    if (executionApprovalId.trim().isEmpty) {
      errorBanner = 'Execution approval is required.';
      notifyListeners();
      return;
    }
    if (requiresExternalTransfer &&
        (transferApprovalId?.trim().isEmpty ?? true)) {
      errorBanner = 'External transfer approval is required.';
      notifyListeners();
      return;
    }
    if (_inFlightOps.contains('start')) return;
    _inFlightOps.add('start');
    final reqId = _stableRequestId('start');
    errorBanner = null;
    cancelPending = false;
    notifyListeners();
    try {
      activeAttempt = await client.prepareAndStartRun(
        taskId: taskId,
        executionApprovalId: executionApprovalId,
        transferApprovalId: transferApprovalId,
        requestId: reqId,
      );
      _syncCancelPendingFromAttempt();
      activeStage = WorkflowStage.monitor;
    } on Exception {
      errorBanner = 'Run start rejected by Core.';
    } finally {
      _releaseRequestId('start');
      notifyListeners();
    }
  }

  /// Marks `cancelPending = true` immediately without declaring `Cancelled` until Core confirms termination (V-01).
  Future<void> requestCancel() async {
    final attempt = activeAttempt;
    if (attempt == null || _inFlightOps.contains('cancel')) return;
    _inFlightOps.add('cancel');
    final reqId = _stableRequestId('cancel');
    cancelPending = true;
    errorBanner = null;
    notifyListeners();
    try {
      activeAttempt = await client.requestCancel(
        attemptId: attempt.attemptId,
        requestId: reqId,
      );
      _syncCancelPendingFromAttempt();
    } on Exception {
      errorBanner = 'Cancel request failed; attempt state preserved.';
    } finally {
      _releaseRequestId('cancel');
      notifyListeners();
    }
  }

  /// Enforces 4Hz (250ms) monitor update pacing (P4) and recovers from `cursorExpired` via snapshot resync.
  Future<bool> pollMonitor({bool force = false}) async {
    final attempt = activeAttempt;
    if (attempt == null) return false;
    final currentTime = _now();
    if (!force && _lastMonitorPollAt != null) {
      if (currentTime.difference(_lastMonitorPollAt!) <
          minMonitorRefreshInterval) {
        return false;
      }
    }
    _lastMonitorPollAt = currentTime;
    try {
      final polled = await client.pollObservation(
        attemptId: attempt.attemptId,
        afterSequence: attempt.cursorSequence,
      );
      if (polled.cursorExpired) {
        activeAttempt = await client.fetchSnapshotForAttempt(attempt.attemptId);
        cursorResyncPerformed = true;
      } else {
        activeAttempt = polled;
      }
      _syncCancelPendingFromAttempt();
      notifyListeners();
      return true;
    } on Exception {
      errorBanner = 'Monitor observation unavailable.';
      notifyListeners();
      return false;
    }
  }

  Future<void> loadEvaluationAndCost() async {
    errorBanner = null;
    try {
      evaluations = await client.fetchEvaluationHistory(workspaceId);
      costSummary = await client.fetchCostSummary(workspaceId);
      activeStage = WorkflowStage.evaluation;
      notifyListeners();
    } on Exception {
      errorBanner = 'Failed to load evaluation and cost summary.';
      notifyListeners();
    }
  }

  void _syncCancelPendingFromAttempt() {
    final state = activeAttempt?.taskState;
    if (state == TaskUiState.cancelRequested) {
      cancelPending = true;
    } else if (state == TaskUiState.cancelled ||
        state == TaskUiState.evaluating ||
        state == TaskUiState.succeeded ||
        state == TaskUiState.failed ||
        state == TaskUiState.blocked) {
      cancelPending = false;
    }
  }
}
