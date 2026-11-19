# Tasks

- [x] Implement FIFO DAG-ready decisions with four-slot, account-isolation and resource conflict tests.
- [x] Implement immutable versioned Run plans and atomic task/attempt reservation (including cross-Run capacity and multi-process reservation races).
- [x] Integrate Core prepare, approval binding checks, Runtime start/cancel, restart reconciliation and atomic verified evaluation transitions against MockRuntime and EvaluationVerdictStore (authenticated XPC entry point, IMP-13 immutable artifact collection and real Provider adapters remain pending).
- [x] Implement durable bounded retry/backoff, attempt history and Unknown recovery without automatic restart.
- [ ] Verify V-07/V-09 at product/provider integration level (Core MockRuntime V-07/V-09 tests pass; IMP-13/product XPC/Provider gates remain pending) and close IMP-12.
