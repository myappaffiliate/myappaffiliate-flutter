/// MyAppAffiliate Flutter SDK — first-party, deterministic affiliate attribution.
///
/// The whole integration is two calls:
///
/// ```dart
/// await MyAppAffiliate.start(apiKey: 'pk_live_…');  // once, at launch
/// await MyAppAffiliate.identify(userId);            // once you know the user
/// ```
///
/// The API host is compiled in — you never type a URL. `start` also retries
/// anything an earlier launch failed to deliver and asks for a deferred match on
/// a fresh install, so a user who installed from a creator's link is attributed
/// without you calling anything else.
///
/// Everything beyond the two calls — a staging host, handling an incoming deep
/// link, manual code entry, reading the attributed affiliate — is optional.
///
/// Every network path is silent-safe: failures resolve to `false`/`null` and
/// never throw into the host app.
library myappaffiliate_flutter;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

/// Where the SDK talks to when nothing overrides it. Mirrors `SITE.api` in
/// @maa/brand.
const String kDefaultApiBaseUrl = 'https://api.myappaffiliate.com';

/// Compile-time key, so `flutter build --dart-define=MYAPPAFFILIATE_API_KEY=…`
/// keeps the key out of source control and `MyAppAffiliate.start()` takes no
/// arguments at all.
const String _envApiKey = String.fromEnvironment('MYAPPAFFILIATE_API_KEY');

/// Compile-time host override, for a staging API or a self-hosted deployment.
const String _envApiBaseUrl = String.fromEnvironment('MYAPPAFFILIATE_API_BASE_URL');

/// Tiny key/value store the SDK uses to persist the device id, the attributed
/// affiliate id, and any attribution payload still waiting to be delivered.
/// Abstracted so the engine is testable without SharedPreferences.
abstract class KeyValueStore {
  Future<String?> get(String key);
  Future<void> set(String key, String? value);
}

/// Test/non-Flutter fallback.
class InMemoryStore implements KeyValueStore {
  final Map<String, String> _map = {};

  @override
  Future<String?> get(String key) async => _map[key];

  @override
  Future<void> set(String key, String? value) async {
    if (value == null) {
      _map.remove(key);
    } else {
      _map[key] = value;
    }
  }
}

/// Production store — shared_preferences, keys prefixed `maa.`.
class SharedPreferencesStore implements KeyValueStore {
  Future<SharedPreferences> get _prefs => SharedPreferences.getInstance();

  @override
  Future<String?> get(String key) async => (await _prefs).getString(key);

  @override
  Future<void> set(String key, String? value) async {
    final prefs = await _prefs;
    if (value == null) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, value);
    }
  }
}

/// Minimal POST abstraction so the SDK is testable with a fake transport.
abstract class HttpPoster {
  /// Returns the response body + status code. Throws on transport failure.
  Future<MaaHttpResponse> post(Uri url, Map<String, String> headers, String body);
}

class MaaHttpResponse {
  const MaaHttpResponse(this.body, this.statusCode);
  final String body;
  final int statusCode;
}

/// Production transport — dart:io HttpClient, zero extra dependencies.
class IoHttpPoster implements HttpPoster {
  const IoHttpPoster({this.timeout = const Duration(seconds: 10)});
  final Duration timeout;

  @override
  Future<MaaHttpResponse> post(Uri url, Map<String, String> headers, String body) async {
    final client = HttpClient()..connectionTimeout = timeout;
    try {
      final request = await client.postUrl(url).timeout(timeout);
      request.headers.contentType = ContentType.json;
      headers.forEach(request.headers.set);
      request.write(body);
      final response = await request.close().timeout(timeout);
      final text = await response.transform(utf8.decoder).join().timeout(timeout);
      return MaaHttpResponse(text, response.statusCode);
    } finally {
      client.close(force: true);
    }
  }
}

/// Trimmed value, or null when absent/blank — a blank override means "unset".
String? _present(String? value) {
  final trimmed = value?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}

/// How the SDK finds its API key and host without either being typed into your
/// source code: the explicit argument first, then a `--dart-define`, then (for
/// the host) the compiled-in production default.
class MyAppAffiliateConfig {
  const MyAppAffiliateConfig._();

  static String? resolveApiKey(String? explicit) => _present(explicit) ?? _present(_envApiKey);

  static String resolveApiBaseUrl(String? explicit) =>
      _present(explicit) ?? _present(_envApiBaseUrl) ?? kDefaultApiBaseUrl;
}

/// The internal engine behind [MyAppAffiliate]. Holds config + storage +
/// transport. Tests drive [Client] directly with an in-memory store and a
/// fake HTTP poster.
class Client {
  Client({
    required this.apiKey,
    required String baseUrl,
    required this.store,
    required this.http,
    this.debug = false,
    int Function()? now,
  })  : baseUrl = baseUrl.endsWith('/')
            ? baseUrl.substring(0, baseUrl.length - 1)
            : baseUrl,
        now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final String apiKey;
  final String baseUrl;
  final KeyValueStore store;
  final HttpPoster http;
  final bool debug;
  final int Function() now;

