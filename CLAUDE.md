# CLAUDE.md — flipper-firebase_remote_config

Context for future Claude sessions working on this gem. Read this before
changing anything non-trivial.

## What this gem is

A Flipper adapter that persists feature flag state as Firebase Remote Config
parameters. The user-facing surface is documented in `README.md` — this file
covers the *why* of the design and the gotchas a maintainer needs to know.

## The positioning, and why it constrains the design

> One source of truth for teams that already ship a Firebase mobile client.
> Backend and app read the same parameters, flipped in one place.

Read that as a design constraint, not marketing. It is the reason to choose this
gem over `flipper-redis` or `flipper-active_record`, both of which are better at
everything except being readable by a mobile app.

Two consequences a maintainer needs to hold onto:

- **The stored value format is a public interface.** It is not an internal
  encoding you can restructure freely — client apps read these parameters. See
  "Storage scheme" below.
- **We write the *client* template.** Verified: `/v1/projects/{p}/remoteConfig`
  is byte-identical to `/v1/projects/{p}/namespaces/firebase/remoteConfig` —
  same ETag, same parameters, same version. The project-level path *is* the
  client namespace. There is also a `firebase-server` namespace which is
  readable and writable the same way, but **server templates are served only to
  Admin SDK implementations** — client SDKs cannot see them. Moving storage
  there would make the flags invisible to the apps this gem exists to
  coordinate with. Don't, unless a deployment explicitly doesn't need client
  visibility.

Where the positioning does *not* hold yet, and the work tracked against it:

- Only the `boolean` gate has client-side meaning; actor, group and percentage
  gates are evaluated per-actor in Ruby and a client has no actor. Those
  features fall back to a JSON blob, and `getBoolean()` on a blob returns
  `false` rather than erroring — so a feature that starts boolean-only and later
  gains an actor gate silently switches **off** for every client. `write_gates`
  warns on that transition; the rule is that client-visible features stay
  boolean-only.
- So coordinating a *release* across backend and app works; coordinating a
  gradual *ramp* does not. See test-tracker#470.

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
                                                        ▲
                                                        │ the same parameters,
                                                        │ fetched natively
                                                        │
                              Firebase client SDKs ─────┘
                              (iOS / Android / Web — the second reader,
                               and the reason the value format is a
                               public interface)
