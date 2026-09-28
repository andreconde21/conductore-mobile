import 'package:conduit/features/continuity/domain/continuity_throttle.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a burst goes out once, after it settles', () {
    fakeAsync((async) {
      var fired = 0;
      final throttle = ContinuityThrottle(
        onFire: () => fired += 1,
        now: () => async.getClock(DateTime(2026)).now(),
      );
      for (var i = 0; i < 20; i++) {
        throttle.poke();
        async.elapse(const Duration(milliseconds: 50));
      }
      expect(fired, 0);
      async.elapse(const Duration(seconds: 2));
      expect(fired, 1);
      expect(throttle.pending, isFalse);
    });
  });

  test('changes that keep coming go out at most every interval', () {
    fakeAsync((async) {
      final fires = <Duration>[];
      final start = DateTime(2026);
      final throttle = ContinuityThrottle(
        onFire: () => fires.add(async.elapsed),
        now: () => start.add(async.elapsed),
      );
      // A change every second for 35 s.
      for (var i = 0; i < 35; i++) {
        throttle.poke();
        async.elapse(const Duration(seconds: 1));
      }
      async.elapse(const Duration(seconds: 10));
      expect(fires, isNotEmpty);
      for (var i = 1; i < fires.length; i++) {
        expect(
          fires[i] - fires[i - 1],
          greaterThanOrEqualTo(const Duration(seconds: 10)),
        );
      }
      // The last change still went out.
      expect(throttle.pending, isFalse);
      expect(fires.length, lessThanOrEqualTo(5));
      throttle.dispose();
    });
  });

  test('flush sends a waiting change at once, and nothing otherwise', () {
    fakeAsync((async) {
      var fired = 0;
      final throttle = ContinuityThrottle(onFire: () => fired += 1);
      throttle.flush();
      expect(fired, 0);
      throttle.poke();
      throttle.flush();
      expect(fired, 1);
      async.elapse(const Duration(seconds: 30));
      expect(fired, 1);
    });
  });
}
