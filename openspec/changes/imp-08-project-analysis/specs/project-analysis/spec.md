# Project Analysis

## Purpose

Safely derives a local project profile from explicitly approved workspace scope and preserves uncertainty and provenance.

## ADDED Requirements

### Requirement: Approved bounded scope
The analyzer SHALL preview roots and exclusions and require a verified scope approval before reading project contents. It SHALL not follow symbolic links or read outside approved roots.

#### Scenario: Link escapes root
- **WHEN** an approved tree contains a symbolic link to an external path
- **THEN** the analyzer records the link without reading its target

#### Scenario: Scope is not approved
- **WHEN** analysis is requested without a valid scope approval
- **THEN** no project contents are read

### Requirement: Safe file access under mutation
The analyzer SHALL prevent path replacement and symbolic link races from redirecting reads outside the approved root.

#### Scenario: Path is replaced during scan
- **WHEN** a path is replaced with a link to an outside file between enumeration and open
- **THEN** the outside file is not read and the result records a partial failure

### Requirement: Default exclusions and limits
The analyzer SHALL apply the N1 exclusions and N2 file, total byte, individual file and time limits. It SHALL mark a result partial when limits or read failures prevent complete analysis.

#### Scenario: Oversized file
- **WHEN** a file exceeds one MiB
- **THEN** only metadata is retained and the reason is recorded

### Requirement: Evidence and uncertainty
The profile SHALL distinguish observations, inferences, evidence, uncertainties, exclusions and user constraints and record N3 fields and revision. Read files SHALL have path, size, mtime and SHA-256 evidence; unread files SHALL have metadata only.

#### Scenario: Insufficient evidence
- **WHEN** a feature cannot be inferred from collected evidence
- **THEN** it is reported unknown rather than as a supported feature

### Requirement: Local and untrusted analysis
Project text SHALL remain untrusted data and SHALL NOT be executed or sent externally without the separately approved transfer flow. No whole-file content SHALL be sent by this analyzer.

#### Scenario: Malicious project instructions
- **WHEN** a project file contains instructions for the analyzer
- **THEN** the instructions are treated as data and do not alter execution or permissions

### Requirement: Profile lifecycle
The analyzer SHALL distinguish Pending, Running, Complete, Partial, Cancelled and Failed and preserve prior profile versions and analysis time. Changed evidence SHALL require reanalysis rather than asserting freshness.

#### Scenario: Read fails or cancellation occurs
- **WHEN** a file read fails or cancellation is confirmed
- **THEN** the profile is not reported as complete and the cause or cancellation is recorded