```

The whole adapter is just two files of substance:

- `lib/flipper/adapters/firebase_remote_config.rb` — Flipper interface, gate
  serialization, cache + ETag retry loop.
- `lib/flipper/adapters/firebase_remote_config/client.rb` — REST wrapper.

## Storage scheme

One Remote Config parameter per feature, named for the feature key **verbatim**
— no prefix. Client apps read these names.

A feature whose only gate is boolean is stored as a real `BOOLEAN` parameter
(`"true"` / `"false"`), so a Firebase client can call `getBoolean()` on it. A
feature using actor, group or percentage gates falls back to a JSON blob of the
gate state, because those are evaluated per-actor in Ruby and mean nothing to a
client.

There is **no index parameter**. `features` / `get_all` derive the feature list
from the template itself via `flipper_feature?`: a parameter counts if its
`valueType` is `BOOLEAN`, or its value parses as a hash carrying **all five**
gate keys. The template is already fetched in one GET, so scanning its keys
costs nothing that reading an index parameter out of that same template didn't.

That the JSON test demands the complete set is deliberate, not fussiness. The
distinction it draws is **type, not ownership**: a boolean parameter is a
toggle, but structured JSON config is not, and `{"groups": [...]}` is an
ordinary thing to find in a mobile app's parameters — `actors` is no stranger.
Matching on any single key would claim it as a feature and let a `disable`
flatten structured config into `BOOLEAN false`.

Every blob we write starts from `default_config` and so always carries all
five keys, which makes the strict test free. Don't loosen it.

This is the intended model, not a side effect: **a `BOOLEAN` Remote Config
parameter is a feature toggle.** The Firebase console and `Flipper.enable` /
`Flipper.disable` are two interfaces onto the same thing, exactly as Flipper's
other adapters let you write through the DSL or straight into the store. There
is no notion of a parameter belonging to the app rather than to Flipper.

So a boolean parameter created in the console is a feature, and so is one the
mobile team added last year without thinking about Flipper. Both are togglable
from either side. The old index made this impossible — the console could edit a
flag but never create one, which contradicted the positioning above.

What is *not* a feature is a parameter that isn't a toggle at all: a `STRING`,
a `NUMBER`, or structured `JSON` config. Those are ignored — see the gate-key
test below.

**One Firebase project per environment.** Staging and production must not share
one. Parameter names are the feature keys with nothing prepended, so a flag
flipped in staging lands directly on production's flags — there is no namespace
left to keep them apart.

Firebase reaches the same conclusion independently: builds that differ by
release status shouldn't share resources, because debug data ends up polluting
or overriding production data, and it recommends a separate project for each
environment in the workflow. See
<https://firebase.google.com/docs/projects/dev-workflows/general-best-practices#registering-app-variants>.

Note the distinction it draws — platform variants of the *same* app (iOS,
Android, web) belong in one project, which is exactly the case this gem is built
for. It's release status that separates projects, not platform.

**Multi-tenancy: one Firebase project per tenant, for now.** Dropping the prefix
removed the only isolation the adapter had — two tenants sharing a project would
collide on parameter names, silently overwriting each other's flags. Separate
projects also stop tenants sharing a write quota that is only a few hundred
publishes a day.

Firebase's own guidance points the same way, and for broader reasons than ours:
housing logically independent apps in one project risks configuration and data
privacy problems — analytics aggregated across tenants, shared authentication,
database structures that get complicated, security rules that get hard to reason
about. Its recommendation is to register each app in its own project, including
each branded variant of a white-label product. See
<https://firebase.google.com/docs/projects/dev-workflows/general-best-practices#avoiding-multi-tenancy>.

So the stance here isn't only a consequence of dropping the prefix — it's what
Firebase recommends regardless. Still worth revisiting if someone genuinely
needs multiple tenants in one project, but the bar is higher than "the adapter
could support it": both plausible answers, a restored prefix or a per-tenant
namespace, reintroduce the naming or endpoint complexity this change removed,
and neither addresses the concerns above.

The in-memory template is a plain `Hash` matching the API JSON shape — not a
typed model object. See "Why no generated client" below.

**The `defaultValue.value` encoding is client-visible.** Mobile and web clients
fetch these same parameters, so the JSON blob is not free to restructure — a
change here breaks every app parsing it. This is also the main thing standing
between the gem and its own positioning: `getBoolean()` on a gate blob returns
`false`, so clients can't consume it natively. Writing simple boolean features
as a real `BOOLEAN` parameter (falling back to the blob only when a feature uses
actor/group/percentage gates) is the planned fix. Note the sharp edge that
design carries: a feature that starts boolean-only and later gains an actor gate
silently flips **off** for every client, because `getBoolean()` fails soft.

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

Writes from elsewhere — the Firebase console, another process — are picked up by
`Listener` if one is running, and otherwise not until the TTL expires.

Note that `cache_ttl` and a shared cache store are mutually exclusive in
practice: put an `ActiveSupportCacheStore` in front and this in-process cache
becomes the layer nothing can invalidate, since expiring a Redis or memcached key
cannot reach an ivar inside each process. Use `cache_ttl: 0` behind one.

## The listener

`Listener` (its own file — the adapter class is already near the 250-line
`Metrics/ClassLength` cap) polls for template changes and keeps the adapter's
cache current, so a console publish reaches a running process in seconds.

Why polling at all: there is no server-side push. Firebase's own server guidance
recommends periodically reloading the template and describes no streaming
mechanism for servers. The realtime endpoint the client SDKs use is a client API
— see "Things to be careful about".

Design decisions that are easy to undo by accident:

- **The probe is `listVersions`, not a template fetch.** One version's metadata
  is cheap enough to poll; the template isn't. A conditional GET would be
  cheaper still, but `If-None-Match` is not honoured on the template endpoint —
  tested against a live project, it always returns 200 with a full body.
- **The poll waits on a `ConditionVariable`, not `sleep`.** That's what makes
  `stop` prompt instead of blocking for the rest of an interval. Don't "simplify"
  it back to a sleep.
- **The interval is jittered ±30%.** Without it every process in a fleet wakes on
  the same second and stampedes the API.
- **No exception escapes the loop.** A Remote Config blip must not silently end
  change detection for the life of the process; failures back off to 5 minutes.
- **The first tick establishes a baseline and reports nothing.** Otherwise every
  feature looks new and the first poll fires a change for all of them.
- **It never auto-starts.** Threads don't survive `fork`, and a listener started
  at adapter construction would also start in `rails console`, rake tasks and
  `assets:precompile`. The pid check that respawns after a fork is a backstop,
  not a substitute for `on_worker_boot` / Sidekiq's `:startup`.

`on_change` handlers exist only for caches the listener can't reach itself — a
shared store in front of the adapter. The adapter's own cache is updated by
`refresh!` with no handler required, so don't add a default handler that calls
`reload!`; it would be redundant work.

`probe:` is the seam for push sources. Anything answering `#current_version`, or
any callable, returning a version number. Two deferred paths plug in here
without touching the listener: a Cloud Function webhook writing the version into
a shared cache store, and the realtime stream. Both are described in
test-tracker#469. The listener must stay ignorant of where the number came from.

