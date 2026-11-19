import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:oches_desktop/core/core_client.dart';
import 'package:oches_desktop/core/core_models.dart';
import 'package:oches_desktop/main.dart';
import 'package:oches_desktop/state/vertical_flow_controller.dart';

class FakeCoreClient implements OchesCoreClient {
  int startCalls = 0;
  int applyCalls = 0;
  int inspectCalls = 0;
  int snapshotResyncCalls = 0;
  int pollCalls = 0;

  bool connected = true;
  bool expireNextCursor = false;
  bool cancelWinsRace = false;
  CostSummaryView nextCostSummary = const CostSummaryView(
    status: CostStatus.unknown,
    currency: null,
    amountMicroUsd: null,
    sourceBasis: 'provider omitted failure cost',
    unknownCount: 1,
    subscriptionIncludedCount: 0,
  );

  ExecutionAttemptView? currentAttempt;

  @override
  Future<CoreInspectionSnapshot> connectAndInspect() async {
    inspectCalls += 1;
    return CoreInspectionSnapshot(
      connected: connected,
      workspaceId: 'ws-test',
      protocolVersion: '1.0',
      activeAttempt: currentAttempt,
    );
  }

  @override
  Future<ScopePreviewDraft> previewScope(String workspacePath) async =>
      ScopePreviewDraft(
        workspaceId: 'ws-test',
        workspacePath: workspacePath,
        scopeDigest: 'scope-dig-1',
        includedFileCount: 12,
        excludedPatterns: const ['.env', '.git'],
        symlinkPaths: const ['escape-link'],
      );

  @override
  Future<ProjectProfileSummary> analyzeWorkspace({
    required String scopeDigest,
    required String requestId,
  }) async => const ProjectProfileSummary(
    profileRevision: RevisionRef(
      objectId: 'arc02/profile',
      storeGeneration: 'gen-1',
      revision: '1',
    ),
    limitsReached: false,
    partial: false,
    summaryNote: 'Swift package detected',
    uncertainties: ['runtime capability unverified'],
  );

  @override
  Future<List<RecommendationCandidate>> fetchRecommendations(
    RevisionRef profileRevision,
  ) async => const [
    RecommendationCandidate(
      patternId: 'single-agent',
      title: 'Single Agent Baseline',
      isSingleAgentBaseline: true,
      capabilityStatus: CapabilityBadgeStatus.supported,
      executableSupported: true,
      claim: 'Simplest baseline',
      alternativeNote: 'Default baseline',
      uncertainties: ['cost varies by task'],
    ),
    RecommendationCandidate(
      patternId: 'routing',
      title: 'Routing',
      isSingleAgentBaseline: false,
      capabilityStatus: CapabilityBadgeStatus.unsupported,
      executableSupported: false,
      claim: 'Conditional routing unsupported in v1',
      alternativeNote: 'Use Single Agent',
      uncertainties: ['v1 unsupported'],
    ),
  ];

  @override
  Future<TemplateDraftState> validateTemplateDraft(
    TemplateDraftState draft,
  ) async => TemplateDraftState(
    instanceId: draft.instanceId,
    canonicalRevision: RevisionRef(
      objectId: draft.canonicalRevision.objectId,
      storeGeneration: draft.canonicalRevision.storeGeneration,
      revision: (int.parse(draft.canonicalRevision.revision) + 1).toString(),
    ),
    draftBody: draft.draftBody,
    localDraftDirty: false,
    stale: false,
    validated: true,
    validationErrors: const [],
  );

  @override
  Future<ExportDiffPlan> planConfigExport({
    required RevisionRef instanceRevision,
  }) async => ExportDiffPlan(
    planId: 'plan-1',
    planDigest: 'plan-dig-1',
    instanceRevision: instanceRevision,
    targetPath: '.claude/settings.json',
    diffPreview: '+ allowedTools: ["Read"]',
    mappings: const [
      ExportFieldMapping(
        fieldName: 'allowedTools',
        fidelity: MappingFidelity.exact,
        detail: 'mapped cleanly',
      ),
    ],
    stale: false,
    blockedByUnsupportedRequiredProperty: false,
  );

  @override
  Future<ApplyConfigResult> applyConfigExport({
    required ExportDiffPlan plan,
    required String applyApprovalId,
    required String requestId,
  }) async {
    applyCalls += 1;
    return const ApplyConfigResult(
      applied: true,
      partialOrUnknown: false,
      detail: 'applied 1 file',
    );
  }

