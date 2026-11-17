# ADR-019: Provisional wire input limits and numeric policy

Status: Proposed, 2026-11-17. Refs #1. Not an approved interoperability contract.

## Context

ADR-016 D05 adopts RFC 8785 JCS and leaves precise limits and operation schemas to implementation. CONTRACT_FINALIZATION_PROPOSAL §3.2 proposes safe-range integers, decimal strings for identifiers that may exceed that range, and bounded input; its sample limits are not final. It does not authorize silently rounding identifiers or normalizing Unicode. ARC-10 generation-bound revision references compare objectId, storeGeneration and revision together.

## Current prototype behavior

The wire scanner requires caller limits no greater than 1 MiB per envelope, depth 128 and 256 KiB of raw JSON bytes between string quotes; escaping counts toward the raw size. These are defensive ceilings, not selected production limits. The scanner rejects malformed UTF-8, duplicate keys, non-finite values, values outside ±9007199254740991, mantissas longer than 38 digits, Decimal-unrepresentable numbers and nonzero values that underflow to zero. The latter restrictions are stricter than the proposal's safe-integer rule and exclude valid finite fractional JCS values, including some subnormals. It preserves key code points and array order. No request dispatch is enabled.

## Decision required before contract freeze

Select explicit envelope, depth, string, execution-time and operation-specific limits with threat and compatibility tests. Define whether the safe-integer rule applies to mathematically integral values expressed with fractional/exponent notation and specify accepted finite non-integral values and IEEE-754 conversion. Replace the provisional Decimal-based restriction where it excludes required inputs, without allowing a large integer to round into a safe value. Define null/omission and unknown-field rules per operation. Review against ARC-09/11 signed bytes and domain separation; do not reuse the bare JCS digest as an authorization signature.

Alternatives include an exact decimal lexical classifier followed by correctly rounded binary64 conversion, or a vetted strict parser with independently verified semantics. Swift Foundation's ordinary dictionary decoding alone is insufficient because canonically equivalent Unicode keys can collapse. Any choice must pass independent JCS vectors, raw malformed/duplicate/large-number tests and cross-runtime comparisons, including underflow and boundaries.

## Consequences and rollback

Until the above decision and review, the current restrictions are fail-closed and must not be advertised as a finalized v1 interoperability contract. No production data migration exists. A later change must document compatibility and rollback; relaxing limits does not by itself establish authorization, transport identity or durability.
