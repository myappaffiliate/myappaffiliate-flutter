# myappaffiliate_flutter

The drop-in Flutter SDK that connects your app to MyAppAffiliate attribution.
One tiny dependency (`shared_preferences`), Dart 3, `dart:io` networking.
Target: a working integration in **under 30 minutes**.

It does four things: stores a stable device id, records the attribution from an
incoming link (or a manual code), binds your user id to it, and hands you the
attributed affiliate id to pass into your billing layer (RevenueCat's
`purchases_flutter` shown below; any provider works the same way).

## Install

```yaml
# pubspec.yaml
dependencies:
  myappaffiliate_flutter: ^0.1.0
```

(Until the pub.dev release, use a git dependency:
`myappaffiliate_flutter: { git: { url: https://github.com/myappaffiliate/myappaffiliate-flutter } }`.)

## 1. Configure (once, at launch)

```dart
import 'package:myappaffiliate_flutter/myappaffiliate_flutter.dart';

void main() {
  MyAppAffiliate.configure(
    apiKey: 'pk_live_…',                        // your app's SDK key
    baseUrl: 'https://api.myappaffiliate.com',  // your API base URL
  );
  runApp(const MyApp());
}
```

## 2. Capture the attribution from the incoming link

Wire up deep links per platform (Universal Links / App Links, e.g. with
`app_links` or `uni_links`), then forward the URI:

```dart
appLinks.uriLinkStream.listen((uri) {
  MyAppAffiliate.attribute(uri); // parses claim_token | ct
});
```

**Manual-code fallback** (creator gives followers a code like `JESS20`):

```dart
await MyAppAffiliate.applyCode('JESS20');
```

## 3. Identify the user (once you know who they are)

```dart
await MyAppAffiliate.identify(userId); // same id you use with your billing provider
```

## 4. Pass the affiliate into RevenueCat (before the purchase)

This closes the loop — RevenueCat sends `affiliate_id` back to us in the purchase
webhook, and we map the subscription revenue to that creator.

```dart
import 'package:purchases_flutter/purchases_flutter.dart';

final affiliateId = await MyAppAffiliate.attributedAffiliateId();
if (affiliateId != null) {
  await Purchases.setAttributes({'affiliate_id': affiliateId});
}
// then make the purchase as usual
```

## API

| Call | Purpose |
|---|---|
| `MyAppAffiliate.configure(apiKey:, baseUrl:)` | Initialize once at launch |
| `MyAppAffiliate.attribute(uri)` | Record attribution from an incoming link |
| `MyAppAffiliate.applyCode(code)` | Manual-code attribution fallback |
| `MyAppAffiliate.identify(userId)` | Bind your user id to the attribution |
| `MyAppAffiliate.attributedAffiliateId()` | The attributed affiliate id (or `null`) |

Every call **fails silently** — network errors resolve to `false`/`null` and never
throw into your app. Calls before `configure` are safe no-ops.

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
