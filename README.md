# flipper-firebase_remote_config

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

## License

MIT.
