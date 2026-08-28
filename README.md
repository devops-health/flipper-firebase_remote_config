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
require 'flipper/adapters/memoizable'

Flipper.configure do |config|
  config.adapter do
    base = Flipper::Adapters::FirebaseRemoteConfig.new(
      project_id:  ENV.fetch('FIREBASE_PROJECT_ID'),
      credentials: ENV.fetch('GOOGLE_APPLICATION_CREDENTIALS'), # path to service-account JSON
      prefix:      'flipper__',  # optional, default 'flipper__'
      cache_ttl:   30,           # optional, default 30 seconds
    )
    Flipper::Adapters::Memoizable.new(base)
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

## Memoization

This adapter already caches the fetched Remote Config template in-process for
`cache_ttl` seconds, but that cache is still a network round trip away the
moment it expires or on a fresh process. Wrapping the adapter with
`Flipper::Adapters::Memoizable` (process-wide, always on) or
`Flipper::Middleware::Memoizer` (per-request, Rails/Rack) makes repeated
checks of the *same* feature within a request/scope free, regardless of where
`cache_ttl` currently sits.

### `Flipper::Adapters::Memoizable` — always-on wrapping

This is the wrapping shown in [Configuration](#configuration) above, and it's
the right default for most apps:

```ruby
require 'flipper'
require 'flipper/adapters/firebase_remote_config'
require 'flipper/adapters/memoizable'

Flipper.configure do |config|
  config.adapter do
    base = Flipper::Adapters::FirebaseRemoteConfig.new(
      project_id:  ENV.fetch('FIREBASE_PROJECT_ID'),
      credentials: ENV.fetch('GOOGLE_APPLICATION_CREDENTIALS'),
    )
    Flipper::Adapters::Memoizable.new(base)
  end
end
```

With no further configuration this memoizes forever (per process) until a
write (`enable`, `disable`, `add`, `remove`, `clear`) invalidates the affected
cache entry — reads never go stale beyond that, because writes go through the
same `Memoizable` instance and expire what they touch.

Outside of a Rack request — a Rake task or Sidekiq job that checks the same
flag many times in a loop — you can scope memoization manually:

```ruby
Flipper.adapter.memoize = true # Flipper.adapter is the Memoizable instance configured above
begin
  Widget.find_each do |widget|
    next unless Flipper.enabled?(:widget_export, widget)
    # ...
  end
ensure
  Flipper.adapter.memoize = false # also clears the cache
end
```

### `Flipper::Middleware::Memoizer` — per-request, Rails/Rack

If you'd rather scope caching to the lifetime of a single request (and avoid
holding stale flag state across requests in long-lived processes), use the
Rack middleware instead of, or alongside, `Memoizable`. It wraps whatever
adapter `Flipper.instance` is using with `Memoizable` for the duration of the
request and clears it in an `ensure` block afterwards.

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

`SetupEnv` puts the configured `Flipper.instance` into `request.env['flipper']`
so `Memoizer` can find it; `Memoizer` then flips `memoize = true` on that
instance's adapter before the request and `memoize = false` after.

Useful options on `Flipper::Middleware::Memoizer`:

```ruby
Rails.application.config.middleware.use Flipper::Middleware::Memoizer,
  preload: [:some_feature, :another_feature], # or `true` to preload every feature
  unless:  ->(request) { request.path.start_with?('/assets') }
```

`preload` issues one upfront fetch for the listed (or all) features at the
start of the request instead of lazily fetching on first check — worth
turning on if a request is known to check many flags, since it collapses
what would otherwise be several lazy `Memoizable` cache misses into one.

If your app uses the `flipper-rails` gem, the equivalent setup is the
`config.flipper.memoize` / `config.flipper.preload` initializer options that
gem provides instead of wiring the middleware up by hand.

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
2. Mutates the template in memory.
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
- **Server-side caching beyond the adapter's in-process TTL.** Combine with
  `Flipper::Adapters::Memoizable` and ideally a longer-lived cache (Redis,
  Memcached) for high-traffic apps.

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