  static const _deviceIdKey = 'maa.deviceId';
  static const _affiliateIdKey = 'maa.affiliateId';

  /// An attribution payload that hasn't reached the API yet. First launch is
  /// exactly when a device is most likely offline, so we keep it and retry.
  static const _pendingTokenKey = 'maa.pendingToken';
  static const _pendingCodeKey = 'maa.pendingCode';

  /// Set once the server-side deferred match has been attempted, so we ask for
  /// it once per install instead of on every launch.
  static const _deferredTriedKey = 'maa.deferredTried';

  /// Query params a referral can arrive under, most trusted first.
  static const _tokenParams = ['claim_token', 'ct'];
  static const _codeParams = ['via', 'ref', 'maa_code', 'code'];

  /// Extracts the deferred-deep-link claim token (`claim_token` | `ct`).
  static String? claimToken(Uri uri) => _firstParam(uri, _tokenParams);

  /// Extracts a referral code (`?via=LUMI`). Creators share plain `?via=` links
  /// as often as tracked ones, and an app that only looked for a claim token
  /// would silently drop every one of them.
  static String? referralCode(Uri uri) => _firstParam(uri, _codeParams);

  static String? _firstParam(Uri uri, List<String> names) {
    final params = uri.queryParameters;
    for (final name in names) {
      final value = params[name];
      if (value != null && value.isNotEmpty) return value;
    }
    return null;
  }

  void _log(String message) {
    // ignore: avoid_print
    if (debug) print('[myappaffiliate] $message');
  }

  /// Stable per-install device id, generated once and persisted.
  Future<String> deviceId() async {
    final existing = await store.get(_deviceIdKey);
    if (existing != null) return existing;
    final id = _uuidV4();
    await store.set(_deviceIdKey, id);
    return id;
  }

  Future<String?> attributedAffiliateId() => store.get(_affiliateIdKey);

  /// Runs at launch, before any link or code arrives. In order:
  ///   1. already attributed → nothing to do
  ///   2. a payload we failed to deliver earlier → retry it
  ///   3. otherwise → ask the API for a deferred match, once per install
  ///
  /// Step 3 is what makes a fresh store install attributable at all: the store
  /// drops the claim token, so the server matches on a hashed IP and a short
  /// time window instead (docs/30 Part 1).
  Future<bool> bootstrap() async {
    if (await attributedAffiliateId() != null) return false;

    final token = await store.get(_pendingTokenKey);
    if (token != null) return _postInstall(claimToken: token);

    final code = await store.get(_pendingCodeKey);
    if (code != null) return _postInstall(affiliateCode: code);

    if (await store.get(_deferredTriedKey) != null) return false;
    await store.set(_deferredTriedKey, '1');
    return _postInstall();
  }

  /// Records attribution from an incoming deep link.
  Future<bool> attribute(Uri uri) async {
    final token = claimToken(uri);
    if (token != null) {
      await store.set(_pendingTokenKey, token);
      return _postInstall(claimToken: token);
    }
    final code = referralCode(uri);
    if (code != null) return applyCode(code);
    _log('no referral in $uri');
    return false;
  }

  /// Manual-code fallback (e.g. a creator's "JESS20").
  Future<bool> applyCode(String code) async {
    await store.set(_pendingCodeKey, code);
    return _postInstall(affiliateCode: code);
  }

  /// Binds the app's user id to the stored attribution.
  Future<bool> identify(String userId) async {
    final body = jsonEncode({
      'deviceId': await deviceId(),
      'customerUserId': userId,
      'identifiedAt': now(),
    });
    try {
      final response = await http.post(_endpoint('sdk/identify'), _authHeaders(), body);
      return response.statusCode == 200;
    } catch (e) {
      _log('identify failed: $e');
      return false;
    }
  }

  /// Clears every piece of persisted state — after this the device is
  /// indistinguishable from a fresh install.
  Future<void> reset() async {
    for (final key in [
      _deviceIdKey,
      _affiliateIdKey,
      _pendingTokenKey,
      _pendingCodeKey,
      _deferredTriedKey,
    ]) {
      await store.set(key, null);
    }
  }

