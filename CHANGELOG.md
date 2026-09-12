# Changelog

## 0.2.0

**Two calls, and no API URL.** `configure` is gone: the production host is compiled
into the SDK, so nothing about our infrastructure is typed into an app any more.

Breaking:

- `MyAppAffiliate.configure(apiKey:baseUrl:)` → `MyAppAffiliate.start(apiKey:)`, which
  is async and returns whether a key was found. `baseUrl` → the optional `apiBaseUrl`,
  defaulting to `https://api.myappaffiliate.com`.

Added:

- `start()` reads the key from `--dart-define=MYAPPAFFILIATE_API_KEY`, and the host
  from `--dart-define=MYAPPAFFILIATE_API_BASE_URL`, so neither has to appear in source.
- First-open attribution, matching the iOS engine: `start` retries a referral an
  earlier launch failed to deliver, and on a fresh install with nothing pending asks
  the API for a deferred match (once per install). Final rejections (404 no click, 409
  ambiguous) are dropped rather than retried forever.
- `attribute(uri)` now also claims a referral code from a plain link (`?via=`, `?ref=`,
  `?maa_code=`, `?code=`), not just a claim token.
- `MyAppAffiliate.reset()` — clears all persisted state for logout and data-erasure
  requests. `MyAppAffiliate.isStarted` and a `debug` flag.
- A trailing slash on the base URL no longer produces `//sdk/install`.

Removed from the documented integration:

- The `affiliate_id` RevenueCat subscriber attribute step. Nothing in the pipeline ever
  read it — attribution joins on the user id from `identify(userId)`.

## 0.1.0

- Initial release: `configure`, `attribute(Uri)` (claim_token | ct),
  `applyCode`, `identify`, `attributedAffiliateId`.
- Injectable `KeyValueStore` (shared_preferences in production, in-memory for
  tests) and `HttpPoster` (dart:io in production).
- Silent-safe networking — failures never throw into the host app.
