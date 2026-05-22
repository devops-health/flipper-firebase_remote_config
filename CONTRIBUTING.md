# Contributing

Thanks for your interest in `flipper-firebase_remote_config`. Bug reports,
fixes, docs improvements, and feature PRs are all welcome.

## Scope

Particularly welcome:

- Bug reports with a minimal reproduction.
- Documentation improvements (especially around configuration and the
  trade-offs of using Remote Config as a flag store).
- An implementation of Remote Config **conditions** as a Flipper extension
  (see [README.md](README.md#not-yet-supported)).

Out of scope, generally:

- Live integration tests in the default `rspec` run — they burn the
  project's Remote Config write quota. See [CLAUDE.md](CLAUDE.md) for the
  reasoning and the existing `FakeClient` test double.
- Increasing the ETag retry budget past 1. Remote Config is
  write-quota-limited; if you have enough write contention that one retry
  isn't enough, this adapter is the wrong tool.

## Dev setup

The project supports Ruby 2.7+. To install dependencies and run the suite:

```sh
bundle install
bundle exec rspec
bundle exec rubocop
```

Tests are fully offline — `FakeClient` (in `spec/support/`) stands in for
the REST client. See [CLAUDE.md](CLAUDE.md) for architecture notes and
maintenance gotchas.

## Pull requests

- Keep PRs focused on a single change. Split unrelated cleanup into
  separate PRs.
- Add or update specs for any behavior change. The suite must stay green
  on the full Ruby matrix (CI runs 2.7–4.0).
- Run `bundle exec rspec` and `bundle exec rubocop` locally before
  pushing.
- Link the issue you're fixing in the PR description, if any.

## Security

Please do **not** report security issues in public GitHub issues. See
[SECURITY.md](SECURITY.md) for the disclosure process.
