import 'dart:async';
import 'dart:convert';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'dart:developer' as developer;

import 'package:myapp/models/notification_model.dart';
import 'package:myapp/services/api_service.dart';

/// Connection status exposed as a stream so the UI can show a dot.
enum WebSocketStatus { connected, disconnected, connecting }

/// Manages a single persistent WebSocket connection to the Go backend.
///
/// Responsibilities:
/// • Connect to wss://host/ws/{username]
/// • Receive real-time notifications and push them via [notificationStream]
/// • Auto-reconnect every 5 s when the connection drops
///
/// This is a *service* (no ChangeNotifier) - it is provided via
/// `Provider<WebSocketService>.value` in the widget tree.
class WebSocketService {
  final String _baseUrl;
  final String _username;
  WebSocketChannel? _channel;
  Timer? _reconnectTimer;
  bool _isDisposed = false;

  /// Backoff exponent for the next reconnect: delay = 5s << step, so
  /// 5s, 10s, 20s, 40s, 80s. Reset to 0 whenever a handshake succeeds.
  int _reconnectDelayStep = 0;
  static const int _maxReconnectStep = 4;

  final _statusCtrl = StreamController<WebSocketStatus>.broadcast();
  Stream<WebSocketStatus> get statusStream => _statusCtrl.stream;

  final _notifCtrl = StreamController<NotificationModel>.broadcast();
  Stream<NotificationModel> get notificationStream => _notifCtrl.stream;

  WebSocketService(this._baseUrl, this._username);

  /// Opens the WebSocket connection.
  void connect() {
    if (_isDisposed ||_statusCtrl.isClosed) return;
    if (_username.isEmpty || _baseUrl.isEmpty) return;

    _statusCtrl.add(WebSocketStatus.connecting);
    // The socket authenticates with the session token as a query param —
    // browsers can't set an Authorization header on a WebSocket handshake, and
    // the backend rejects the upgrade if the token's user doesn't match the
    // path username. (See WebsocketHandler in devb/websocket.go.)
    final token = ApiService.authToken ?? '';
    final url =
        '$_baseUrl/ws/$_username?token=${Uri.encodeQueryComponent(token)}';
    developer.log('Ws: Connecting to $_baseUrl/ws/$_username', name: 'ws');

    final WebSocketChannel channel;
    try {
      channel = WebSocketChannel.connect(Uri.parse(url));
    } catch (e) {
      // Only synchronous failures (a malformed URI) land here.
      _handleDrop('connect threw: $e');
      return;
    }
    _channel = channel;

    // WebSocketChannel.connect is LAZY: it hands back a channel immediately
    // and performs the HTTP upgrade in the background. A refused upgrade
    // (expired token, server down, proxy in the way) surfaces as an error on
    // `ready` — and because nothing used to await that future, Dart reported
    // it as an *unhandled* exception. That's what filled the logs with
    //   "Connection to '…/ws/…' was not upgraded to websocket"
    // once per reconnect, and with Sentry configured it would ship a crash
    // report each time too.
    //
    // Handling `ready` also makes the status honest: previously we announced
    // `connected` the instant connect() returned, before any handshake had
    // happened, so the UI's connection dot was green while the socket was
    // actually dead.
    channel.ready.then((_) {
      if (_isDisposed || _statusCtrl.isClosed) return;
      _reconnectDelayStep = 0; // a real connection resets the backoff
      _statusCtrl.add(WebSocketStatus.connected);
      developer.log('WS: Connected', name: 'ws');
      _listen();
    }).catchError((Object e) {
      _handleDrop('handshake failed: $e');
    });
  }

  /// Single exit path for "the socket is not usable" — from a synchronous
  /// throw, a refused handshake, a stream error, or a clean close.
  void _handleDrop(String why) {
    if (_isDisposed || _statusCtrl.isClosed) return;
    developer.log('WS: $why', name: 'ws');
    _statusCtrl.add(WebSocketStatus.disconnected);
    _scheduleReconnect();
  }

  void _listen() {
    _channel?.stream.listen(
      (msg) {
        final data = json.decode(msg);
        _notifCtrl.add(NotificationModel.fromJson(data));
      },
      onDone: () => _handleDrop('closed by peer'),
      onError: (Object error) => _handleDrop('stream error: $error'),
    );
  }

  void _scheduleReconnect() {
    if (_isDisposed) return;
    _reconnectTimer?.cancel();
    // Exponential backoff, capped. A flat 5-second retry against a backend
    // that keeps refusing the upgrade (dead token, outage) meant a failed
    // handshake — and a log line — every 5 seconds, forever. Backing off to
    // a minute keeps a genuinely transient drop fast to recover while a
    // persistent failure stays quiet.
    final delay = Duration(seconds: 5 * (1 << _reconnectDelayStep));
    if (_reconnectDelayStep < _maxReconnectStep) _reconnectDelayStep++;
    _reconnectTimer = Timer(delay, () {
      developer.log('WS: Reconnecting...', name: 'ws');
      connect();
    });
  }

  /// Tears down everything cleanly.
  void dispose() {
    _isDisposed = true;
    _reconnectTimer?.cancel();
    _statusCtrl.close();
    _notifCtrl.close();
    _channel?.sink.close();
  }
}