import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/message/msg_channel.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_channel.dart';
// ignore: implementation_imports
import 'package:dartssh2/src/ssh_message.dart';
import 'package:flutter_test/flutter_test.dart';

/// The vendored dartssh2 keeps a command's exit status when it arrives in
/// the same read as the exec reply (CON-123): a fast command on a busy
/// phone gets its reply, output, exit-status and close in one TCP read,
/// all handled before [SSHClient.execute] wraps the channel in an
/// [SSHSession]. The status used to be dropped then, and a version check
/// that printed its JSON read as failed.
void main() {
  SSHChannelController channel() => SSHChannelController(
    localId: 0,
    localMaximumPacketSize: 32768,
    localInitialWindowSize: 1 << 20,
    remoteId: 7,
    remoteMaximumPacketSize: 32768,
    remoteInitialWindowSize: 1 << 20,
    sendMessage: (_) {},
  );

  SSH_Message_Channel_Request exitStatus(int code) =>
      SSH_Message_Channel_Request(
        recipientChannel: 0,
        requestType: SSHChannelRequestType.exitStatus,
        wantReply: false,
        exitStatus: code,
      );

  // What the client does: the exec request, then the session once the
  // reply came. Every [replies] message is handled synchronously after the
  // reply, as they are when they share one read.
  Future<SSHSession> exec(
    SSHChannelController controller,
    List<SSHMessage> replies,
  ) async {
    final started = controller.sendExec('conductore-hostd version');
    controller.handleMessage(SSH_Message_Channel_Success(recipientChannel: 0));
    replies.forEach(controller.handleMessage);
    expect(await started, isTrue);
    return SSHSession(controller.channel);
  }

  test('the exit status that came with the exec reply is kept', () async {
    final controller = channel();
    final session = await exec(controller, [
      SSH_Message_Channel_Data(
        recipientChannel: 0,
        data: Uint8List.fromList(utf8.encode('{"version":"1.8.1"}\n')),
      ),
      exitStatus(0),
      SSH_Message_Channel_EOF(recipientChannel: 0),
      SSH_Message_Channel_Close(recipientChannel: 0),
    ]);

    final stdout = utf8.decode(
      await session.stdout.expand((chunk) => chunk).toList(),
    );
    await session.done;

    expect(stdout, '{"version":"1.8.1"}\n');
    expect(session.exitCode, 0);
  });

  test('a non-zero status and an exit signal are kept too', () async {
    final controller = channel();
    final session = await exec(controller, [
      exitStatus(3),
      SSH_Message_Channel_Request(
        recipientChannel: 0,
        requestType: SSHChannelRequestType.exitSignal,
        wantReply: false,
        exitSignalName: 'TERM',
        coreDumped: false,
        errorMessage: '',
        languageTag: '',
      ),
      SSH_Message_Channel_EOF(recipientChannel: 0),
      SSH_Message_Channel_Close(recipientChannel: 0),
    ]);
    await session.done;

    expect(session.exitCode, 3);
    expect(session.exitSignal?.signalName, 'TERM');
  });

  test('a status after the session exists still lands', () async {
    final controller = channel();
    final session = await exec(controller, const []);
    controller
      ..handleMessage(exitStatus(0))
      ..handleMessage(SSH_Message_Channel_EOF(recipientChannel: 0))
      ..handleMessage(SSH_Message_Channel_Close(recipientChannel: 0));
    await session.done;

    expect(session.exitCode, 0);
  });
}
