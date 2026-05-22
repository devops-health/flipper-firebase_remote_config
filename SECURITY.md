# Security Policy

## Supported versions

Pre-1.0, only the latest `0.0.x` release is supported with security fixes.
Once a `1.0.0` release ships, this section will be updated to track
supported minor lines.

## Reporting a vulnerability

**Please do not open a public GitHub issue for security vulnerabilities.**

To report a vulnerability, use one of the following private channels:

- **Preferred:** Use GitHub's [private vulnerability reporting](https://github.com/devops-health/flipper-firebase_remote_config/security/advisories/new)
  on this repository ("Report a vulnerability" in the Security tab).
- **Alternatively:** Email <roberto.quintanilla@gmail.com> with the
  subject line `flipper-firebase_remote_config security`.

Please include:

- A description of the issue and its impact.
- Steps to reproduce, ideally with a minimal proof of concept.
- The gem version, Ruby version, and Flipper version you reproduced on.

You can expect an acknowledgment within **7 days**. We'll work with you on
a fix and a coordinated disclosure timeline before any public discussion.

## Scope

This adapter handles Google service-account credentials and talks to the
Firebase Remote Config REST API on a Firebase project's behalf. Reports
about credential handling, auth-token leakage, or anything that could let
an attacker mutate a project's Remote Config state through this gem are
especially welcome.
