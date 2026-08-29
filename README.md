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

**Always wrap this adapter with [`Flipper::Adapters::Memoizable`](https://www.flippercloud.io/docs/adapters/memoizable)
or the per-request `Flipper::Middleware::Memoizer`** to avoid a Remote Config
fetch on every flag check.

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
      prefix:      'flipper__',  # optional, default 'flipper__'
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

Note that nothing currently notices a template published *outside* this
process — someone editing flags in the Firebase console, or another app
writing through this adapter — until the relevant layer expires on its own.

## Storage layout

Each Flipper feature becomes one Remote Config parameter, named
`<prefix><feature_key>`. The parameter's `defaultValue.value` is a JSON blob
representing the gate state:

```json
{
  "boolean": "true",
  "actors": ["1", "2"],
  "groups": ["admins"],
  "percentage_of_actors": "25",
  "percentage_of_time": null
}
```

A sentinel parameter `<prefix>__index__` holds a JSON array of all known
feature keys, so listing features doesn't have to scan every parameter.

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
- **Detecting changes published elsewhere.** Nothing pushes or polls for
  updates yet, so a publish made in the Firebase console or by another process
  is only picked up once the caching layer in front of it expires. See
  [Caching and memoization](#caching-and-memoization).

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
