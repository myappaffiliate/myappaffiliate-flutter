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

Client makeClient(HttpPoster http, {KeyValueStore? store}) => Client(
      apiKey: 'pk_test',
      baseUrl: 'https://api.test',
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

  test('attribute stores affiliateId and posts install', () async {
    final http =
        FakeHttp((_) => const MaaHttpResponse('{"attributionId":"at_1","affiliateId":"aff_1"}', 200));
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

  test('attribute without claim token does nothing', () async {
    final http = FakeHttp((_) => const MaaHttpResponse('', 200));
    final client = makeClient(http);
    expect(await client.attribute(Uri.parse('https://go.x/jess')), isFalse);
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

  test('static facade is a safe no-op before configure', () async {
    MyAppAffiliate.resetForTesting();
    expect(await MyAppAffiliate.applyCode('JESS20'), isFalse);
    expect(await MyAppAffiliate.identify('u'), isFalse);
    expect(await MyAppAffiliate.attributedAffiliateId(), isNull);
  });

  test('static facade delegates with injected fakes', () async {
    final http = FakeHttp((_) => const MaaHttpResponse('{"affiliateId":"aff_9"}', 200));
    MyAppAffiliate.configure(
      apiKey: 'pk_test',
      baseUrl: 'https://api.test',
      storage: InMemoryStore(),
      http: http,
    );
    expect(await MyAppAffiliate.applyCode('JESS20'), isTrue);
    expect(await MyAppAffiliate.attributedAffiliateId(), 'aff_9');
    MyAppAffiliate.resetForTesting();
  });
}