  @override
  Future<ExecutionAttemptView> prepareAndStartRun({
    required String taskId,
    required String executionApprovalId,
    String? transferApprovalId,
    required String requestId,
  }) async {
    startCalls += 1;
    currentAttempt = const ExecutionAttemptView(
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: 'att-1',
      providerName: 'claude',
      taskState: TaskUiState.running,
      events: ['session.init'],
      outputTruncated: false,
      droppedEventsCount: 0,
      cursorSequence: 1,
      cursorExpired: false,
    );
    return currentAttempt!;
  }

  @override
  Future<ExecutionAttemptView> requestCancel({
    required String attemptId,
    required String requestId,
  }) async {
    currentAttempt = ExecutionAttemptView(
      runId: 'run-1',
      taskId: 'task-1',
      attemptId: attemptId,
      providerName: 'claude',
      taskState: cancelWinsRace
          ? TaskUiState.cancelled
          : TaskUiState.cancelRequested,
      events: const ['session.init', 'cancel.requested'],
      outputTruncated: false,
      droppedEventsCount: 0,
      cursorSequence: 2,
      cursorExpired: false,
    );
    return currentAttempt!;
  }

  @override
  Future<ExecutionAttemptView> pollObservation({
    required String attemptId,
    required int afterSequence,
  }) async {
    pollCalls += 1;
    if (expireNextCursor) {
      expireNextCursor = false;
      return ExecutionAttemptView(
        runId: 'run-1',
        taskId: 'task-1',
        attemptId: attemptId,
        providerName: 'claude',
        taskState: TaskUiState.running,
        events: const [],
        outputTruncated: false,
        droppedEventsCount: 0,
        cursorSequence: afterSequence,
        cursorExpired: true,
      );
    }
    return currentAttempt!;
  }

  @override
  Future<ExecutionAttemptView> fetchSnapshotForAttempt(String attemptId) async {
    snapshotResyncCalls += 1;
    return currentAttempt!;
  }

  @override
  Future<List<EvaluationHistoryItem>> fetchEvaluationHistory(
    String workspaceId,
  ) async => const [
    EvaluationHistoryItem(
      evaluationId: 'eval-1',
      attemptId: 'att-1',
      verdict: 'PASS',
      manifestDigest: 'sha256:man1',
      workspaceDriftDetected: false,
      summary: 'Verified snapshot passed',
    ),
  ];

  @override
  Future<CostSummaryView> fetchCostSummary(String workspaceId) async =>
      nextCostSummary;
}

