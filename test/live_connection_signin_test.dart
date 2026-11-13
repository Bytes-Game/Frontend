// The live connection's sign-in.
//
// The app keeps one live connection open to the server, for messages,
// notifications and calls as they happen. It is opened with the sign-in.
//
// The sign-in used to go on the end of the address: /ws/maya?token=…
// An address is written down on the way: in the host's request log, and
// by anything between the phone and the server. Whoever reads it there
// can use the sign-in until it runs out. It now goes in a header.
//
// These open a real connection to a real server on this machine and look
// at what arrived.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:myapp/services/api_service.dart';
import 'package:myapp/services/websocket_service.dart';

/// A sign-in as the server makes one, for the parts the app reads.
String signIn(String username) {
  String part(Map<String, dynamic> m) =>
      base64Url.encode(utf8.encode(json.encode(m))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.${part({'sub': '1', 'username': username})}.sig';
}

void main() {
  late HttpServer server;

  /// Every opening request, as it arrived: the whole address, and what
  /// the protocols header said.
  late List<({String address, List<String> protocols})> opened;
  late List<WebSocket> sockets;

  /// What the server picks from the protocols the app offered. The real
  /// server picks "bearer"; a server that picks nothing still connects.
  String? Function(List<String>)? pick;

  setUp(() async {
    opened = [];
    sockets = [];
    pick = (_) => wsSignInProtocol;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) async {
      opened.add((
        address: req.uri.toString(),
        protocols: [
          for (final line
              in req.headers['sec-websocket-protocol'] ?? const <String>[])
            for (final p in line.split(',')) p.trim(),
        ],
      ));
      final choose = pick;
      final socket = await WebSocketTransformer.upgrade(
        req,
        protocolSelector: choose == null ? null : (offered) => choose(offered),
      );
      sockets.add(socket);
      socket.listen((_) {});
    });
  });
  tearDown(() async {
    for (final s in sockets) {
      await s.close();
    }
    await server.close(force: true);
    ApiService.clearAuth();
  });

  Future<void> until(bool Function() done) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (!done()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('waited 3 seconds; opening requests: $opened');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('the sign-in is in the header, and nowhere in the address', () async {
    final token = signIn('maya');
    ApiService.authToken = token;
    final ws = WebSocketService('ws://127.0.0.1:${server.port}', 'maya');
    addTearDown(ws.dispose);

    ws.connect();
    await until(() => ws.isConnected);

    final first = opened.single;
    // The address is the account's name and nothing else.
    expect(first.address, '/ws/maya');
    expect(first.address.contains('token'), isFalse);
    expect(first.address.contains(token), isFalse);
    // The header: the word the server looks for, then the sign-in.
    expect(first.protocols, [wsSignInProtocol, token]);
    expect(wsSignInProtocol, 'bearer');
  });

  test('a real sign-in is made only of characters a header may carry', () {
    // Letters, digits, "-", "_" and "." are all a protocol name may hold
    // without quoting. A sign-in is three runs of exactly those, joined by
    // dots; one with anything else would be refused before it was sent.
    final token = signIn('maya_2.b-c');
    expect(RegExp(r'^[A-Za-z0-9._-]+$').hasMatch(token), isTrue);
  });

  test('it connects to a server that names no protocol back', () async {
    pick = null;
    ApiService.authToken = signIn('maya');
    final ws = WebSocketService('ws://127.0.0.1:${server.port}', 'maya');
    addTearDown(ws.dispose);

    ws.connect();
    await until(() => ws.isConnected);
    expect(opened.single.address, '/ws/maya');
  });

  test('what arrives on that connection is heard', () async {
    ApiService.authToken = signIn('maya');
    final ws = WebSocketService('ws://127.0.0.1:${server.port}', 'maya');
    addTearDown(ws.dispose);
    final heard = <Map<String, dynamic>>[];
    final listening = ws.events.listen(heard.add);
    addTearDown(listening.cancel);

    ws.connect();
    await until(() => ws.isConnected && sockets.isNotEmpty);
    sockets.single.add(json.encode({'type': 'typing', 'from': 'leo'}));
    await until(() => heard.isNotEmpty);
    expect(heard.single['from'], 'leo');
  });
}
