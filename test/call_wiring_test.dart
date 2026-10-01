// The wires a widget test cannot see.
//
// Every screen test builds its own small app around the page it tests, so
// none of them goes through main.dart. Deleting the lines there that make
// calls work — the call service on the live connection, the host that puts
// the call screen up, the navigator it uses — would leave every one of them
// green. These read main.dart itself, comments stripped first, so a comment
// describing the wiring cannot stand in for it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:myapp/services/api_service.dart';

import 'support/dart_source.dart';

String _code(String path) => File(path)
    .readAsLinesSync()
    .where((l) => !l.trimLeft().startsWith('//'))
    .join('\n');

void main() {
  test('main.dart puts calls on the live connection and the screen on top',
      () {
    final main = _code('lib/main.dart');
    final wrapper = bodyOf(main, 'class _WebSocketWrapperState');
    for (final wire in [
      'CallService(',
      'events: _ws.events',
      'send: _ws.send',
      'media: WebRtcCallMedia.new',
      'iceServers: ApiService.getIceServers',
      'CallHost(',
      'navigator: MyApp.navigatorKey',
      'ChangeNotifierProvider<CallService>.value(value: _calls)',
    ]) {
      expect(wrapper, contains(wire), reason: 'main.dart lost: $wire');
    }
    expect(main, contains('navigatorKey: MyApp.navigatorKey'),
        reason: 'the app\'s navigator is not the one the call screen uses');
  });

  group('where calls find their way', () {
    tearDown(() => ApiService.useClient(http.Client()));

    test('the server\'s list, relay included', () async {
      ApiService.useClient(MockClient((req) async {
        expect(req.url.path, '/api/v1/calls/ice');
        return http.Response(
          json.encode({
            'iceServers': [
              {
                'urls': ['stun:a'],
              },
              {
                'urls': ['turn:b'],
                'username': 'u',
                'credential': 'p',
              },
            ],
            'relay': true,
          }),
          200,
        );
      }));
      final got = await ApiService.getIceServers();
      expect(got.servers, hasLength(2));
      expect(got.servers[1]['credential'], 'p');
      expect(got.relay, isTrue);
    });

    test('the server unreachable: the public address-finder still', () async {
      ApiService.useClient(
          MockClient((_) async => http.Response('down', 503)));
      final got = await ApiService.getIceServers();
      expect(got.servers.single['urls'], ['stun:stun.l.google.com:19302']);
      expect(got.relay, isFalse);
    });
  });
}
