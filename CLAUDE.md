# CLAUDE.md — flipper-firebase_remote_config

Context for future Claude sessions working on this gem. Read this before
changing anything non-trivial.

## What this gem is

A Flipper adapter that persists feature flag state as Firebase Remote Config
parameters. The user-facing surface is documented in `README.md` — this file
covers the *why* of the design and the gotchas a maintainer needs to know.

## Architecture in one diagram

```
Flipper::Feature ──► Flipper::Adapters::FirebaseRemoteConfig (this gem)
                              │
                              ├── in-process cache: {template, etag, fetched_at}
                              │
                              └─► Client (Net::HTTP + googleauth)
                                       │
                                       └─► firebaseremoteconfig.googleapis.com
                                             GET  /v1/projects/{id}/remoteConfig
                                             PUT  /v1/projects/{id}/remoteConfig
                                                  (with If-Match: <etag>)
```

The whole adapter is just two files of substance:

- `lib/flipper/adapters/firebase_remote_config.rb` — Flipper interface, gate
  serialization, cache + ETag retry loop.
- `lib/flipper/adapters/firebase_remote_config/client.rb` — REST wrapper.

## Storage scheme

One Remote Config parameter per feature, named `<prefix><feature_key>` (prefix
defaults to `flipper__`). The parameter's `defaultValue.value` holds a JSON
blob with the gate state. A sentinel parameter `<prefix>__index__` lists known
feature keys so `features` / `get_all` don't have to scan every parameter in
the project.

The in-memory template is a plain `Hash` matching the API JSON shape — not a
typed model object. See "Why no generated client" below.

## Why no generated Google API client

The Firebase Remote Config v1 API does not have a published Ruby service gem:

- `google-apis-firebaseremoteconfig_v1` does **not** exist on RubyGems (checked
  against `gem search '^google-apis-firebase'`; only firebase_v1beta1,
  firebaseappcheck, firebaseml, etc. are published).
- The deprecated umbrella `google-api-client` 0.53 does not bundle the
  `Google::Apis::FirebaseremoteconfigV1` namespace either.

So we hand-roll two HTTP calls with `Net::HTTP`. Auth is real — we depend on
`googleauth` directly and use `Google::Auth::ServiceAccountCredentials` for the
OAuth2 service-account flow.

**Don't try to "fix" this by reintroducing `google/apis/firebaseremoteconfig_v1`
— that namespace doesn't exist.** If Google eventually publishes a service gem,
swapping in is fine, but verify the gem exists on RubyGems first.

An earlier revision of this gem depended on `google-api-client` (the
deprecated umbrella) just to pick up `googleauth` transitively. That was dead
weight — we never used any class from `google-api-client` itself — so the dep
was dropped in favor of `googleauth` directly. Don't reintroduce
`google-api-client` without a concrete need; it's been deprecated by Google.

## The ETag retry loop

`with_template` is the only write path. It:

1. Loads the cached or freshly-fetched template (and its ETag).
2. Yields the template to the block for mutation.
3. Publishes with `If-Match: <etag>`.
4. On `ETagMismatch` (HTTP 409 or 412), reloads and retries **once**.

One retry, not infinite. If the project sees enough concurrent writes that one
retry isn't enough, this adapter is the wrong tool — Remote Config is
write-quota-limited (hundreds of writes/day per project). Don't paper over
that by bumping the retry count.

## Cache invalidation

`load_template` caches `{template, etag}` for `cache_ttl` seconds (default 30s).
Every successful write calls `reload!` so the next read pulls fresh state.
External writes (e.g., someone editing in the Firebase console) are not
detected until the TTL expires.

Recommended deployment: also wrap with `Flipper::Adapters::Memoizable` for
per-request caching, on top of this adapter's TTL cache. That gives:

- Per-request: zero Remote Config calls (memoized in the request)
- Across requests within TTL: one cached `GET` per process per `cache_ttl`
- After TTL: one `GET` then back to cached

## Gate serialization

`serialize_gates` / `deserialize_gates` round-trip the Flipper gate hash to a
JSON-safe shape: `Set` → `Array` on write, `Array` → `Set` on read. The five
gate keys we persist match Flipper's default config — `boolean`, `actors`,
`groups`, `percentage_of_actors`, `percentage_of_time`. Newer gate types
(`:expression`) are not handled; if Flipper adds new built-in gates we'll need
to extend `default_config` and the (de)serializers together.