void main() {
  testWidgets('full 8-stage vertical flow with EN/KR toggle and honest cost', (
    tester,
  ) async {
    final client = FakeCoreClient();
    await tester.pumpWidget(OchesApp(coreClient: client));
    await tester.pumpAndSettle();

    // 1. Scope -> Profile
    await tester.tap(find.byKey(const Key('load-scope-btn')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Files: 12'), findsOneWidget);

    await tester.tap(find.byKey(const Key('approve-analyze-btn')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Swift package detected'), findsOneWidget);

    // 2. Profile -> Recommendations
    await tester.tap(find.byKey(const Key('load-recs-btn')));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('Single Agent Baseline [SUPPORTED]'),
      findsOneWidget,
    );

    // 3. Template -> Export Diff
    await tester.tap(find.byKey(const Key('open-template-btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('validate-template-btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('build-export-btn')));
    await tester.pumpAndSettle();
    expect(find.textContaining('.claude/settings.json'), findsOneWidget);

    // 4. Export Apply -> Run Approval -> Monitor
    await tester.tap(find.byKey(const Key('apply-export-btn')));
    await tester.pumpAndSettle();
    expect(client.applyCalls, 1);

    await tester.tap(find.byKey(const Key('start-run-btn')));
    await tester.pumpAndSettle();
    expect(client.startCalls, 1);
    expect(find.textContaining('Status: Running'), findsOneWidget);

    // Toggle locale KR -> EN
    await tester.tap(find.byKey(const Key('toggle-locale-btn')));
    await tester.pumpAndSettle();

    // 5. Evaluation & Cost (UNKNOWN never rendered as $0.00)
    await tester.tap(find.byKey(const Key('open-eval-btn')));
    await tester.pumpAndSettle();
    final costText = tester
        .widget<Text>(find.byKey(const Key('cost-summary-text')))
        .data!;
    expect(costText, contains('UNKNOWN'));
    expect(costText, isNot(contains(r'$0.00')));
  });

  test(
    'V-01 cancel pending vs normal exit race, V-14 reconnect, stale edit, 4Hz throttle',
    () async {
      var clock = DateTime(2026, 11, 19, 10, 0, 0);
      final client = FakeCoreClient();
      final ctrl = VerticalFlowController(client: client, now: () => clock);
      await ctrl.connect();
      expect(ctrl.connectionState, CoreConnectionState.connected);

      // Stale template edit blocks applyConfigExport
      ctrl.initTemplateDraftIfNeeded();
      await ctrl.validateTemplate();
      await ctrl.buildExportPlan();
      ctrl.editTemplateLocally('{"agent":"modified"}');
      expect(ctrl.exportPlan?.stale, isTrue);
      await ctrl.applyExportWithApproval('app-apply-1');
      expect(client.applyCalls, 0);

      // Start run + duplicate call deduplication
      await ctrl.startRunWithApprovals(
        taskId: 'task-1',
        executionApprovalId: 'app-exec-1',
        transferApprovalId: 'app-xfer-1',
      );
      expect(client.startCalls, 1);

      // V-01: Delayed cancel stays CancelRequested until confirmed, and normal exit race wins as Evaluating
      await ctrl.requestCancel();
      expect(ctrl.activeAttempt?.taskState, TaskUiState.cancelRequested);
      expect(ctrl.cancelPending, isTrue);

      client.currentAttempt = const ExecutionAttemptView(
        runId: 'run-1',
        taskId: 'task-1',
        attemptId: 'att-1',
        providerName: 'claude',
        taskState: TaskUiState.evaluating,
        events: ['session.init', 'cancel.requested', 'result.completed'],
        outputTruncated: true,
        droppedEventsCount: 2,
        cursorSequence: 3,
        cursorExpired: false,
      );
      expect(await ctrl.pollMonitor(), isTrue);
      expect(ctrl.activeAttempt?.taskState, TaskUiState.evaluating);
      expect(ctrl.cancelPending, isFalse);

      // P4: 4Hz (250ms) monitor throttle skips calls within 250ms
      clock = clock.add(const Duration(milliseconds: 100));
      expect(await ctrl.pollMonitor(), isFalse);
      clock = clock.add(const Duration(milliseconds: 200));
      expect(await ctrl.pollMonitor(), isTrue);

      // V-14: Reconnect with cursor expiry performs read-only inspect + snapshot resync and 0 starts
      client.expireNextCursor = true;
      final startsBeforeReconnect = client.startCalls;
      await ctrl.reconnect();
      expect(client.startCalls, startsBeforeReconnect);
      expect(client.snapshotResyncCalls, 1);
      expect(ctrl.cursorResyncPerformed, isTrue);

      // SUBSCRIPTION_INCLUDED never formats as $0.00
      const subCost = CostSummaryView(
        status: CostStatus.subscriptionIncluded,
        currency: null,
        amountMicroUsd: null,
        sourceBasis: 'plan quota',
        unknownCount: 0,
        subscriptionIncludedCount: 1,
      );
      expect(
        subCost.formattedDisplay(DesktopLocale.en),
        contains('SUBSCRIPTION_INCLUDED'),
      );
      expect(
        subCost.formattedDisplay(DesktopLocale.en),
        isNot(contains(r'$0.00')),
      );
    },
  );

  test(
    'in-flight duplicate start click sends only a single Core request',
    () async {
      final gate = Completer<void>();
      final slowClient = _SlowStartClient(gate);
      final ctrl = VerticalFlowController(client: slowClient);
      await ctrl.connect();

      final first = ctrl.startRunWithApprovals(
        taskId: 'task-1',
        executionApprovalId: 'app-exec-1',
        transferApprovalId: 'app-xfer-1',
      );
      final second = ctrl.startRunWithApprovals(
        taskId: 'task-1',
        executionApprovalId: 'app-exec-1',
        transferApprovalId: 'app-xfer-1',
      );
      gate.complete();
      await Future.wait([first, second]);
      expect(slowClient.startCalls, 1);
    },
  );
}

class _SlowStartClient extends FakeCoreClient {
  _SlowStartClient(this.gate);
  final Completer<void> gate;

  @override
  Future<ExecutionAttemptView> prepareAndStartRun({
    required String taskId,
    required String executionApprovalId,
    String? transferApprovalId,
    required String requestId,
  }) async {
    await gate.future;
    return super.prepareAndStartRun(
      taskId: taskId,
      executionApprovalId: executionApprovalId,
      transferApprovalId: transferApprovalId,
      requestId: requestId,
    );
  }
}
