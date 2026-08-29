# flipper-firebase_remote_config

[![CI](https://github.com/devops-health/flipper-firebase_remote_config/actions/workflows/ci.yml/badge.svg)](https://github.com/devops-health/flipper-firebase_remote_config/actions/workflows/ci.yml)
[![Gem Version](https://badge.fury.io/rb/flipper-firebase_remote_config.svg)](https://rubygems.org/gems/flipper-firebase_remote_config)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A [Flipper](https://www.flippercloud.io/docs) adapter that stores feature state
in [Firebase Remote Config](https://firebase.google.com/docs/remote-config).
Useful when you want flags reachable from both your Ruby backend and your
Firebase-using mobile / web clients without standing up a separate flag store.

## Read this first — when not to use it

Firebase Remote Config is **eventually consistent** and **rate-limited for
writes** (Firebase publishes a daily write quota per project, on the order of
hundreds of writes/day). This makes it a poor fit for:

- Per-request flag flipping
- High-frequency A/B test ramping
- Anything that depends on a write being visible immediately

It is a good fit for low-frequency operational toggles that you want a single
source of truth for across server and client platforms.

**Don't run it without a caching layer**, or you'll pay a Remote Config fetch on
every flag check. `Flipper::DSL` already wraps your adapter in `Memoizable`, but
that memoizes nothing until something turns it on — see
[Caching and memoization](#caching-and-memoization) for what to put in front of
it and how the layers interact.

## Installation

```ruby
# Gemfile
gem 'flipper-firebase_remote_config'
```

## Configuration

```ruby
require 'flipper'
require 'flipper/adapters/firebase_remote_config'

Flipper.configure do |config|
  config.adapter do
    Flipper::Adapters::FirebaseRemoteConfig.new(
      project_id:  ENV.fetch('FIREBASE_PROJECT_ID'),
      credentials: ENV.fetch('GOOGLE_APPLICATION_CREDENTIALS'), # path to service-account JSON
      cache_ttl:   30,           # optional, default 30 seconds; use 0 behind a cache store
    )
  end
end
```

The service account needs the **Firebase Remote Config Admin** role (or
equivalent custom role granting `cloudconfig.configs.get` and
`cloudconfig.configs.update`).

`credentials` accepts:

- A file path to a service-account JSON key (`String`)
- An open `IO`/`StringIO` containing service-account JSON
- A pre-built `Google::Auth::*` credentials object
- `nil` to fall back to Application Default Credentials

## Caching and memoization

Up to four layers can sit between a feature check and Firebase. You don't need
all of them, but you do need to know how they interact:

| Layer | Scope | Configured by |
| --- | --- | --- |
| `Memoizable` | one request or block | Flipper (already wrapped; off until toggled) |
| this adapter's `cache_ttl` | one process | `cache_ttl:` below |
| a shared cache store | the whole fleet | `flipper-active_support_cache_store`, `flipper-dalli` |
| Remote Config | source of truth | — |

### Memoization (per request)

`Flipper::DSL` **already wraps your adapter in `Flipper::Adapters::Memoizable`**
— `memoize: true` is its default — so you don't need to wrap it yourself, and
doing so just nests one `Memoizable` inside another.

What you do need to know is that `Memoizable` starts with memoization *off*.
Wrapping alone caches nothing; every read still reaches the adapter until
something sets `memoize = true`.

In Rack or Rails, that something is `Flipper::Middleware::Memoizer`, which
turns it on for the duration of a request and back off in an `ensure`:

```ruby
# config/initializers/flipper.rb
require 'flipper'
require 'flipper/adapters/firebase_remote_config'
require 'flipper/middleware/setup_env'
require 'flipper/middleware/memoizer'

Flipper.configure do |config|
  config.adapter do
    Flipper::Adapters::FirebaseRemoteConfig.new(
      project_id:  ENV.fetch('FIREBASE_PROJECT_ID'),
      credentials: ENV.fetch('GOOGLE_APPLICATION_CREDENTIALS'),
    )
  end
end

Rails.application.config.middleware.use Flipper::Middleware::SetupEnv, -> { Flipper.instance }
Rails.application.config.middleware.use Flipper::Middleware::Memoizer
```

`SetupEnv` puts the configured instance into `request.env['flipper']` so
`Memoizer` can find it. Useful options:

```ruby
Rails.application.config.middleware.use Flipper::Middleware::Memoizer,
  preload: [:some_feature, :another_feature], # or `true` for every feature
  unless:  ->(request) { request.path.start_with?('/assets') }
```

`preload` collapses what would otherwise be several lazy cache misses into one
upfront fetch — worth turning on when a request checks many flags.

Outside a request — a Rake task or Sidekiq job checking the same flag in a
loop — scope it by hand. Note that `memoize=` clears the cache on *both*
transitions, so the `ensure` both stops memoizing and drops what was cached:

```ruby
Flipper.memoize = true
begin
  Widget.find_each do |widget|
    next unless Flipper.enabled?(:widget_export, widget)
    # ...
  end
ensure
  Flipper.memoize = false
end
```

If your app uses `flipper-rails`, the `config.flipper.memoize` /
`config.flipper.preload` initializer options do the middleware wiring for you.

### A shared cache store (per fleet)

Memoization only helps *within* one request. Across requests and processes,
put a cache store in front of the adapter so one fetch serves the whole fleet
instead of one per process:

```ruby
firebase = Flipper::Adapters::FirebaseRemoteConfig.new(
  project_id:  ENV.fetch('FIREBASE_PROJECT_ID'),
  credentials: ENV.fetch('GOOGLE_APPLICATION_CREDENTIALS'),
  cache_ttl:   0, # see below — this is load-bearing
)

Flipper.configure do |config|
  config.adapter do
    Flipper::Adapters::ActiveSupportCacheStore.new(firebase, Rails.cache, expires_in: 5.minutes)
  end
end
```

> **Set `cache_ttl: 0` whenever a cache store is in front.**
>
> This adapter's own in-process cache exists because, on its own, there is no
> better layer available. Once a shared store is in front of it, that layer
> becomes the one nothing can invalidate: expiring a key in Redis or memcached
> does not reach a plain instance variable inside each of your processes, so
> reads keep being served from a stale template for up to `cache_ttl` seconds
> after the store was cleared. Turning it off leaves exactly one cache to
> reason about.

Any `ActiveSupport::Cache::Store` works — this is not a Redis feature:

| Store | Shared across processes | Notes |
| --- | --- | --- |
| `RedisCacheStore` | yes | one fetch serves the fleet |
| `MemCacheStore` | yes | identical behaviour; a drop-in for Redis here |
| `MemoryStore` | no | per-process, so one fetch per process — fine for small fleets, and no external dependency |
| none | — | reads fall through to Remote Config; rely on `cache_ttl` instead |

`flipper-dalli` is the same idea against Dalli directly rather than through
ActiveSupport.

A template published *outside* this process — someone flipping a flag in the
Firebase console, or another app writing through this adapter — is only noticed
when the layer in front of it expires, unless you run a listener. See
[Noticing changes published elsewhere](#noticing-changes-published-elsewhere).

## Noticing changes published elsewhere

Someone flips a flag in the Firebase console. Without a listener, your processes
keep serving the old value until whichever cache sits in front of the adapter
expires — up to `cache_ttl`, or the full TTL of your cache store.

A `Listener` closes that window:

```ruby
listener = Flipper::Adapters::FirebaseRemoteConfig::Listener.new(adapter, interval: 10)
listener.start
```

That's the whole setup when the adapter's own cache is the only one you have.
Each tick asks Remote Config for the current template *version* — a small call,
not a template fetch — and only pulls the template when the version actually
moves.

If you have a cache store in front of the adapter, the listener can't reach it,
so tell it what to expire. It hands you exactly the features that changed:

```ruby
listener.on_change do |changed_keys|
  changed_keys.each { |key| cached.expire_feature_cache(key) }
  cached.expire_get_all_cache
end
```

Added and removed features count as changed, so a feature deleted in the console
won't linger in your cache.

### Where to start it

**Threads do not survive `fork`.** A listener started before your server forks
leaves a dead thread in every worker. Start it after the fork, from your
server's own hook:

```ruby
# config/puma.rb — clustered mode
on_worker_boot     { LISTENER.start }
on_worker_shutdown { LISTENER.stop }
```

```ruby
# Sidekiq — the highest-value case, since job processes are long-lived and
# would otherwise sit on stale flags for the full TTL
Sidekiq.configure_server do |config|
  config.on(:startup)  { LISTENER.start }
  config.on(:shutdown) { LISTENER.stop }
end
```

For Puma in single mode, Sinatra, or plain Rack — anything not preloading and
forking — start it from your initializer or `config.ru` and `at_exit { LISTENER.stop }`.
Under Unicorn or Passenger, use `after_fork` / `:starting_worker_process`.

Three things worth knowing:

- **It never starts itself.** That's deliberate: an auto-starting listener would
  also spin up in `rails console`, in rake tasks, and during
  `assets:precompile`. Start it explicitly, from the hooks above.
- **In Rails development, don't.** The listener holds a reference to an adapter
  that code reloading orphans, so you leak a thread per reload. Guard it, or
  skip it in development.
- **Every process polls.** With a 10s interval and 50 processes that's 5
  requests/second against Remote Config, forever. Reads aren't the quota that
  bites — writes are — but a shared cache store lets one process's fetch serve
  the fleet, which is the better shape at scale.

### Using a different change signal

`probe:` replaces the version check with your own. Anything that responds to
`current_version`, or any callable, returning a version number:

```ruby
Listener.new(adapter, probe: -> { $redis.get('flipper:rc_version')&.to_i })
```

The listener doesn't care where the number came from — only that it changed.
That's the seam for push: a Cloud Functions `onConfigUpdated` trigger writing
`event.data.versionNumber` somewhere your processes can read cheaply, so they
notice within a second instead of within an interval.

## Storage layout

Each Flipper feature is one Remote Config parameter, **named for the feature key
exactly** — the feature `:search` is the parameter `search`. There is no prefix
and no bookkeeping parameter, because your client apps read these names too.

A feature whose only gate is on/off is stored as a real `BOOLEAN` parameter:

```
search   BOOLEAN   true
```

A feature using actor, group or percentage gates falls back to a JSON blob of
the gate state, since those gates are evaluated per-actor by the backend and
have no meaning to a client:

```json
{
  "boolean": null,
  "actors": ["1", "2"],
  "groups": ["admins"],
  "percentage_of_actors": "25",
  "percentage_of_time": null
}
```

The adapter recognises which parameters are features by their type: a parameter
counts if it's `BOOLEAN`, or if its value parses as the gate shape above. One
consequence worth knowing in both directions — **a `BOOLEAN` parameter you
create directly in the Firebase console is a real Flipper feature**, and so is
any boolean parameter your app already had.

### One Firebase project per environment

**Staging and production need separate Firebase projects.** Parameter names are
the feature keys with nothing prepended, so there is no namespace keeping
environments apart — a flag flipped in staging lands directly on production's
flags.

This is [Firebase's own recommendation][envs] regardless of this gem: builds
that differ by release status shouldn't share resources, because debug data
ends up polluting or overriding production data.

Note what that guidance *doesn't* separate: platform variants of the same app —
iOS, Android, web — belong together in one project. That's the case this adapter
is built for. Release status splits projects, not platform.

[envs]: https://firebase.google.com/docs/projects/dev-workflows/general-best-practices#registering-app-variants

### Multi-tenant setups

**Give each tenant its own Firebase project too.** Two tenants sharing one
project would overwrite each other's flags with no warning, for the same reason
environments would. Separate projects also keep tenants from sharing a write
quota that is only a few hundred publishes per day.

Firebase [recommends the same thing][multi-tenancy] for broader reasons — one
project holding logically independent apps leads to analytics aggregated across
tenants, shared authentication, and security rules that get hard to reason
about. Each branded variant of a white-label product gets its own project.

[multi-tenancy]: https://firebase.google.com/docs/projects/dev-workflows/general-best-practices#avoiding-multi-tenancy

## Reading these flags from a client app

This is the point of the gem: the same parameter, flipped in one place, read by
both the backend and your Firebase-using apps. For simple on/off features it
just works, with no knowledge of this gem on the client side:

```swift
// Swift — Firebase iOS SDK
let enabled = RemoteConfig.remoteConfig()["search"].boolValue
```

```kotlin
// Kotlin — Firebase Android SDK
val enabled = Firebase.remoteConfig.getBoolean("search")
```

```js
// JavaScript — Firebase Web SDK
const enabled = getValue(remoteConfig, 'search').asBoolean();
```

### The one rule: client-visible features stay boolean-only

Actor, group and percentage gates are evaluated per-actor by the Ruby backend.
A client has no actor to evaluate them against, so a feature using them is
stored as JSON instead — and **`getBoolean()` on a JSON value returns `false`
rather than raising.**

That means a feature which starts as a plain boolean and later gains an actor
or percentage gate **silently switches off for every client**, mid-rollout, with
no error anywhere. The adapter warns on stderr when a write causes that
transition, but nothing can stop it.

So: features your apps read should be flipped with plain `Flipper.enable(:search)`
and `Flipper.disable(:search)`. Keep actor and percentage gates for backend-only
features.

Coordinating a *release* across backend and app works today. Coordinating a
gradual *ramp* does not — the backend buckets actors in Ruby, and a client SDK
would have to bucket itself independently, with no guarantee the two agree.

## Concurrency and retries

Remote Config uses ETag-based optimistic concurrency. The adapter:

1. Fetches the template + ETag (cached for `cache_ttl` seconds).
2. Mutates a private copy of the template in memory, so concurrent readers
   never observe a half-applied write.
3. Publishes with `If-Match: <etag>`.
4. On a `412 Precondition Failed`, reloads and retries **once**. If the retry
   also fails, `Flipper::Adapters::FirebaseRemoteConfig::ETagMismatch` is
   raised.

If you have a write-heavy multi-process workload that frequently conflicts,
this adapter is the wrong tool.

## Not yet supported

- **Remote Config conditions.** Firebase Remote Config has a powerful
  conditional value system (per-platform, per-country, per-user-property). v0.1
  ignores it: every gate is stored as the parameter's `defaultValue` only. If
  you change a parameter's `conditionalValues` in the Firebase console, the
  adapter will not see those changes. Conditions may be exposed as a Flipper
  extension in a future release; PRs welcome.
- **Push-based change detection.** The listener polls. There is no server-side
  push API for Remote Config, so sub-second propagation means either a Cloud
  Function webhook or the undocumented realtime stream the client SDKs use —
  both plug into `probe:` but neither ships here yet.

## Why this gem talks REST directly

The Firebase Remote Config v1 API does not have a generated Ruby client gem
(`google-apis-firebaseremoteconfig_v1` is not published to RubyGems, and the
deprecated umbrella `google-api-client` does not include it either). So the
two REST calls we actually need (`GET` + `PUT` on
`/v1/projects/{id}/remoteConfig`) go through `Net::HTTP` directly. Auth is
real: we depend on [`googleauth`](https://github.com/googleapis/google-auth-library-ruby)
for the OAuth2 service-account flow. See `CLAUDE.md` for the longer story.

## Development

```sh
bundle install
bundle exec rspec
bundle exec rubocop
```

## Contributing

Bug reports and pull requests are welcome on GitHub at
<https://github.com/devops-health/flipper-firebase_remote_config>. See
[CONTRIBUTING.md](CONTRIBUTING.md) for dev setup and PR guidelines.

For security issues, please follow [SECURITY.md](SECURITY.md) rather than
opening a public issue.

## License

Released under the [MIT License](LICENSE).
