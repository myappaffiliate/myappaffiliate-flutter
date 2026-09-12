# myappaffiliate_flutter

The drop-in Flutter SDK that connects your app to MyAppAffiliate attribution. One tiny
dependency (`shared_preferences`), Dart 3, `dart:io` networking.

**The whole integration is two calls.** Start the SDK with your key; tell it who the
user is. Everything else — retrying an offline first launch, asking for a deferred
match on a fresh install — happens inside.

You never type an API URL. The production host is compiled in.

## Install

```bash
flutter pub add myappaffiliate_flutter
```

```yaml
# or by hand, in pubspec.yaml
dependencies:
  myappaffiliate_flutter: ^0.2.0
```

## 1. Start it

```dart
import 'package:myappaffiliate_flutter/myappaffiliate_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await MyAppAffiliate.start(apiKey: 'pk_live_…');
  runApp(const MyApp());
}
```

### Keeping the key out of source

Supply it at build time and the call takes no arguments at all:

```bash
flutter build ios --dart-define=MYAPPAFFILIATE_API_KEY=pk_live_…
```

```dart
await MyAppAffiliate.start();
```

## 2. Identify the user

```dart
await MyAppAffiliate.identify(userId);
```

The id must be the **same string your billing provider reports back to us**:
RevenueCat's `logIn(...)` id, Adapty's customer user id, Superwall's app user id,
Stripe's `metadata.customer_user_id`, Paddle's custom data. That is the only join key
there is — if the two differ, everything looks healthy and no commission is ever
created.

That's it. There is no third step. In particular you do **not** need to set an
`affiliate_id` subscriber attribute in RevenueCat or anywhere else: nothing reads it,
and it is no longer part of the integration.

## Optional

```dart
// Incoming deep links — Flutter has no built-in link stream, so pass URIs
// through from app_links (or uni_links) if links open your app directly.
appLinks.uriLinkStream.listen(MyAppAffiliate.attribute);

// A "Got a creator code?" field — attributes with no deep-link setup at all.
await MyAppAffiliate.applyCode('JESS20');

// The attributed affiliate, for your own UI or analytics.
final affiliateId = await MyAppAffiliate.attributedAffiliateId();  // String?

// Logout / data-erasure request.
await MyAppAffiliate.reset();

// Staging or self-hosted API, and debug logging.
await MyAppAffiliate.start(
  apiKey: 'pk_live_…',
  apiBaseUrl: 'https://staging.example.com',
  debug: true,
);
```

The host override also works as `--dart-define=MYAPPAFFILIATE_API_BASE_URL=…`, so a
staging build needs no code change at all.

## API

| Call | Purpose |
|---|---|
| `MyAppAffiliate.start(apiKey:)` | Start once at launch; also runs first-open attribution |
| `MyAppAffiliate.identify(userId)` | Bind your user id to the attribution |
| `MyAppAffiliate.attribute(uri)` | Record attribution from an incoming link |
| `MyAppAffiliate.applyCode(code)` | Creator-code entry |
| `MyAppAffiliate.attributedAffiliateId()` | The attributed affiliate id (or `null`) |
| `MyAppAffiliate.reset()` | Clear all persisted state (logout / erasure requests) |
| `MyAppAffiliate.isStarted` | Whether `start` has run |

Every call **fails silently** — network errors resolve to `false`/`null` and never
throw into your app. Calls before `start` are safe no-ops. An attribution that fails
to reach us is persisted and retried on the next launch; final rejections (404 no
click, 409 ambiguous match) are dropped rather than retried forever.

## Privacy

No advertising ID, no fingerprinting, no cross-app tracking. The SDK stores only a
generated device id and the attributed affiliate id (via `shared_preferences`).
Attribution is first-party and deterministic.

## Development

```bash
flutter test
```

Storage and HTTP are injectable (`KeyValueStore`, `HttpPoster`) so the engine is
unit-tested with an in-memory store and a fake transport (see `test/`).
