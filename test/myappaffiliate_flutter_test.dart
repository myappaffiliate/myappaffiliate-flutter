import 'package:flutter_test/flutter_test.dart';
import 'package:myappaffiliate_flutter/myappaffiliate_flutter.dart';

/// Records requests and returns a canned response per URL.
class FakeHttp implements HttpPoster {
  FakeHttp(this.responder);
  final MaaHttpResponse Function(Uri url) responder;
  final List<({Uri url, Map<String, String> headers, String body})> requests = [];

  @override
  Future<MaaHttpResponse> post(Uri url, Map<String, String> headers, String body) async {
    requests.add((url: url, headers: headers, body: body));
    return responder(url);
  }
}

class ThrowingHttp implements HttpPoster {
  @override
  Future<MaaHttpResponse> post(Uri url, Map<String, String> headers, String body) async {
    throw Exception('network down');
  }
}

Client makeClient(HttpPoster http, {KeyValueStore? store, String baseUrl = 'https://api.test'}) =>
    Client(
      apiKey: 'pk_test',
      baseUrl: baseUrl,
      store: store ?? InMemoryStore(),
      http: http,
      now: () => 1000000,
    );

void main() {
  test('deviceId is stable and persisted', () async {
    final store = InMemoryStore();
    final client = makeClient(FakeHttp((_) => const MaaHttpResponse('', 200)), store: store);
    final first = await client.deviceId();
    expect(await client.deviceId(), first);
    expect(await store.get('maa.deviceId'), isNotNull);
    // uuid v4 shape
    expect(first, matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-')));
  });

  test('claim token parsing', () {
    expect(Client.claimToken(Uri.parse('https://go.x/jess?claim_token=abc123')), 'abc123');
    expect(Client.claimToken(Uri.parse('https://go.x/jess?utm_source=ig&ct=xyz')), 'xyz');
    expect(Client.claimToken(Uri.parse('https://go.x/jess')), isNull);
    expect(Client.claimToken(Uri.parse('https://go.x/jess?ct=')), isNull);
  });

  test('referral code parsing, with the claim token always preferred', () {
    expect(Client.referralCode(Uri.parse('https://app.x/?via=LUMI')), 'LUMI');
    expect(Client.referralCode(Uri.parse('https://app.x/?ref=LUMI&utm_source=yt')), 'LUMI');
    expect(Client.referralCode(Uri.parse('https://app.x/?maa_code=JESS20')), 'JESS20');
    expect(Client.referralCode(Uri.parse('https://app.x/?utm_source=yt')), isNull);
    expect(Client.claimToken(Uri.parse('https://app.x/?via=LUMI&ct=tok_1')), 'tok_1');
  });

  test('base url keeps exactly one slash before the path', () async {
    final http = FakeHttp((_) => const MaaHttpResponse('{}', 200));
    final client = makeClient(http, baseUrl: 'https://api.test/');
    await client.identify('user_1');
    expect(http.requests.first.url.toString(), 'https://api.test/sdk/identify');
  });

  test('attribute stores affiliateId and posts install', () async {
    final http = FakeHttp(
        (_) => const MaaHttpResponse('{"attributionId":"at_1","affiliateId":"aff_1"}', 200));
    final client = makeClient(http);
    final ok = await client.attribute(Uri.parse('https://go.x/jess?claim_token=abc'));
    expect(ok, isTrue);
    expect(await client.attributedAffiliateId(), 'aff_1');
    expect(http.requests, hasLength(1));
    expect(http.requests.first.url.path, endsWith('/sdk/install'));
    expect(http.requests.first.headers['Authorization'], 'Bearer pk_test');
    expect(http.requests.first.body, contains('abc'));
    expect(http.requests.first.body, contains('"deviceId"'));
    expect(http.requests.first.body, contains('"firstOpenAt":1000000'));
  });

  /// Creators share plain `?via=` links at least as often as tracked ones.
  test('attribute falls back to a referral code in the link', () async {
    final http = FakeHttp((_) => const MaaHttpResponse('{"affiliateId":"aff_via"}', 200));
    final client = makeClient(http);
    expect(await client.attribute(Uri.parse('https://app.x/?via=LUMI&utm_source=yt')), isTrue);
    expect(await client.attributedAffiliateId(), 'aff_via');
    expect(http.requests.first.body, contains('LUMI'));
  });

  test('attribute without any referral does nothing', () async {
    final http = FakeHttp((_) => const MaaHttpResponse('', 200));
    final client = makeClient(http);
    expect(await client.attribute(Uri.parse('https://go.x/jess?utm_source=x')), isFalse);
    expect(http.requests, isEmpty);
  });

  test('applyCode posts affiliateCode', () async {
    final http = FakeHttp((_) => const MaaHttpResponse('{"affiliateId":"aff_2"}', 200));
    final client = makeClient(http);
    expect(await client.applyCode('JESS20'), isTrue);
    expect(await client.attributedAffiliateId(), 'aff_2');
    expect(http.requests.first.body, contains('JESS20'));
  });

  test('identify posts user', () async {
    final http = FakeHttp((_) => const MaaHttpResponse('{}', 200));
    final client = makeClient(http);
    expect(await client.identify('user_9'), isTrue);
    expect(http.requests.first.url.path, endsWith('/sdk/identify'));
    expect(http.requests.first.body, contains('user_9'));
    expect(http.requests.first.body, contains('"identifiedAt":1000000'));
  });

  test('non-200 returns false and stores nothing', () async {
    final http = FakeHttp((_) => const MaaHttpResponse('', 404));
    final client = makeClient(http);
    expect(await client.identify('x'), isFalse);
    expect(await client.applyCode('NOPE'), isFalse);
    expect(await client.attributedAffiliateId(), isNull);
  });

  test('transport failure is silent', () async {
    final client = makeClient(ThrowingHttp());
    expect(await client.applyCode('JESS20'), isFalse);
    expect(await client.identify('user_1'), isFalse);
    expect(await client.attribute(Uri.parse('https://go.x/j?ct=abc')), isFalse);
    expect(await client.attributedAffiliateId(), isNull);
  });

  group('bootstrap — deferred attribution and retry', () {
    /// A fresh store install: the store dropped the claim token, so the SDK
    /// posts an install with neither token nor code and the server matches on
    /// its side. This is the path that makes link-driven installs attributable.
    test('asks for a deferred match on a fresh install', () async {
      final http = FakeHttp(
          (_) => const MaaHttpResponse('{"affiliateId":"aff_9","matchMethod":"deferred_ip"}', 200));
      final client = makeClient(http);
      expect(await client.bootstrap(), isTrue);
      expect(await client.attributedAffiliateId(), 'aff_9');
      expect(http.requests.first.body, isNot(contains('claimToken')));
      expect(http.requests.first.body, isNot(contains('affiliateCode')));
    });

    test('does nothing when already attributed', () async {
      final store = InMemoryStore();
      await store.set('maa.affiliateId', 'aff_existing');
      final http = FakeHttp((_) => const MaaHttpResponse('', 200));
      expect(await makeClient(http, store: store).bootstrap(), isFalse);
      expect(http.requests, isEmpty);
    });

    /// The deferred ask costs a round trip and can only ever succeed once, so
    /// it must not fire on every cold launch.
    test('attempts the deferred match only once per install', () async {
      final store = InMemoryStore();
      final http = FakeHttp((_) => const MaaHttpResponse('{}', 404));
      await makeClient(http, store: store).bootstrap();
      await makeClient(http, store: store).bootstrap();
      await makeClient(http, store: store).bootstrap();
      expect(http.requests, hasLength(1));
    });

    /// First launch is when a device is most likely offline. Losing the code
    /// there would lose the creator their commission permanently.
    test('retries a code the previous launch failed to deliver', () async {
      final store = InMemoryStore();
      var online = false;
      final http = FakeHttp((_) => online
          ? const MaaHttpResponse('{"affiliateId":"aff_2"}', 200)
          : const MaaHttpResponse('', 500));

      expect(await makeClient(http, store: store).applyCode('JESS20'), isFalse);

      online = true;
      final nextLaunch = makeClient(http, store: store);
      expect(await nextLaunch.bootstrap(), isTrue);
      expect(await nextLaunch.attributedAffiliateId(), 'aff_2');
      expect(http.requests[1].body, contains('JESS20'));
    });

    test('retries a link token the previous launch failed to deliver', () async {
      final store = InMemoryStore();
      var online = false;
      final http = FakeHttp((_) => online
          ? const MaaHttpResponse('{"affiliateId":"aff_3"}', 200)
          : const MaaHttpResponse('', 500));

      await makeClient(http, store: store).attribute(Uri.parse('https://go.x/j?claim_token=tok1'));

      online = true;
      final nextLaunch = makeClient(http, store: store);
      expect(await nextLaunch.bootstrap(), isTrue);
      expect(await nextLaunch.attributedAffiliateId(), 'aff_3');
      expect(http.requests[1].body, contains('tok1'));
    });

    /// 404 (no click) and 409 (ambiguous — the server refused to guess) are
    /// final answers. Retrying them forever would hammer the API for nothing.
    test('final rejections clear the pending payload', () async {
      for (final status in [404, 409]) {
        final store = InMemoryStore();
        final http = FakeHttp((_) => MaaHttpResponse('', status));
        await makeClient(http, store: store).applyCode('NOPE');
        expect(await store.get('maa.pendingCode'), isNull, reason: 'status $status');

        await makeClient(http, store: store).bootstrap();
        expect(http.requests, hasLength(2), reason: 'status $status: must not retry');
      }
    });
  });

  test('reset clears every persisted key', () async {
    final store = InMemoryStore();
    final http = FakeHttp((_) => const MaaHttpResponse('{"affiliateId":"aff_1"}', 200));
    final client = makeClient(http, store: store);
    await client.applyCode('JESS20');
    expect(await client.attributedAffiliateId(), isNotNull);

    await client.reset();
    for (final key in [
      'maa.deviceId',
      'maa.affiliateId',
      'maa.pendingToken',
      'maa.pendingCode',
      'maa.deferredTried',
    ]) {
      expect(await store.get(key), isNull, reason: key);
    }
  });

  group('zero-config', () {
    test('the host defaults to production when nothing overrides it', () {
      expect(MyAppAffiliateConfig.resolveApiBaseUrl(null), kDefaultApiBaseUrl);
      expect(kDefaultApiBaseUrl, 'https://api.myappaffiliate.com');
    });

    test('an explicit host wins, and a blank one falls through', () {
      expect(MyAppAffiliateConfig.resolveApiBaseUrl('https://staging.test'), 'https://staging.test');
      expect(MyAppAffiliateConfig.resolveApiBaseUrl('   '), kDefaultApiBaseUrl);
    });

    test('an explicit key wins, and a blank one resolves to null', () {
      expect(MyAppAffiliateConfig.resolveApiKey('pk_live_1'), 'pk_live_1');
      expect(MyAppAffiliateConfig.resolveApiKey('  '), isNull);
      // No --dart-define in the test run, so there is nothing to fall back to.
      expect(MyAppAffiliateConfig.resolveApiKey(null), isNull);
    });

    /// Without a key nothing can attribute, so start() must report the failure
    /// rather than leaving a half-configured SDK behind.
    test('start without any key reports failure and stays inactive', () async {
      MyAppAffiliate.resetForTesting();
      expect(await MyAppAffiliate.start(apiKey: ''), isFalse);
      expect(MyAppAffiliate.isStarted, isFalse);
    });
  });

  test('static facade is a safe no-op before start', () async {
    MyAppAffiliate.resetForTesting();
    expect(await MyAppAffiliate.applyCode('JESS20'), isFalse);
    expect(await MyAppAffiliate.identify('u'), isFalse);
    expect(await MyAppAffiliate.attributedAffiliateId(), isNull);
  });

  test('static facade delegates with injected fakes', () async {
    MyAppAffiliate.resetForTesting();
    final http = FakeHttp((_) => const MaaHttpResponse('{"affiliateId":"aff_9"}', 200));
    final started = await MyAppAffiliate.start(
      apiKey: 'pk_test',
      apiBaseUrl: 'https://api.test',
      storage: InMemoryStore(),
      http: http,
    );
    expect(started, isTrue);
    expect(MyAppAffiliate.isStarted, isTrue);
    // start() alone attributed this install via the deferred match.
    expect(await MyAppAffiliate.attributedAffiliateId(), 'aff_9');
    expect(await MyAppAffiliate.applyCode('JESS20'), isTrue);
    MyAppAffiliate.resetForTesting();
  });
}