`tick` is public so specs can drive the loop inline. Keep it that way — the four
thread-lifecycle examples are the only ones that start a real thread, and that
ratio is why the suite is still fast and not flaky.

## Gate serialization

`serialize_gates` / `deserialize_gates` round-trip the Flipper gate hash to a
JSON-safe shape: `Set` → `Array` on write, `Array` → `Set` on read. The five
gate keys we persist match Flipper's default config — `boolean`, `actors`,
`groups`, `percentage_of_actors`, `percentage_of_time`. Newer gate types
(`:expression`) are not handled; if Flipper adds new built-in gates we'll need
to extend `default_config` and the (de)serializers together.

These only cover the JSON fallback form; boolean-only features go through
`boolean_gates` instead. Watch that round-trip: an empty gate set serialises to
`BOOLEAN` `false` and must read back as `boolean: nil`, **not** `"false"`.
`#disable` writes an all-nil config, and Flipper's shared adapter spec compares
`#get` against `default_config` exactly.

## Running tests

The system Ruby is 2.6, below our `>= 2.7` floor. Ruby is managed by **mise**
here, pinned by `.ruby-version`, so an activated shell has the right one:

```sh
bundle exec rspec
```

Two traps. A non-interactive shell may not have mise activated and will fall
through to system Ruby 2.6 — check `ruby -v` before trusting a failure. And if
`.ruby-version` pins a version mise hasn't installed, mise installs it on first
use, which looks like a hang for several minutes.

`.claude/settings.json` allowlists the bare `bundle`/`rspec`/`rubocop`/`gem`
commands — deliberately not absolute paths, which is what went stale last time.

The suite is fully offline — `FakeClient` (in `spec/support/`) stands in for
the REST client and enforces the same ETag semantics. There are no live HTTP
fixtures; webmock is in the dev deps for future contract tests but isn't used
yet.

## Things to be careful about

- **Don't add live integration tests to the default `rspec` run.** Hitting
  real Firebase from CI burns the project's write quota.
- **Don't bump the ETag retry budget past 1.** See above.
- **Parameter names are a client-visible interface.** Mobile and web clients
  read these parameters by name, so a rename is a breaking change for every app,
  not an internal refactor.

  The `flipper__` prefix and the `<prefix>__index__` sentinel are **gone**. Both
  answered the same question — which parameters are ours — and both leaked into
  the console; `valueType` answers it now without appearing in a name. Don't
  reintroduce either.

  Renaming was free while no apps shipped against these names. That window is
  closing: once one does, this rule reverts to its original meaning — don't
  rename without a migration path.
- **Don't expose Remote Config conditions as a new user-facing concept.** An
  `#enable_for_condition` that lets callers write arbitrary conditions is still
  the wrong idea — it becomes a second, competing way to express a flag.

  This rule has a deliberate exception under discussion: making
  `Flipper.enable(:f, percentage_of_actors: 25)` author a real Remote Config
  condition, so clients can evaluate the ramp natively. That is a condition as
  the *implementation* of an existing gate, with the Flipper API unchanged —
  not a new concept. Note that Firebase's built-in `percent` operator can't be
  used for it: client templates are evaluated by Google's backend at fetch time,
  against an identifier the server can't see, so the two sides can never agree.
  The workable scheme buckets on a custom signal both sides derive from the same
  user id.
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
