/// MyAppAffiliate Flutter SDK — first-party, deterministic affiliate attribution.
///
/// ```dart
/// MyAppAffiliate.configure(
///   apiKey: 'pk_live_…',
///   baseUrl: 'https://api.myappaffiliate.com',
/// );
/// // incoming deep link:
/// await MyAppAffiliate.attribute(uri);
/// // manual-code fallback:
/// await MyAppAffiliate.applyCode('JESS20');
/// // when you know the user:
/// await MyAppAffiliate.identify(userId);
/// // before a purchase (e.g. purchases_flutter):
/// final affiliateId = await MyAppAffiliate.attributedAffiliateId();
/// ```
///
/// Every network path is silent-safe: failures resolve to `false`/`null` and
/// never throw into the host app.
library myappaffiliate_flutter;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

/// Tiny key/value store the SDK uses to persist the device id and the
/// attributed affiliate id. Abstracted so the engine is testable without
/// SharedPreferences.
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

/// The internal engine behind [MyAppAffiliate]. Holds config + storage +
/// transport. Tests drive [Client] directly with an in-memory store and a
/// fake HTTP poster.
class Client {
  Client({
    required this.apiKey,
    required this.baseUrl,
    required this.store,
    required this.http,
    int Function()? now,
  }) : now = now ?? (() => DateTime.now().millisecondsSinceEpoch);

  final String apiKey;
  final String baseUrl;
  final KeyValueStore store;
  final HttpPoster http;
  final int Function() now;

  static const _deviceIdKey = 'maa.deviceId';
  static const _affiliateIdKey = 'maa.affiliateId';

  /// Extracts the deferred-deep-link claim token (`claim_token` | `ct`).
  static String? claimToken(Uri uri) {
    final params = uri.queryParameters;
    final token = params['claim_token'] ?? params['ct'];
    return (token == null || token.isEmpty) ? null : token;
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

  /// Records attribution from an incoming deep link.
  Future<bool> attribute(Uri uri) async {
    final token = claimToken(uri);
    if (token == null) return false;
    return _postInstall(claimToken: token);
  }

  /// Manual-code fallback (e.g. a creator's "JESS20").
  Future<bool> applyCode(String code) => _postInstall(affiliateCode: code);

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
    } catch (_) {
      return false;
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
    } catch (_) {
      return false;
    }
    if (response.statusCode != 200) return false;
    try {
      final parsed = jsonDecode(response.body);
      final affiliateId = parsed is Map<String, dynamic> ? parsed['affiliateId'] : null;
      if (affiliateId is String && affiliateId.isNotEmpty) {
        await store.set(_affiliateIdKey, affiliateId);
      }
    } catch (_) {
      // Response body is best-effort; the install itself succeeded.
    }
    return true;
  }

  Uri _endpoint(String path) {
    final base = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
    return Uri.parse('$base/$path');
  }

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
/// to an internal [Client]; every call is safe before `configure` (no-ops).
class MyAppAffiliate {
  MyAppAffiliate._();

  static Client? _client;

  /// Initialize the SDK. Call once at launch.
  ///
  /// [storage] and [http] are injectable for tests; production uses
  /// shared_preferences and dart:io.
  static void configure({
    required String apiKey,
    required String baseUrl,
    KeyValueStore? storage,
    HttpPoster? http,
  }) {
    _client = Client(
      apiKey: apiKey,
      baseUrl: baseUrl,
      store: storage ?? SharedPreferencesStore(),
      http: http ?? const IoHttpPoster(),
    );
  }

  /// Handle an incoming deep link; records attribution (`claim_token` | `ct`).
  static Future<bool> attribute(Uri uri) async => (await _client?.attribute(uri)) ?? false;

  /// Manual-code fallback (e.g. a creator's "JESS20") when no link is available.
  static Future<bool> applyCode(String code) async => (await _client?.applyCode(code)) ?? false;

  /// Bind the app's user id to the stored attribution (call once you know the user).
  static Future<bool> identify(String userId) async =>
      (await _client?.identify(userId)) ?? false;

  /// The affiliate id this install was attributed to, if any.
  static Future<String?> attributedAffiliateId() async =>
      await _client?.attributedAffiliateId();

  /// Test hook — reset configuration between tests.
  static void resetForTesting() => _client = null;
}
