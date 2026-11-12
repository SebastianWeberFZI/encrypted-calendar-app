import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// KDF-Parameter, unverschlüsselt in meta.json im Daten-Repo abgelegt.
/// (Format identisch zur encrypted-todo-app.)
class CryptoParams {
  const CryptoParams({
    required this.salt,
    this.kdf = 'argon2id',
    this.memoryKiB = 65536,
    this.iterations = 3,
    this.parallelism = 2,
    this.version = 1,
  });

  /// Höchste KDF-Parameter-Version, die diese App kennt.
  static const int supportedVersion = 1;

  /// Base64-kodiertes Salt (16 Byte).
  final String salt;
  final String kdf;
  final int memoryKiB;
  final int iterations;
  final int parallelism;
  final int version;

  /// false, wenn eine neuere App-Version das Repo mit einem Verfahren
  /// eingerichtet hat, das diese App nicht kennt.
  bool get isSupported =>
      kdf == 'argon2id' && version <= supportedVersion && salt.isNotEmpty;

  Map<String, dynamic> toJson() => {
        'version': version,
        'kdf': kdf,
        'salt': salt,
        'memory_kib': memoryKiB,
        'iterations': iterations,
        'parallelism': parallelism,
      };

  factory CryptoParams.fromJson(Map<String, dynamic> json) {
    int n(String k, int d) {
      final v = json[k];
      return v is num ? v.toInt() : d;
    }

    final salt = json['salt'];
    final kdf = json['kdf'];
    return CryptoParams(
      salt: salt is String ? salt : '',
      kdf: kdf is String ? kdf : 'argon2id',
      memoryKiB: n('memory_kib', 65536),
      iterations: n('iterations', 3),
      parallelism: n('parallelism', 2),
      version: n('version', 1),
    );
  }

  factory CryptoParams.generate() {
    final rng = Random.secure();
    final salt =
        Uint8List.fromList(List<int>.generate(16, (_) => rng.nextInt(256)));
    return CryptoParams(salt: base64Encode(salt));
  }
}

class DecryptionFailedException implements Exception {
  const DecryptionFailedException();
  @override
  String toString() =>
      'Entschlüsselung fehlgeschlagen (falsche Passphrase oder beschädigte Daten)';
}

/// Das Dokument wurde von einer neueren App-Version in einem Format
/// verschlüsselt, das diese Version noch nicht kennt. Es darf weder gelesen
/// noch überschrieben werden.
class UnsupportedFormatException extends DecryptionFailedException {
  const UnsupportedFormatException();
  @override
  String toString() =>
      'Format einer neueren App-Version – bitte die App aktualisieren';
}

/// AES-256-GCM pro Dokument, Master-Key aus Passphrase via Argon2id.
///
/// Dokumentformat: [1 Byte Formatversion][12 Byte Nonce][Ciphertext][16 Byte MAC]
class CryptoService {
  static const int _formatVersion = 1;
  static const int _nonceLength = 12;
  static const int _macLength = 16;

  final AesGcm _aes = AesGcm.with256bits();
  final Hmac _hmac = Hmac.sha256();

  /// Leitet den Master-Key aus der Passphrase ab (rechenintensiv, einmalig).
  Future<SecretKey> deriveKey(String passphrase, CryptoParams params) async {
    final argon2 = Argon2id(
      memory: params.memoryKiB,
      iterations: params.iterations,
      parallelism: params.parallelism,
      hashLength: 32,
    );
    return argon2.deriveKeyFromPassword(
      password: passphrase,
      nonce: base64Decode(params.salt),
    );
  }

  Future<Uint8List> encryptBytes(List<int> plain, SecretKey key) async {
    final box = await _aes.encrypt(plain, secretKey: key);
    final out = BytesBuilder();
    out.addByte(_formatVersion);
    out.add(box.concatenation()); // nonce + ciphertext + mac
    return out.toBytes();
  }

  Future<Uint8List> decryptBytes(List<int> data, SecretKey key) async {
    if (data.isEmpty) throw const DecryptionFailedException();
    if (data[0] > _formatVersion) throw const UnsupportedFormatException();
    if (data[0] != _formatVersion ||
        data.length < 1 + _nonceLength + _macLength) {
      throw const DecryptionFailedException();
    }
    try {
      final box = SecretBox.fromConcatenation(
        data.sublist(1),
        nonceLength: _nonceLength,
        macLength: _macLength,
      );
      final clear = await _aes.decrypt(box, secretKey: key);
      return Uint8List.fromList(clear);
    } on SecretBoxAuthenticationError {
      throw const DecryptionFailedException();
    } on ArgumentError {
      throw const DecryptionFailedException();
    }
  }

  Future<Uint8List> encryptJson(Object json, SecretKey key) =>
      encryptBytes(utf8.encode(jsonEncode(json)), key);

  /// Entschlüsselt ein JSON-Dokument. Nicht lesbarer Inhalt (kein gültiges
  /// UTF-8/JSON) gilt als beschädigt: [DecryptionFailedException].
  Future<dynamic> decryptJson(List<int> data, SecretKey key) async {
    final bytes = await decryptBytes(data, key);
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw const DecryptionFailedException();
    }
  }

  /// Wie [decryptJson], verlangt aber ein JSON-Objekt.
  Future<Map<String, dynamic>> decryptDoc(List<int> data, SecretKey key) async {
    final json = await decryptJson(data, key);
    if (json is! Map) throw const DecryptionFailedException();
    return json.cast<String, dynamic>();
  }

  /// Deterministische, nicht umkehrbare ID (HMAC-SHA256, 32 Hex-Zeichen).
  /// Gleiche Eingabe + gleicher Schlüssel = gleiche ID auf allen Geräten,
  /// ohne den Klartext im Dateinamen preiszugeben.
  Future<String> deterministicId(String input, SecretKey key) async {
    final mac = await _hmac.calculateMac(utf8.encode(input), secretKey: key);
    return mac.bytes
        .take(16)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }
}
