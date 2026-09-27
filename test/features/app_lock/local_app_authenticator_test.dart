import 'package:conduit/features/app_lock/data/local_app_authenticator.dart';
import 'package:conduit/features/app_lock/domain/app_authenticator.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';

class _ThrowingLocalAuth implements LocalAuthentication {
  _ThrowingLocalAuth(this.code);

  final LocalAuthExceptionCode code;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #isDeviceSupported) {
      return Future.value(true);
    }
    if (invocation.memberName == #authenticate) {
      return Future<bool>.error(LocalAuthException(code: code));
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  Future<AppAuthenticationResult> resultFor(LocalAuthExceptionCode code) =>
      LocalAppAuthenticator(
        localAuthentication: _ThrowingLocalAuth(code),
      ).authenticate();

  test(
    'a device without a screen lock is unavailable, not cancelled',
    () async {
      expect(
        await resultFor(LocalAuthExceptionCode.noCredentialsSet),
        AppAuthenticationResult.unavailable,
      );
      expect(
        await resultFor(LocalAuthExceptionCode.noBiometricHardware),
        AppAuthenticationResult.unavailable,
      );
    },
  );

  test('cancels and lockouts keep the app locked', () async {
    expect(
      await resultFor(LocalAuthExceptionCode.userCanceled),
      AppAuthenticationResult.cancelled,
    );
    expect(
      await resultFor(LocalAuthExceptionCode.biometricLockout),
      AppAuthenticationResult.cancelled,
    );
  });
}
