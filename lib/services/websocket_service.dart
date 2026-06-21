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

    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      _statusCtrl.add(WebSocketStatus.connected);
      developer.log('WS: Connected', name:'ws');
      _listen();
    } catch (e) {
      if (!_statusCtrl.isClosed){
        _statusCtrl.add(WebSocketStatus.disconnected);
        developer.log('WS: Connect failed: $e', name: 'ws');
        _scheduleReconnect();
      }
    }
  }

  void _listen() {
    _channel?.stream.listen(
      (msg) {
        final data = json.decode(msg);
        _notifCtrl.add(NotificationModel.fromJson(data));
      },
      onDone: () {
        if (!_statusCtrl.isClosed) {
          _statusCtrl.add(WebSocketStatus.disconnected);
          _scheduleReconnect();
        }
      },
      onError:(error){
        if(!_statusCtrl.isClosed){
          _statusCtrl.add(WebSocketStatus.disconnected);
          _scheduleReconnect();
        }
      },
    );
  }

  void _scheduleReconnect() {
    if (_isDisposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 5), () {
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