import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:dart_mosh/dart_mosh.dart';
import 'package:flutter/foundation.dart';

/// Asks a mosh-server to end its session, as `mosh` does when it quits:
/// a transport instruction whose new state number is the reserved
/// `uint64(-1)`. The server acknowledges it, hangs up its terminal (the
/// shell, or a Herdr or tmux client, gets SIGHUP) and exits.
///
/// dart_mosh's `MoshSession.close` only closes the UDP socket, which
/// leaves the server waiting for a client that never comes back. This
/// sends the request from a socket of its own, bound when the session
/// starts so that [send] needs no await (the app may be quitting).
class MoshServerShutdown {
  MoshServerShutdown._(this._socket, this._address, this._port, this._cipher)
    : _replies = StreamController<Uint8List>.broadcast() {
    _socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      Datagram? datagram;
      while ((datagram = _socket.receive()) != null) {
        _replies.add(datagram!.data);
      }
    });
  }

  /// Binds the socket the request goes out from.
  static Future<MoshServerShutdown> bind({
    required InternetAddress address,
    required int port,
    required MoshCipher cipher,
  }) async {
    final socket = await RawDatagramSocket.bind(
      address.type == InternetAddressType.IPv6
          ? InternetAddress.anyIPv6
          : InternetAddress.anyIPv4,
      0,
    );
    return MoshServerShutdown._(socket, address, port, cipher);
  }

  final RawDatagramSocket _socket;
  final InternetAddress _address;
  final int _port;
  final MoshCipher _cipher;
  final StreamController<Uint8List> _replies;
  bool _closed = false;

  /// How many of the client's latest input states the request is based
  /// on, newest first. The server only takes an instruction based on a
  /// state it still holds: the last one it acknowledged, which is at most
  /// this many behind the newest the client sent.
  static const baseStates = 8;

  /// Sends the request, based on each of the client's input states from
  /// [stateNum] back by [baseStates] (the server ignores the ones it does
  /// not hold), twice in case a datagram is lost.
  void send(int stateNum) {
    if (_closed) return;
    final random = Random.secure();
    // Far above the session's own sequence numbers and fragment ids, so
    // no nonce is used twice under the session key and the server reads
    // this as the newest packet (it then answers to this socket).
    var sequence = (1 << 62) + random.nextInt(1 << 32);
    final fragmentBase = (1 << 48) + random.nextInt(1 << 32);
    for (var round = 0; round < 2; round++) {
      for (var i = 0; i < baseStates && stateNum - i >= 0; i++) {
        final payload = moshCompress(shutdownInstruction(stateNum - i));
        for (final fragment in moshFragments(
          fragmentBase + round * baseStates + i,
          payload,
          moshDefaultSendMtu,
        )) {
          final packet = _cipher.encrypt(
            nonce: sequence++,
            plaintext: MoshTransportPacket(
              timestamp: 0,
              timestampReply: MoshTransportPacket.noTimestamp,
              payload: fragment.encode(),
            ).encode(),
          );
          try {
            _socket.send(packet, _address, _port);
          } on SocketException {
            return;
          }
        }
      }
    }
  }

  /// Completes true once the server acknowledges the request (it then
  /// exits), false when nothing says so within [timeout].
  Future<bool> acknowledged(Duration timeout) async {
    if (_closed) return false;
    final assembly = MoshFragmentAssembly();
    try {
      await _replies.stream
          .where((datagram) {
            try {
              final packet = MoshTransportPacket.decode(
                _cipher.decrypt(datagram),
              );
              final assembled = assembly.add(
                MoshFragment.decode(packet.payload),
              );
              if (assembled == null) return false;
              return MoshTransportInstruction.decode(
                    moshDecompress(assembled),
                  ).ackNum ==
                  MoshTransportInstruction.shutdownStateNum;
            } catch (_) {
              return false;
            }
          })
          .first
          .timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    } on StateError {
      return false;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _socket.close();
    unawaited(_replies.close());
  }

  /// The protobuf of a shutdown request on input state [oldNum]. Written
  /// by hand: dart_mosh's encoder refuses the negative number that
  /// `uint64(-1)` is in Dart.
  @visibleForTesting
  static Uint8List shutdownInstruction(int oldNum) {
    final out = BytesBuilder();
    void varint(int value) {
      // Unsigned: a negative int is written as its 64-bit two's complement.
      var remaining = value;
      for (var i = 0; i < 9 && (remaining < 0 || remaining >= 0x80); i++) {
        out.addByte((remaining & 0x7f) | 0x80);
        remaining = remaining >>> 7;
      }
      out.addByte(remaining & 0x7f);
    }

    void field(int number, int value) {
      varint(number << 3);
      varint(value);
    }

    field(1, moshProtocolVersion);
    field(2, oldNum);
    field(3, MoshTransportInstruction.shutdownStateNum);
    // Acknowledges and throws away nothing: no state of the server's or
    // the client's is dropped by a request that may be based on the
    // wrong one.
    field(4, 0);
    field(5, 0);
    return out.takeBytes();
  }
}
