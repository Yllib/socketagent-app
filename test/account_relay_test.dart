import 'dart:convert';
import 'dart:io';

import 'package:app/models/server_config.dart';
import 'package:app/services/chat_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pinenacl/x25519.dart';

import 'support/fake_computers.dart';

/// Where the app's own account requests go (wire spec 14): the built-in
/// relay, whatever relay a computer is stored on. A relay the user runs is
/// asked about the subscription or an access code only after the built-in
/// relay has said no. Every request here is answered by a mock client.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const builtIn = 'relay.jarofdirt.info';
  const own = 'relay.own.example';
  late List<http.Request> requests;
  // What each relay answers. Null stands for a relay that cannot be reached.
  late http.Response? Function(http.Request request) builtInAnswers;
  late http.Response? Function(http.Request request) ownAnswers;

  http.Response json(Map<String, Object?> body, [int status = 200]) =>
      http.Response(jsonEncode(body), status);

  setUp(() {
    mockProviderChannels();
    requests = [];
    builtInAnswers = (_) => json({'active': true, 'provider': 'google_play'});
    ownAnswers = (_) => json({'active': false});
  });
  tearDown(unmockProviderChannels);

  /// Runs [body] with a provider that has one computer on the user's own
  /// relay and a subscriber token.
  Future<void> withProvider(Future<void> Function(ChatProvider) body) =>
      http.runWithClient(
        () async {
          final provider = ChatProvider();
          await provider.settingsReady;
          try {
            await provider.addServer(
              ServerConfig(
                id: 'own',
                name: 'On my relay',
                host: '',
                port: 8085,
                token: '',
                useRelay: true,
                relayUrl: 'wss://$own',
                pairingToken: 'room',
                serverPubkey: base64Encode(
                  PrivateKey.generate().publicKey.asTypedList,
                ),
              ),
            );
            await provider.saveSubscriberToken('subscriber-token');
            requests.clear();
            await body(provider);
          } finally {
            provider.dispose();
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
        },
        () => MockClient((request) async {
          requests.add(request);
          final answer = request.url.host == builtIn
              ? builtInAnswers(request)
              : ownAnswers(request);
          if (answer == null) throw const SocketException('unreachable');
          return answer;
        }),
      );

  List<String> hosts() => [for (final request in requests) request.url.host];

  test('account requests go to the built-in relay and no other', () async {
    await withProvider((provider) async {
      expect(await provider.checkSubscriptionStatus(), isTrue);
      await provider.getDirectBillingPortalUrl();
      await provider.createDirectCheckoutSession('someone@example.com');
      await provider.verifyDirectCheckoutSession('session');
      await provider.verifyGooglePlayPurchase('purchase', 'product');
      await provider.requestPlayReviewAccess('review-code');

      expect(requests, hasLength(6));
      expect(hosts(), everyElement(builtIn));
      expect(requests.map((r) => r.url.scheme), everyElement('https'));
      expect(provider.relayHttpUrl, 'https://$builtIn');
    });
  });

  test('the built-in relay gets the token in a header, not the URL', () async {
    await withProvider((provider) async {
      expect(await provider.checkSubscriptionStatus(), isTrue);

      final request = requests.single;
      expect(request.method, 'GET');
      expect(
        request.url.toString(),
        'https://$builtIn/api/subscription-status',
      );
      expect(request.headers['Authorization'], 'Bearer subscriber-token');
    });
  });

  test('the subscription check asks another relay only after a no', () async {
    await withProvider((provider) async {
      // A token the user's own relay issued.
      builtInAnswers = (_) => json({'active': false});
      ownAnswers = (_) => json({'active': true, 'provider': 'owner'});
      expect(await provider.checkSubscriptionStatus(), isTrue);
      expect(hosts(), [builtIn, own]);
      expect(provider.subscriptionProvider, 'owner');
      // That relay may be an older build, so it gets the query form.
      expect(requests.first.url.query, isEmpty);
      expect(requests.last.url.queryParameters, {'token': 'subscriber-token'});
      expect(requests.last.headers, isNot(contains('Authorization')));

      // Neither relay knows the token.
      requests.clear();
      ownAnswers = (_) => json({'active': false});
      expect(await provider.checkSubscriptionStatus(), isFalse);
      expect(hosts(), [builtIn, own]);
      expect(provider.hasCachedRelayAccess, isFalse);

      // The built-in relay gave no answer, so nothing else is asked.
      requests.clear();
      builtInAnswers = (_) => null;
      await provider.checkSubscriptionStatus();
      expect(hosts(), [builtIn]);
    });
  });

  group('a join turned away for lack of a subscription', () {
    late HttpServer relay;
    late int refusals;

    setUp(() async {
      refusals = 0;
      // A relay, or a room's computer writing the relay's signal.
      relay = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      relay.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((_) {});
        refusals++;
        socket.add(jsonEncode({'type': 'subscription_required'}));
      });
    });
    tearDown(() => relay.close(force: true));

    /// Joins a room on [relay] and reports how often the app was told its
    /// subscription is needed.
    Future<int> join(ChatProvider provider) async {
      var told = 0;
      provider.onSubscriptionRequired.listen((_) => told++);
      await provider.addServer(
        ServerConfig(
          id: 'refused',
          name: 'Refused',
          host: '',
          port: 8085,
          token: '',
          useRelay: true,
          relayUrl: 'ws://127.0.0.1:${relay.port}',
          pairingToken: 'room',
          serverPubkey: base64Encode(
            PrivateKey.generate().publicKey.asTypedList,
          ),
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(refusals, 1);
      return told;
    }

    test('does not mark a subscription the relay calls active', () async {
      await withProvider((provider) async {
        expect(await join(provider), 0);
        expect(hosts(), [builtIn]);
        expect(provider.subscriptionActive, isTrue);
        expect(provider.hasCachedRelayAccess, isTrue);
      });
    });

    test('shows a subscription the relay calls lapsed as lapsed', () async {
      builtInAnswers = (_) => json({'active': false, 'status': 'expired'});
      await withProvider((provider) async {
        expect(await join(provider), 1);
        expect(provider.subscriptionActive, isFalse);
        expect(provider.hasCachedRelayAccess, isFalse);
      });
    });
  });

  test('an access code goes to another relay only after a no', () async {
    await withProvider((provider) async {
      Map<String, dynamic> sent(http.Request request) =>
          jsonDecode(request.body) as Map<String, dynamic>;

      // The built-in relay takes it.
      builtInAnswers = (_) => json({'token': 'built-in-token', 'active': true});
      expect(await provider.requestAccessCode('code'), isNull);
      expect(hosts(), [builtIn]);
      expect(provider.subscriberToken, 'built-in-token');

      // The built-in relay could not be reached to judge it.
      requests.clear();
      builtInAnswers = (_) => null;
      expect(await provider.requestAccessCode('code'), isNotNull);
      expect(hosts(), [builtIn]);

      // The built-in relay says it is not one of its own.
      requests.clear();
      builtInAnswers = (_) => json({'error': 'no'}, 403);
      ownAnswers = (_) => json({'token': 'own-token', 'active': true});
      expect(await provider.requestAccessCode('own-code'), isNull);
      expect(hosts(), [builtIn, own]);
      expect(sent(requests.last), {'code': 'own-code'});
      expect(provider.subscriberToken, 'own-token');

      // Nobody takes it.
      requests.clear();
      ownAnswers = (_) => json({'error': 'no'}, 403);
      expect(
        await provider.requestAccessCode('wrong'),
        'That access code is not valid.',
      );
    });
  });
}
