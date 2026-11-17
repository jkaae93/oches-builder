# ADR-019: Provisional wire input limits and numeric policy

Status: Accepted (provisional fail-closed v1 baseline for IMP-01), 2026-11-17. Refs #1. Final operation-specific limits and signed-byte domain separation remain gated on subsequent issues.

## Context

ADR-016 D05 adopts RFC 8785 JCS and leaves precise limits and operation schemas to implementation. CONTRACT_FINALIZATION_PROPOSAL §3.2 proposes safe-range integers, decimal strings for identifiers that may exceed that range, and bounded input; its sample limits are not final. It does not authorize silently rounding identifiers or normalizing Unicode. ARC-10 generation-bound revision references compare objectId, storeGeneration and revision together.

## Current prototype behavior

The wire scanner requires caller limits no greater than 1 MiB per envelope, depth 128 and 256 KiB of raw JSON bytes between string quotes; escaping counts toward the raw size. These are defensive ceilings, not selected production limits. The scanner rejects malformed UTF-8, duplicate keys, non-finite values, mathematically integral values outside ±9007199254740991 and nonzero values that underflow to zero. Finite non-integral values, including representable subnormals, are rounded to binary64. The raw scanner checks JSON number grammar without Foundation whole-document decoding; string fragments still use Foundation. Version fields separately use Decimal and reject mantissas over 38 digits. The scanner preserves key code points and array order. No request dispatch is enabled.

## Decision required before contract freeze

Select explicit envelope, depth, string, execution-time and operation-specific limits with threat and compatibility tests. Define whether the safe-integer rule applies to mathematically integral values expressed with fractional/exponent notation and specify accepted finite non-integral values and IEEE-754 conversion. Resolve the version-field restrictions without allowing a large integer or fractional version to round into a valid integer. Define null/omission and unknown-field rules per operation. Review against ARC-09/11 signed bytes and domain separation; do not reuse the bare JCS digest as an authorization signature.

Alternatives include an exact decimal lexical classifier followed by correctly rounded binary64 conversion, or a vetted strict parser with independently verified semantics. Swift Foundation's ordinary dictionary decoding alone is insufficient because canonically equivalent Unicode keys can collapse. Any choice must pass independent JCS vectors, raw malformed/duplicate/large-number tests and cross-runtime comparisons, including underflow and boundaries.

## Consequences and rollback

Until the above decision and review, the current restrictions are fail-closed and must not be advertised as a finalized v1 interoperability contract. No production data migration exists. A later change must document compatibility and rollback; relaxing limits does not by itself establish authorization, transport identity or durability.

## Candidate implementation update

The candidate classifies mathematically integral decimal tokens using their original digits and exponent before binary64 rounding: integers beyond ±9007199254740991 are rejected even with a decimal point or exponent. Finite non-integral values are accepted if conversion does not underflow to zero, including representable subnormals. Non-integral values are rounded to binary64 as required by JCS; operation schemas needing exact decimal semantics must use an explicit string or separately specified representation. This is a proposed interpretation, not an approved contract. Cross-runtime and adversarial boundary review remains required.
