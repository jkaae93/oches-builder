# Design

## Context

`CAPABILITY_CONTRACT_V1.md` specifies 12 capability IDs, 14 mandatory scope axes, strict separation between `basis=documented` and verified `supported`, and blocking concurrent runs unless `auth.accountIsolation=supported`.

## Goals / Non-Goals

**Goals:** zero credentials in SQLite/logs, deterministic SHA-256 binary/version change detection, strict 14-axis snapshot staleness evaluation, and fail-closed `unknown`/`unsupported` gating.

**Non-Goals:** extracting tokens from third-party apps or launching live Claude/Codex sessions (`IMP-15`/`IMP-17`).

## Decisions

- `CredentialSanitizer.validateNoCredentials` inspects strings for token/cookie/API-key signatures and rejects them before SQLite persistence or logging.
- `CapabilitySnapshot` treats `basis == .documented` as `.unknown` effective capability during gating (`CV01`, `CV18`).
- `CapabilityEvaluator` treats any mismatch across the 14 `CapabilityScope` fields as `.stale` (`STALE`, `CV02`, `CV11`~`CV15`).

## Risks / Trade-offs

- [Installed CLI binary modified on disk without Core notification] → `executableSHA256` verification detects on-disk binary changes and invalidates prior snapshots as `STALE` (`CV15`).

## Migration Plan

Additive `provider_installations` and `account_references` tables in SQLite (`CREATE TABLE IF NOT EXISTS`).
