# Changelog

All notable changes to this project will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Initial Flipper adapter targeting the Firebase Remote Config v1 REST API.
- One Remote Config parameter per feature (prefix configurable, default
  `flipper__`), with an `__index__` sentinel parameter listing known feature
  keys.
- In-process template + ETag cache with a configurable TTL (default 30s) and a
  `#reload!` method to force-refresh.
- Optimistic-concurrency retry: one retry on HTTP 409/412 then re-raise.
- Service-account authentication via `googleauth`.
