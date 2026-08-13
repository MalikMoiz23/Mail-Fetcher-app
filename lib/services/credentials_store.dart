import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Gmail address plus the 16-character App Password used for IMAP login.
class MailCredentials {
  const MailCredentials({required this.email, required this.appPassword});

  final String email;
  final String appPassword;
}

/// Keeps the App Password in the Android Keystore rather than in
/// SharedPreferences, so a rooted-device dump or a backup does not leak it.
class CredentialsStore {
  const CredentialsStore._();

  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(),
  );

  static const String _emailKey = 'gmail_email';
  static const String _passwordKey = 'gmail_app_password';

  static Future<MailCredentials?> read() async {
    final email = await _storage.read(key: _emailKey);
    final password = await _storage.read(key: _passwordKey);
    if (email == null ||
        password == null ||
        email.isEmpty ||
        password.isEmpty) {
      return null;
    }
    return MailCredentials(email: email, appPassword: password);
  }

  static Future<void> save(MailCredentials credentials) async {
    await _storage.write(key: _emailKey, value: credentials.email);
    await _storage.write(key: _passwordKey, value: credentials.appPassword);
  }

  static Future<void> clear() async {
    await _storage.delete(key: _emailKey);
    await _storage.delete(key: _passwordKey);
  }
}
