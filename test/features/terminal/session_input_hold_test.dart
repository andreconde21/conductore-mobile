import 'dart:async';

import 'package:conduit/features/terminal/presentation/session_input_hold.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<String> sent;
  late SessionInputHold hold;

  setUp(() {
    sent = [];
    hold = SessionInputHold(deliver: sent.add);
  });

  tearDown(() => hold.dispose());

  test('input flows untouched when nothing holds it', () {
    expect(hold.offer('a'), isFalse);
    expect(hold.state.value, isNull);
  });

  test('a confirmation delivers held input in order', () {
    fakeAsync((async) {
      final ready = Completer<bool>();
      hold.hold(ready.future, label: 'w1');
      expect(hold.offer('l'), isTrue);
      expect(hold.offer('s'), isTrue);
      expect(sent, isEmpty);
      ready.complete(true);
      async.flushMicrotasks();
      expect(sent, ['l', 's']);
      expect(hold.state.value, isNull);
    });
  });

  test('no confirmation in time drops the input and says so', () {
    fakeAsync((async) {
      hold.hold(Completer<bool>().future, label: 'w1');
      hold.offer('yes\r');
      async.elapse(SessionInputHold.defaultTimeout);
      expect(sent, isEmpty);
      final state = hold.state.value;
      expect(state, isA<InputHoldFailed>());
      expect((state! as InputHoldFailed).dropped, 4);
      async.elapse(SessionInputHold.failureNoticeDuration);
      expect(hold.state.value, isNull);
    });
  });

  test('a newer hold decides; the older one\'s answer is ignored', () {
    fakeAsync((async) {
      final first = Completer<bool>();
      final second = Completer<bool>();
      hold.hold(first.future);
      hold.offer('a');
      hold.hold(second.future);
      hold.offer('b');
      first.complete(false);
      async.flushMicrotasks();
      expect(hold.holding, isTrue);
      second.complete(true);
      async.flushMicrotasks();
      expect(sent, ['a', 'b']);
    });
  });
}
