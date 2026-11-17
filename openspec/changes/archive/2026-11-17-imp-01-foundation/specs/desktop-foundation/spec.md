# Desktop Foundation

## Purpose

Provides a reproducibly buildable macOS desktop shell with a transport boundary for the shared local Core.

## ADDED Requirements

### Requirement: Reproducible macOS build
A clean checkout SHALL document and pin its toolchain and provide commands for dependency resolution, static analysis, tests, and a macOS arm64 desktop build. CI SHALL run the applicable checks.

#### Scenario: Clean checkout
- **WHEN** the documented commands run with the pinned supported toolchain on macOS arm64
- **THEN** dependency resolution, analysis, tests, and build complete successfully

### Requirement: Separate transport boundary
The desktop shell SHALL communicate through an explicit Core transport abstraction and SHALL NOT represent a placeholder transport as authenticated XPC or as an operational Core service.

#### Scenario: No verified transport
- **WHEN** a user attempts a protected operation while no verified Core transport is available
- **THEN** the shell reports unavailable and does not perform the operation

### Requirement: Honest platform status
The project SHALL identify macOS arm64 as the initial target and SHALL NOT claim support for untested platforms or security mechanisms.

#### Scenario: Untested platform
- **WHEN** a platform or security gate has not been tested
- **THEN** its status remains NOT RUN or UNKNOWN instead of supported
