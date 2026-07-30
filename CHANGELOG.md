# Changelog

## 0.1.0

- Initial release: `configure`, `attribute(Uri)` (claim_token | ct),
  `applyCode`, `identify`, `attributedAffiliateId`.
- Injectable `KeyValueStore` (shared_preferences in production, in-memory for
  tests) and `HttpPoster` (dart:io in production).
- Silent-safe networking — failures never throw into the host app.
