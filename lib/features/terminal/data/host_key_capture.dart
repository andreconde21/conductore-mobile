import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Reads the server's host key off the unencrypted start of an SSH
/// connection, so the host-key check can show and pin its SHA256
/// fingerprint (what `ssh` and `ssh-keygen -lf` print) although the SSH
/// library only reports the key's MD5.
///
/// Until the first `SSH_MSG_NEWKEYS` the transport is plain binary
/// packets; the key-exchange reply (`SSH_MSG_KEXDH_REPLY` /
/// `KEX_ECDH_REPLY`, 31, or `KEX_DH_GEX_REPLY`, 33) starts with the host
/// key blob. Each blob seen is remembered in [HostKeyFingerprints] under
/// its MD5, which is exactly what the library hands the verifier, so the
/// SHA256 looked up is always that of the key being verified.
class HostKeyCapture {
  static const _maxBuffered = 256 * 1024;
  static const _msgNewKeys = 21;
  static const _msgKexReply = 31;
  static const _msgKexGexReply = 33;

  final BytesBuilder _buffer = BytesBuilder(copy: false);
  bool _bannerSeen = false;
  bool _done = false;

  /// Feeds the next bytes the server sent.
  void add(List<int> chunk) {
    if (_done) return;
    _buffer.add(chunk);
    if (_buffer.length > _maxBuffered) {
      _finish();
      return;
    }
    var bytes = _buffer.toBytes();
    var offset = 0;
    if (!_bannerSeen) {
      // Lines before the `SSH-` identification line are allowed.
      while (true) {
        final newline = bytes.indexOf(0x0a, offset);
        if (newline == -1) break;
        final isBanner =
            newline - offset >= 4 &&
            ascii.decode(
                  bytes.sublist(offset, offset + 4),
                  allowInvalid: true,
                ) ==
                'SSH-';
        offset = newline + 1;
        if (isBanner) {
          _bannerSeen = true;
          break;
        }
      }
      if (!_bannerSeen) {
        _keep(bytes, offset);
        return;
      }
    }
    while (!_done && bytes.length - offset >= 5) {
      final view = ByteData.sublistView(bytes);
      final length = view.getUint32(offset);
      if (length < 2 || length > _maxBuffered) {
        _finish();
        return;
      }
      if (bytes.length - offset - 4 < length) break;
      final padding = bytes[offset + 4];
      final payloadLength = length - padding - 1;
      if (payloadLength < 1) {
        _finish();
        return;
      }
      final payload = Uint8List.sublistView(
        bytes,
        offset + 5,
        offset + 5 + payloadLength,
      );
      offset += 4 + length;
      switch (payload[0]) {
        case _msgNewKeys:
          _finish();
          return;
        case _msgKexReply || _msgKexGexReply:
          final blob = hostKeyBlobOf(payload);
          if (blob != null) HostKeyFingerprints.remember(blob);
      }
    }
    if (!_done) {
      bytes = Uint8List.sublistView(bytes, offset);
      _buffer.clear();
      _buffer.add(bytes);
    }
  }

  void _keep(Uint8List bytes, int offset) {
    final rest = Uint8List.sublistView(bytes, offset);
    _buffer.clear();
    _buffer.add(rest);
  }

  void _finish() {
    _done = true;
    _buffer.clear();
  }

  /// The host key blob a key-exchange reply [payload] starts with, or null
  /// when its first field is not one (`KEX_DH_GEX_GROUP`, also 31, starts
  /// with a prime).
  static Uint8List? hostKeyBlobOf(Uint8List payload) {
    if (payload.length < 5) return null;
    final view = ByteData.sublistView(payload);
    final blobLength = view.getUint32(1);
    if (blobLength < 4 || payload.length < 5 + blobLength) return null;
    final blob = Uint8List.sublistView(payload, 5, 5 + blobLength);
    final nameLength = ByteData.sublistView(blob).getUint32(0);
    if (nameLength == 0 || nameLength > 64 || blob.length < 4 + nameLength) {
      return null;
    }
    final name = String.fromCharCodes(blob, 4, 4 + nameLength);
    if (!_keyType.hasMatch(name)) return null;
    return Uint8List.fromList(blob);
  }

  static final _keyType = RegExp(r'^(ssh|ecdsa|sk|rsa)-[a-z0-9@.\-]+$');
}

/// SHA256 fingerprints of recently seen host keys, by their MD5 one.
abstract final class HostKeyFingerprints {
  static const _capacity = 32;
  static final _byMd5 = <String, String>{};

  static void remember(Uint8List blob) {
    final md5Fingerprint = md5HostKeyFingerprint(blob);
    _byMd5.remove(md5Fingerprint);
    _byMd5[md5Fingerprint] = sha256HostKeyFingerprint(blob);
    while (_byMd5.length > _capacity) {
      _byMd5.remove(_byMd5.keys.first);
    }
  }

  /// The SHA256 fingerprint of the key whose [md5Fingerprint]
  /// (`MD5:aa:bb:…`) the SSH library reported, if its blob was seen.
  static String? sha256For(String md5Fingerprint) => _byMd5[md5Fingerprint];
}

/// `MD5:aa:bb:…`, the fingerprint format the app has always stored.
String md5HostKeyFingerprint(List<int> blob) {
  final hex = [
    for (final byte in md5.convert(blob).bytes)
      byte.toRadixString(16).padLeft(2, '0'),
  ];
  return 'MD5:${hex.join(':')}';
}

/// `SHA256:` and the unpadded base64 of the key blob's SHA-256, as
/// OpenSSH prints it.
String sha256HostKeyFingerprint(List<int> blob) =>
    'SHA256:${base64.encode(sha256.convert(blob).bytes).replaceAll('=', '')}';
