import 'package:conduit/features/app_lock/domain/app_authenticator.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';

class LocalAppAuthenticator implements AppAuthenticator {
  LocalAppAuthenticator({LocalAuthentication? localAuthentication})
    : _localAuthentication = localAuthentication ?? LocalAuthentication();

  final LocalAuthentication _localAuthentication;

  @override
  Future<bool> canAuthenticate() async {
    try {
      return await _localAuthentication.isDeviceSupported();
    } on LocalAuthException {
      return false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<AppAuthenticationResult> authenticate() async {
    try {
      final authenticated = await _localAuthentication.authenticate(
        localizedReason: 'Unlock Conductore to access saved SSH machines.',
      );
      return authenticated
          ? AppAuthenticationResult.success
          : AppAuthenticationResult.cancelled;
    } on LocalAuthException catch (error) {
      // local_auth 3 reports failures this way, not as PlatformException.
      return _unavailableCodes.contains(error.code)
          ? AppAuthenticationResult.unavailable
          : AppAuthenticationResult.cancelled;
    } on PlatformException {
      return AppAuthenticationResult.unavailable;
    }
  }

  /// The device cannot authenticate at all (no screen lock, no hardware):
  /// the lock page then offers "Continue without auth". Cancels, timeouts
  /// and lockouts stay locked.
  static const _unavailableCodes = {
    LocalAuthExceptionCode.noCredentialsSet,
    LocalAuthExceptionCode.noBiometricHardware,
    LocalAuthExceptionCode.noBiometricsEnrolled,
    LocalAuthExceptionCode.uiUnavailable,
    LocalAuthExceptionCode.deviceError,
  };
}
