import 'package:flutter_test/flutter_test.dart';
import 'package:yams_hub/core/api/api_exception.dart';
import 'package:yams_hub/core/servers/server_resolver.dart';
import 'package:yams_models/yams_models.dart';

import '../support/builders.dart';

/// Per-URL fake: answers as the hub (with a proof from [proofKey]), as an
/// impostor, slowly, or not at all.
class _FakePing implements ServerPingClient {
  final behaviours = <Uri, Future<ServerPing> Function(String? nonce)>{};
  final calls = <({Uri url, String? nonce, String? sid})>[];

  void hub(Uri url, {String proofKey = testProofKey, String instanceId = testInstanceId, Duration delay = Duration.zero}) =>
      behaviours[url] = (nonce) async {
        if (delay > Duration.zero) await Future<void>.delayed(delay);
        return buildPing(nonce: nonce, proofKey: proofKey, instanceId: instanceId);
      };

  void noProof(Uri url) => behaviours[url] = (nonce) async => buildPing(proofKey: null);

  void down(Uri url) => behaviours[url] = (_) async => throw const ApiException.network();

  @override
  Future<ServerPing> ping(Uri base, {String? nonce, String? sessionId, Duration? timeout}) {
    calls.add((url: base, nonce: nonce, sid: sessionId));
    final b = behaviours[base];
    if (b == null) return Future.error(const ApiException.network());
    return b(nonce);
  }
}

