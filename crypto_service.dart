import 'package:encrypt/encrypt.dart';

class CryptoService {
  // ✅ 32 bytes exactly (256 bit key)
  static final Key _key = Key.fromUtf8("ECHO_RESCUE_SECURE_KEY_32_BYTE!!");

  // ✅ 16 bytes exactly
  static final IV _iv = IV.fromUtf8("ECHO_IV_16_BYTES");

  static final Encrypter _encrypter = Encrypter(AES(_key, mode: AESMode.cbc));

  static String encrypt(String plainText) {
    final encrypted = _encrypter.encrypt(plainText, iv: _iv);
    return encrypted.base64;
  }

  static String decrypt(String encryptedText) {
    final encrypted = Encrypted.fromBase64(encryptedText);
    return _encrypter.decrypt(encrypted, iv: _iv);
  }
}
