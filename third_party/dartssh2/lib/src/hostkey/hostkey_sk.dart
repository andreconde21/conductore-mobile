import 'dart:typed_data';

import 'package:convert/convert.dart';
import 'package:dartssh2/src/ssh_hostkey.dart';
import 'package:dartssh2/src/ssh_message.dart';

class SSHSecurityKeyEcdsaPublicKey implements SSHHostKey {
  static const type = 'sk-ecdsa-sha2-nistp256@openssh.com';
  static const curveId = 'nistp256';

  SSHSecurityKeyEcdsaPublicKey({
    required this.q,
    required this.application,
  });

  final Uint8List q;
  final String application;

  factory SSHSecurityKeyEcdsaPublicKey.decode(Uint8List data) {
    final reader = SSHMessageReader(data);
    final type = reader.readUtf8();
    if (type != SSHSecurityKeyEcdsaPublicKey.type) {
      throw FormatException('Invalid security key ECDSA type: $type');
    }
    final curve = reader.readUtf8();
    if (curve != curveId) {
      throw UnsupportedError('Unsupported security key ECDSA curve: $curve');
    }
    final q = reader.readString();
    final application = reader.readUtf8();
    return SSHSecurityKeyEcdsaPublicKey(q: q, application: application);
  }

  @override
  Uint8List encode() {
    final writer = SSHMessageWriter();
    writer.writeUtf8(type);
    writer.writeUtf8(curveId);
    writer.writeString(q);
    writer.writeUtf8(application);
    return writer.takeBytes();
  }

  @override
  String toString() {
    return 'SSHSecurityKeyEcdsaPublicKey(application: $application, q: ${hex.encode(q)})';
  }
}

class SSHSecurityKeyEd25519PublicKey implements SSHHostKey {
  static const type = 'sk-ssh-ed25519@openssh.com';

  SSHSecurityKeyEd25519PublicKey({
    required this.key,
    required this.application,
  });

  final Uint8List key;
  final String application;

  factory SSHSecurityKeyEd25519PublicKey.decode(Uint8List data) {
    final reader = SSHMessageReader(data);
    final type = reader.readUtf8();
    if (type != SSHSecurityKeyEd25519PublicKey.type) {
      throw FormatException('Invalid security key Ed25519 type: $type');
    }
    final key = reader.readString();
    final application = reader.readUtf8();
    return SSHSecurityKeyEd25519PublicKey(
      key: key,
      application: application,
    );
  }

  @override
  Uint8List encode() {
    final writer = SSHMessageWriter();
    writer.writeUtf8(type);
    writer.writeString(key);
    writer.writeUtf8(application);
    return writer.takeBytes();
  }

  @override
  String toString() {
    return 'SSHSecurityKeyEd25519PublicKey(application: $application, key: ${hex.encode(key)})';
  }
}

class SSHSecurityKeyEcdsaSignature implements SSHSignature {
  static const type = SSHSecurityKeyEcdsaPublicKey.type;

  SSHSecurityKeyEcdsaSignature({
    required this.r,
    required this.s,
    required this.flags,
    required this.counter,
  });

  final BigInt r;
  final BigInt s;
  final int flags;
  final int counter;

  factory SSHSecurityKeyEcdsaSignature.decode(Uint8List data) {
    final reader = SSHMessageReader(data);
    final type = reader.readUtf8();
    if (type != SSHSecurityKeyEcdsaSignature.type) {
      throw FormatException('Invalid security key ECDSA signature type: $type');
    }
    final blobReader = SSHMessageReader(reader.readString());
    final r = blobReader.readMpint();
    final s = blobReader.readMpint();
    final flags = reader.readUint8();
    final counter = reader.readUint32();
    return SSHSecurityKeyEcdsaSignature(
      r: r,
      s: s,
      flags: flags,
      counter: counter,
    );
  }

  @override
  Uint8List encode() {
    final writer = SSHMessageWriter();
    writer.writeUtf8(type);
    final blobWriter = SSHMessageWriter();
    blobWriter.writeMpint(r);
    blobWriter.writeMpint(s);
    writer.writeString(blobWriter.takeBytes());
    writer.writeUint8(flags);
    writer.writeUint32(counter);
    return writer.takeBytes();
  }
}

class SSHSecurityKeyEd25519Signature implements SSHSignature {
  static const type = SSHSecurityKeyEd25519PublicKey.type;

  SSHSecurityKeyEd25519Signature({
    required this.signature,
    required this.flags,
    required this.counter,
  });

  final Uint8List signature;
  final int flags;
  final int counter;

  factory SSHSecurityKeyEd25519Signature.decode(Uint8List data) {
    final reader = SSHMessageReader(data);
    final type = reader.readUtf8();
    if (type != SSHSecurityKeyEd25519Signature.type) {
      throw FormatException(
        'Invalid security key Ed25519 signature type: $type',
      );
    }
    final signature = reader.readString();
    final flags = reader.readUint8();
    final counter = reader.readUint32();
    return SSHSecurityKeyEd25519Signature(
      signature: signature,
      flags: flags,
      counter: counter,
    );
  }

  @override
  Uint8List encode() {
    final writer = SSHMessageWriter();
    writer.writeUtf8(type);
    writer.writeString(signature);
    writer.writeUint8(flags);
    writer.writeUint32(counter);
    return writer.takeBytes();
  }
}