  Future<bool> _postInstall({String? claimToken, String? affiliateCode}) async {
    final body = jsonEncode({
      'deviceId': await deviceId(),
      if (claimToken != null) 'claimToken': claimToken,
      if (affiliateCode != null) 'affiliateCode': affiliateCode,
      'firstOpenAt': now(),
    });
    final MaaHttpResponse response;
    try {
      response = await http.post(_endpoint('sdk/install'), _authHeaders(), body);
    } catch (e) {
      _log('install failed: $e');
      return false;
    }

    // 404 = no attributable click; 409 = an ambiguous deferred match the server
    // refused to guess at. Both are final answers, not transient failures, so
    // drop the pending payload instead of retrying it on every launch.
    if (response.statusCode == 404 || response.statusCode == 409) {
      await _clearPending();
      return false;
    }
    if (response.statusCode != 200) return false;

    try {
      final parsed = jsonDecode(response.body);
      final affiliateId = parsed is Map<String, dynamic> ? parsed['affiliateId'] : null;
      if (affiliateId is String && affiliateId.isNotEmpty) {
        await store.set(_affiliateIdKey, affiliateId);
        _log('attributed to $affiliateId');
      }
    } catch (_) {
      // Response body is best-effort; the install itself succeeded.
    }
    await _clearPending();
    return true;
  }

  Future<void> _clearPending() async {
    await store.set(_pendingTokenKey, null);
    await store.set(_pendingCodeKey, null);
  }

  Uri _endpoint(String path) => Uri.parse('$baseUrl/$path');

  Map<String, String> _authHeaders() => {'Authorization': 'Bearer $apiKey'};

  static final math.Random _random = _newRandom();

  /// Random.secure when the platform has an entropy source; plain Random
  /// otherwise (the device id is an identifier, not a secret).
  static math.Random _newRandom() {
    try {
      return math.Random.secure();
    } catch (_) {
      return math.Random();
    }
  }

  static String _uuidV4() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    String hex(int start, int end) =>
        bytes.sublist(start, end).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    return '${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-${hex(8, 10)}-${hex(10, 16)}';
  }
}

/// The public surface an app integrates. All methods are static and delegate
/// to an internal [Client]; every call is safe before `start` (no-ops).
class MyAppAffiliate {
  MyAppAffiliate._();

  static Client? _client;

  /// True once [start] has run. Every other call is a safe no-op before it.
  static bool get isStarted => _client != null;

  /// Start the SDK. Call once at launch.
  ///
  /// Pass your key, or omit it and supply it at build time with
  /// `--dart-define=MYAPPAFFILIATE_API_KEY=pk_live_…`.
  ///
  /// [apiBaseUrl] points at a staging API or a self-hosted deployment; leave it
  /// null in production. [storage] and [http] are injectable for tests;
  /// production uses shared_preferences and dart:io.
  ///
  /// Returns false when no key could be found, which is the one
  /// misconfiguration worth checking: with no key nothing can ever attribute.
  static Future<bool> start({
    String? apiKey,
    String? apiBaseUrl,
    bool debug = false,
    KeyValueStore? storage,
    HttpPoster? http,
  }) async {
    final key = MyAppAffiliateConfig.resolveApiKey(apiKey);
    if (key == null) {
      // ignore: avoid_print
      print(
        '[myappaffiliate] no API key — pass one to MyAppAffiliate.start(apiKey:) or build with '
        '--dart-define=MYAPPAFFILIATE_API_KEY=… . The SDK is inactive.',
      );
      return false;
    }
    final client = Client(
      apiKey: key,
      baseUrl: MyAppAffiliateConfig.resolveApiBaseUrl(apiBaseUrl),
      store: storage ?? SharedPreferencesStore(),
      http: http ?? const IoHttpPoster(),
      debug: debug,
    );
    _client = client;
    await client.bootstrap();
    return true;
  }

  /// Bind your user id to the attribution — call once you know the user.
  ///
  /// This id is the join key for every revenue event that follows, whoever bills
  /// the customer: it must be the same string your billing provider reports back
  /// to us (RevenueCat / Adapty / Superwall app user id, Stripe
  /// `metadata.customer_user_id`, Paddle custom data).
  static Future<bool> identify(String userId) async =>
      (await _client?.identify(userId)) ?? false;

  /// Claim the referral carried by an incoming deep link — a `claim_token`/`ct`
  /// from a tracked link, or a `via`/`ref`/`code` param.
  static Future<bool> attribute(Uri uri) async => (await _client?.attribute(uri)) ?? false;

  /// Manual-code entry (e.g. a "Got a creator code?" field). Works with no
  /// deep-link setup at all.
  static Future<bool> applyCode(String code) async => (await _client?.applyCode(code)) ?? false;

  /// The affiliate id this install was attributed to, if any. You do not need
  /// this for attribution to work — it is here for your own UI and analytics.
  static Future<String?> attributedAffiliateId() async =>
      await _client?.attributedAffiliateId();

  /// Clear all persisted SDK state — call on logout or a data-erasure request.
  ///
  /// The SDK stays started: the next launch (or the next link) attributes again
  /// from scratch, exactly as a fresh install would.
  static Future<void> reset() async => await _client?.reset();

  /// Test hook — reset configuration between tests.
  static void resetForTesting() => _client = null;
}
