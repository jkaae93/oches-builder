import 'package:flutter/material.dart';

import '../core/core_models.dart';
import '../state/vertical_flow_controller.dart';

class VerticalFlowShell extends StatefulWidget {
  const VerticalFlowShell({super.key, required this.controller});

  final VerticalFlowController controller;

  @override
  State<VerticalFlowShell> createState() => _VerticalFlowShellState();
}

class _VerticalFlowShellState extends State<VerticalFlowShell> {
  final TextEditingController _templateEditController = TextEditingController();
  final TextEditingController _applyApprovalController = TextEditingController(
    text: 'app-apply-1',
  );
  final TextEditingController _execApprovalController = TextEditingController(
    text: 'app-exec-1',
  );
  final TextEditingController _transferApprovalController =
      TextEditingController(text: 'app-xfer-1');

  @override
  void initState() {
    super.initState();
    widget.controller.connect();
  }

  @override
  void dispose() {
    _templateEditController.dispose();
    _applyApprovalController.dispose();
    _execApprovalController.dispose();
    _transferApprovalController.dispose();
    super.dispose();
  }

  String _t(String ko, String en) =>
      widget.controller.locale == DesktopLocale.ko ? ko : en;

  String _stageTitle(WorkflowStage stage) {
    switch (stage) {
      case WorkflowStage.scope:
        return _t('범위 확인', 'Scope');
      case WorkflowStage.profile:
        return _t('Profile', 'Profile');
      case WorkflowStage.recommendations:
        return _t('추천', 'Recommend');
      case WorkflowStage.template:
        return _t('템플릿 편집', 'Template');
      case WorkflowStage.exportDiff:
        return _t('적용 승인', 'Export Diff');
      case WorkflowStage.runApproval:
        return _t('실행 승인', 'Run Approval');
      case WorkflowStage.monitor:
        return _t('실행 모니터', 'Monitor');
      case WorkflowStage.evaluation:
        return _t('평가·비용', 'Evaluation');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final ctrl = widget.controller;
        if (ctrl.connectionState == CoreConnectionState.checking ||
            ctrl.connectionState == CoreConnectionState.unavailable) {
          return Scaffold(
            appBar: AppBar(title: const Text('Oches Builder')),
            body: Center(
              child: Text(
                ctrl.connectionState == CoreConnectionState.unavailable
                    ? 'Core is unavailable.'
                    : 'Checking Core availability…',
              ),
            ),
          );
        }

        return Scaffold(
          appBar: AppBar(
            title: Text('Oches Builder · ${ctrl.workspaceId}'),
            actions: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Chip(label: Text(ctrl.connectionState.name)),
              ),
              Semantics(
                button: true,
                label: _t('언어 전환', 'Toggle Language'),
                child: TextButton(
                  key: const Key('toggle-locale-btn'),
                  onPressed: ctrl.toggleLocale,
                  child: Text(
                    ctrl.locale == DesktopLocale.ko ? 'KR/EN' : 'EN/KR',
                  ),
                ),
              ),
              Semantics(
                button: true,
                label: _t('Core 재연결', 'Reconnect Core'),
                child: TextButton(
                  key: const Key('reconnect-btn'),
                  onPressed: ctrl.reconnect,
                  child: Text(_t('재연결', 'Reconnect')),
                ),
              ),
            ],
          ),
          body: Row(
            children: [
              SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight:
                        MediaQuery.of(context).size.height - kToolbarHeight,
                  ),
                  child: IntrinsicHeight(
                    child: NavigationRail(
                      selectedIndex: WorkflowStage.values.indexOf(
                        ctrl.activeStage,
                      ),
                      onDestinationSelected: (idx) =>
                          ctrl.setStage(WorkflowStage.values[idx]),
                      labelType: NavigationRailLabelType.all,
                      destinations: [
                        for (final stage in WorkflowStage.values)
                          NavigationRailDestination(
                            icon: const Icon(Icons.layers_outlined),
                            selectedIcon: const Icon(Icons.layers),
                            label: Text(_stageTitle(stage)),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const VerticalDivider(width: 1),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (ctrl.errorBanner != null)
                        Card(
                          color: Colors.red.shade50,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Text(ctrl.errorBanner!),
                          ),
                        ),
                      Expanded(child: _buildStageContent(ctrl)),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildStageContent(VerticalFlowController ctrl) {
    switch (ctrl.activeStage) {
      case WorkflowStage.scope:
        final scope = ctrl.scopePreview;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_t('1. 프로젝트 분석 범위 확인', '1. Workspace Scope Preview')),
            const SizedBox(height: 8),
            ElevatedButton(
              key: const Key('load-scope-btn'),
              onPressed: ctrl.loadScopePreview,
              child: Text(_t('범위 미리보기', 'Preview Scope')),
            ),
            if (scope != null) ...[
              Text('Files: ${scope.includedFileCount}'),
              Text('Excluded: ${scope.excludedPatterns.join(", ")}'),
              Text('Symlinks (unfollowed): ${scope.symlinkPaths.length}'),
              ElevatedButton(
                key: const Key('approve-analyze-btn'),
                onPressed: ctrl.approveScopeAndAnalyze,
                child: Text(_t('범위 승인 및 분석', 'Approve Scope & Analyze')),
              ),
            ],
          ],
        );

      case WorkflowStage.profile:
        final prof = ctrl.profile;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_t('2. 분석 Profile', '2. Project Profile')),
            if (prof != null) ...[
              Text('Revision: ${prof.profileRevision.revision}'),
              if (prof.partial)
                Text('Partial (limitsReached=${prof.limitsReached})'),
              Text(prof.summaryNote),
              ElevatedButton(
                key: const Key('load-recs-btn'),
                onPressed: ctrl.loadRecommendations,
                child: Text(_t('추천 후보 불러오기', 'Load Recommendations')),
              ),
            ],
          ],
        );

      case WorkflowStage.recommendations:
        return ListView(
          children: [
            Text(_t('3. 추천 패턴 (Single Agent 기준선 포함)', '3. Recommendations')),
            for (final rec in ctrl.recommendations)
              ListTile(
                title: Text(
                  '${rec.title} [${rec.capabilityStatus.name.toUpperCase()}]',
                ),
                subtitle: Text('${rec.claim} · ${rec.alternativeNote}'),
                selected: ctrl.selectedCandidate?.patternId == rec.patternId,
                onTap: () => ctrl.selectCandidate(rec),
              ),
            ElevatedButton(
              key: const Key('open-template-btn'),
              onPressed: ctrl.initTemplateDraftIfNeeded,
              child: Text(_t('템플릿 편집기 열기', 'Open Template Editor')),
            ),
          ],
        );

      case WorkflowStage.template:
        final draft = ctrl.templateDraft;
        if (draft != null && _templateEditController.text.isEmpty) {
          _templateEditController.text = draft.draftBody;
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_t('4. 템플릿 초안 편집 및 검증', '4. Template Draft Editor')),
            if (draft != null) ...[
              Text(
                'Canonical Rev: ${draft.canonicalRevision.revision} · Dirty=${draft.localDraftDirty} · Stale=${draft.stale}',
              ),
              TextField(
                key: const Key('template-draft-field'),
                controller: _templateEditController,
                onChanged: ctrl.editTemplateLocally,
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton(
                    key: const Key('validate-template-btn'),
                    onPressed: ctrl.validateTemplate,
                    child: Text(_t('검증', 'Validate')),
                  ),
                  ElevatedButton(
                    key: const Key('build-export-btn'),
                    onPressed: ctrl.buildExportPlan,
                    child: Text(_t('적용 계획 생성', 'Plan Export Diff')),
                  ),
                ],
              ),
            ],
          ],
        );

      case WorkflowStage.exportDiff:
        final plan = ctrl.exportPlan;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_t('5. 설정 적용 Diff 및 승인', '5. Export Diff & Apply Approval')),
            if (plan != null) ...[
              if (plan.stale) const Text('STALE_PLAN: revalidate required'),
              Text('Target: ${plan.targetPath}'),
              Text(plan.diffPreview),
              for (final m in plan.mappings)
                Text(
                  '${m.fieldName}: ${m.fidelity.name.toUpperCase()} (${m.detail})',
                ),
              TextField(
                key: const Key('apply-approval-field'),
                controller: _applyApprovalController,
              ),
              ElevatedButton(
                key: const Key('apply-export-btn'),
                onPressed: () =>
                    ctrl.applyExportWithApproval(_applyApprovalController.text),
                child: Text(_t('승인된 적용 실행', 'Apply Config Export')),
              ),
            ],
          ],
        );

      case WorkflowStage.runApproval:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _t('6. 실행 및 외부 전송 분리 승인', '6. Execution & Transfer Approvals'),
            ),
            TextField(
              key: const Key('exec-approval-field'),
              controller: _execApprovalController,
            ),
            TextField(
              key: const Key('transfer-approval-field'),
              controller: _transferApprovalController,
            ),
            ElevatedButton(
              key: const Key('start-run-btn'),
              onPressed: () => ctrl.startRunWithApprovals(
                taskId: 'task-1',
                executionApprovalId: _execApprovalController.text,
                transferApprovalId: _transferApprovalController.text,
              ),
              child: Text(_t('승인된 실행 시작', 'Start Approved Run')),
            ),
          ],
        );

      case WorkflowStage.monitor:
        final attempt = ctrl.activeAttempt;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(_t('7. 실행 모니터', '7. Execution Monitor')),
            if (attempt != null) ...[
              Text('Attempt: ${attempt.attemptId} (${attempt.providerName})'),
              Text(
                ctrl.cancelPending &&
                        attempt.taskState != TaskUiState.evaluating
                    ? 'Status: Cancel Requested'
                    : 'Status: ${_taskStatusLabel(attempt.taskState)}',
              ),
              if (attempt.outputTruncated || attempt.droppedEventsCount > 0)
                Text(
                  'Output incomplete (truncated=${attempt.outputTruncated}, dropped=${attempt.droppedEventsCount})',
                ),
              if (ctrl.cursorResyncPerformed)
                const Text('Cursor expired; resynced from snapshot.'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ElevatedButton(
                    key: const Key('cancel-run-btn'),
                    onPressed: ctrl.requestCancel,
                    child: Text(_t('취소 요청', 'Request Cancel')),
                  ),
                  ElevatedButton(
                    key: const Key('poll-monitor-btn'),
                    onPressed: () => ctrl.pollMonitor(force: true),
                    child: Text(_t('상태 새로고침', 'Refresh Monitor')),
                  ),
                  ElevatedButton(
                    key: const Key('open-eval-btn'),
                    onPressed: ctrl.loadEvaluationAndCost,
                    child: Text(_t('평가·비용 보기', 'View Evaluation & Cost')),
                  ),
                ],
              ),
              Expanded(
                child: ListView(
                  children: [for (final ev in attempt.events) Text(ev)],
                ),
              ),
            ],
          ],
        );

      case WorkflowStage.evaluation:
        final cost = ctrl.costSummary;
        return ListView(
          children: [
            Text(_t('8. 평가 결과 및 비용', '8. Evaluation & Cost')),
            if (cost != null)
              Text(
                'Cost: ${cost.formattedDisplay(ctrl.locale)}',
                key: const Key('cost-summary-text'),
              ),
            for (final ev in ctrl.evaluations)
              ListTile(
                title: Text('${ev.evaluationId}: ${ev.verdict}'),
                subtitle: Text(
                  '${ev.summary} (drift=${ev.workspaceDriftDetected})',
                ),
              ),
          ],
        );
    }
  }

  String _taskStatusLabel(TaskUiState state) {
    switch (state) {
      case TaskUiState.ready:
        return 'Ready';
      case TaskUiState.prepared:
        return 'Prepared';
      case TaskUiState.running:
        return 'Running';
      case TaskUiState.cancelRequested:
        return 'Cancel Requested';
      case TaskUiState.evaluating:
        return 'Evaluating';
      case TaskUiState.succeeded:
        return 'Succeeded';
      case TaskUiState.failed:
        return 'Failed';
      case TaskUiState.cancelled:
        return 'Cancelled';
      case TaskUiState.blocked:
        return 'Blocked';
      case TaskUiState.unknown:
        return 'Unknown';
    }
  }
}