## Running tests

The system Ruby on this machine is 2.6 (below our `>= 2.7` floor). The
Homebrew Ruby at `/opt/homebrew/opt/ruby@3.4/bin/ruby` is actually a 4.x
build that satisfies the requirement. Tests:

```sh
/opt/homebrew/opt/ruby@3.4/bin/bundle exec rspec
```

`.claude/settings.json` allowlists the routine `bundle`/`rspec`/`rubocop`
invocations against that path so future sessions don't pile up permission
prompts.

The suite is fully offline — `FakeClient` (in `spec/support/`) stands in for
the REST client and enforces the same ETag semantics. There are no live HTTP
fixtures; webmock is in the dev deps for future contract tests but isn't used
yet.

## Things to be careful about

- **Don't add live integration tests to the default `rspec` run.** Hitting
  real Firebase from CI burns the project's write quota.
- **Don't bump the ETag retry budget past 1.** See above.
- **Don't change the parameter name format** without a migration path —
  existing deployments have parameters named `flipper__foo` and the index at
  `flipper____index__`. Renaming silently orphans flags.
- **Don't expose Remote Config conditions through the standard gate API.** If
  you want conditions, add a new extension method (e.g.
  `#enable_for_condition`) rather than overloading the gate semantics.
- **Don't introduce a hard dependency on a specific Flipper version >= 1.x
  point release** without checking that the gate `data_type` enum is still
  what the case-statement in `#enable` / `#disable` expects.

## Adding a new gate type

If Flipper introduces a new built-in gate (e.g. `:expression` becomes
standard):

1. Add its key to `default_config`.
2. Handle its `data_type` in the `enable` and `disable` case-statements.
3. Update `serialize_gates` / `deserialize_gates` if its value isn't
   JSON-safe by default.
4. Add a spec mirroring the existing "set gates" / "integer gates" patterns.

## CI / Release workflows

Two GitHub Actions workflows live in `.github/workflows/`:

- `ci.yml` — on push to `main` and on every PR. Runs `bundler-audit` (CVE
  scan), `rubocop`, and `rspec` across Ruby 3.1–3.3. Lint + security run
  first; tests run only if both pass.
- `release.yml` — on `release: published`. Verifies the GitHub release tag
  (stripped of a leading `v`) matches `Flipper::Adapters::FirebaseRemoteConfig::VERSION`,
  re-runs the tests, then publishes via `rubygems/release-gem@v1` using
  **OIDC trusted publishing** — no `RUBYGEMS_API_KEY` secret is required.

**One-time setup before the first release works:** configure a trusted
publisher for this gem on rubygems.org
(<https://guides.rubygems.org/trusted-publishing/>): repo
`<owner>/flipper-firebase_remote_config`, workflow `release.yml`,
environment `rubygems`. Without that, `release-gem` will fail to authenticate.

To cut a release:

1. Bump `VERSION` in `lib/flipper/adapters/firebase_remote_config/version.rb`.
2. Merge to `main`.
3. Create a GitHub release with tag `v<version>` (e.g. `v0.2.0`). Use the
   release notes as the user-facing changelog — `changelog_uri` in the
   gemspec points at <https://github.com/devops-health/flipper-firebase_remote_config/releases>.
   The workflow publishes automatically.

## Files at a glance

```
flipper-firebase_remote_config/
├── .github/workflows/
│   ├── ci.yml                                  # CVE scan + lint + tests
│   └── release.yml                             # OIDC publish to RubyGems
├── lib/flipper/adapters/
│   ├── firebase_remote_config.rb              # the adapter
│   └── firebase_remote_config/
│       ├── client.rb                          # REST wrapper
│       └── version.rb
├── spec/
│   ├── flipper/adapters/firebase_remote_config_spec.rb
│   ├── support/fake_client.rb                 # in-memory client double
│   └── spec_helper.rb
├── .claude/settings.json                       # bundle/rspec allowlist
├── CLAUDE.md                                   # you are here
├── Gemfile
├── LICENSE
├── README.md
├── Rakefile
└── flipper-firebase_remote_config.gemspec
```