void main() {
  const proof = ProofCredentials(sessionId: testSessionId, serverProofKey: testProofKey);
  late _FakePing client;
  late ServerResolver resolver;

  setUp(() {
    client = _FakePing();
    resolver = ServerResolver(client: client, stagger: const Duration(milliseconds: 20));
  });

  group('candidate order', () {
    final profile = buildProfile(lastGoodUrl: testLanUrl);

    test('last good URL first, then the profile order', () {
      expect(ServerResolver.candidateOrder(profile, preferTailscale: false), [testLanUrl, testTailscaleUrl]);
    });

    test('Tailscale first while the network is not verified as home', () {
      expect(ServerResolver.candidateOrder(profile, preferTailscale: true), [testTailscaleUrl, testLanUrl]);
    });

    test('100.64.0.0/10 counts as Tailscale', () {
      final p = buildProfile(urls: [testLanUrl, Uri.parse('http://100.101.102.103:8090')]);
      expect(ServerResolver.candidateOrder(p, preferTailscale: true).first.host, '100.101.102.103');
    });
  });

  test('LAN URL with a valid proof wins and is marked verified', () async {
    client
      ..hub(testLanUrl)
      ..hub(testTailscaleUrl, delay: const Duration(milliseconds: 200));
    final r = await resolver.resolve(buildProfile(), proof: proof, homeVerified: true);
    expect(r.url, testLanUrl);
    expect(r.proofVerified, isTrue);
    final lanCall = client.calls.firstWhere((c) => c.url == testLanUrl);
    expect(lanCall.sid, testSessionId);
    expect(lanCall.nonce, hasLength(24));
  });

  test('an impostor with the right instance id but a wrong proof is unreachable', () async {
    client
      ..hub(testLanUrl, proofKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')
      ..down(testTailscaleUrl);
    final r = await resolver.resolve(buildProfile(), proof: proof, homeVerified: true);
    expect(r.ok, isFalse);
    expect(r.failures[testLanUrl], 'Server proof failed.');
  });

  test('a missing proof is unreachable; a Tailscale URL with a valid proof wins', () async {
    client
      ..noProof(testLanUrl)
      ..hub(testTailscaleUrl, delay: const Duration(milliseconds: 50));
    final r = await resolver.resolve(buildProfile(), proof: proof, homeVerified: true);
    expect(r.url, testTailscaleUrl);
    expect(r.proofVerified, isTrue);
    final tsCall = client.calls.firstWhere((c) => c.url == testTailscaleUrl);
    expect(tsCall.sid, testSessionId, reason: 'Tailscale URLs are proven like any other');
    expect(tsCall.nonce, hasLength(24));
  });

  test('signed in: a *.ts.net impostor without the proof is never accepted', () async {
    // Tailscale off, café DNS answers the MagicDNS name: the public ping
    // fields (name, instance id) match, the proof does not.
    client
      ..noProof(testTailscaleUrl)
      ..down(testLanUrl);
    final r = await resolver.resolve(buildProfile(), proof: proof);
    expect(r.ok, isFalse);
    expect(r.failures[testTailscaleUrl], 'Server proof failed.');
  });

  test('signed in: a *.ts.net impostor with a wrong proof is never accepted', () async {
    client
      ..hub(testTailscaleUrl, proofKey: 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA')
      ..down(testLanUrl);
    final r = await resolver.resolve(buildProfile(), proof: proof);
    expect(r.ok, isFalse);
    expect(r.failures[testTailscaleUrl], 'Server proof failed.');
  });

  test('signed in: a 100.64.0.0/10 address needs the proof too', () async {
    final cgnat = Uri.parse('http://100.101.102.103:8090');
    client
      ..noProof(cgnat)
      ..down(testLanUrl);
    final r = await resolver.resolve(buildProfile(urls: [testLanUrl, cgnat]), proof: proof);
    expect(r.ok, isFalse);
    expect(r.failures[cgnat], 'Server proof failed.');
    expect(client.calls.firstWhere((c) => c.url == cgnat).sid, testSessionId);

    client
      ..calls.clear()
      ..hub(cgnat);
    final ok = await resolver.resolve(buildProfile(urls: [testLanUrl, cgnat]), proof: proof);
    expect(ok.url, cgnat);
    expect(ok.proofVerified, isTrue);
  });

  test('a different instance id is rejected', () async {
    client
      ..hub(testLanUrl, instanceId: 'someone-else')
      ..down(testTailscaleUrl);
    final r = await resolver.resolve(buildProfile(), proof: proof);
    expect(r.ok, isFalse);
    expect(r.failures[testLanUrl], 'A different hub answered.');
  });

  test('before login no proof is needed and no nonce is sent', () async {
    client
      ..hub(testLanUrl)
      ..down(testTailscaleUrl);
    final r = await resolver.resolve(buildProfile());
    expect(r.url, testLanUrl);
    expect(r.proofVerified, isFalse);
    expect(client.calls.every((c) => c.nonce == null && c.sid == null), isTrue);
  });

  test('before login a Tailscale URL is accepted without a proof', () async {
    client
      ..noProof(testTailscaleUrl)
      ..down(testLanUrl);
    final r = await resolver.resolve(buildProfile());
    expect(r.url, testTailscaleUrl);
    expect(r.proofVerified, isFalse);
  });

  test('happy eyeballs: the first acceptable answer wins, not the first URL', () async {
    client
      ..hub(testTailscaleUrl, delay: const Duration(milliseconds: 300))
      ..hub(testLanUrl);
    // Unverified network: Tailscale starts first, but the LAN answers first.
    final r = await resolver.resolve(buildProfile(), proof: proof);
    expect(r.url, testLanUrl);
    expect(client.calls.first.url, testTailscaleUrl);
  });

  test('URLs that are not needed are never started', () async {
    client.hub(testLanUrl);
    resolver = ServerResolver(client: client, stagger: const Duration(milliseconds: 200));
    final r = await resolver.resolve(buildProfile(lastGoodUrl: testLanUrl), homeVerified: true);
    expect(r.url, testLanUrl);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(client.calls.map((c) => c.url), [testLanUrl]);
  });

  test('nothing answers: failure lists every URL', () async {
    client
      ..down(testLanUrl)
      ..down(testTailscaleUrl);
    final r = await resolver.resolve(buildProfile());
    expect(r.ok, isFalse);
    expect(r.failures.keys, unorderedEquals([testLanUrl, testTailscaleUrl]));
  });

  test('a profile without URLs fails immediately', () async {
    final r = await resolver.resolve(buildProfile(urls: []));
    expect(r.ok, isFalse);
    expect(client.calls, isEmpty);
  });
}
