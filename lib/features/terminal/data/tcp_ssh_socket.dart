import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:conduit/features/terminal/data/host_key_capture.dart';
import 'package:dartssh2/dartssh2.dart';

class TcpSshSocket implements SSHSocket {
  TcpSshSocket._(this._socket);

  static Future<TcpSshSocket> connect(
    String host,
    int port, {
    Duration? timeout,
  }) async {
    final socket = await Socket.connect(host, port, timeout: timeout);
    return TcpSshSocket._(socket);
  }

  final Socket _socket;

  InternetAddress? get remoteAddress {
    try {
      return _socket.remoteAddress;
    } on SocketException {
      return null;
    }
  }

  // The host key is read off the unencrypted key exchange for its SHA256
  // fingerprint (see HostKeyCapture).
  late final Stream<Uint8List> _stream = () {
    final capture = HostKeyCapture();
    return _socket.map((chunk) {
      capture.add(chunk);
      return chunk;
    });
  }();

  @override
  Stream<Uint8List> get stream => _stream;

  @override
  StreamSink<List<int>> get sink => _socket;

  @override
  Future<void> get done => _socket.done;

  @override
  Future<void> close() async {
    await _socket.close();
  }

  @override
  void destroy() {
    _socket.destroy();
  }
}
