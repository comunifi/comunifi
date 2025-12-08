import 'package:flutter/foundation.dart';
import '../key_schedule/key_schedule.dart';
import 'default_crypto.dart';

/// Input parameters for MLS decryption in isolate
class MlsDecryptParams {
  final int epoch;
  final int senderIndex;
  final Uint8List nonce;
  final Uint8List ciphertext;
  final Uint8List applicationSecret;
  final int expectedGeneration;

  MlsDecryptParams({
    required this.epoch,
    required this.senderIndex,
    required this.nonce,
    required this.ciphertext,
    required this.applicationSecret,
    required this.expectedGeneration,
  });

  Map<String, dynamic> toJson() => {
        'epoch': epoch,
        'senderIndex': senderIndex,
        'nonce': nonce.toList(),
        'ciphertext': ciphertext.toList(),
        'applicationSecret': applicationSecret.toList(),
        'expectedGeneration': expectedGeneration,
      };

  factory MlsDecryptParams.fromJson(Map<String, dynamic> json) =>
      MlsDecryptParams(
        epoch: json['epoch'] as int,
        senderIndex: json['senderIndex'] as int,
        nonce: Uint8List.fromList(List<int>.from(json['nonce'] as List)),
        ciphertext:
            Uint8List.fromList(List<int>.from(json['ciphertext'] as List)),
        applicationSecret:
            Uint8List.fromList(List<int>.from(json['applicationSecret'] as List)),
        expectedGeneration: json['expectedGeneration'] as int,
      );
}

/// Result of MLS decryption
class MlsDecryptResult {
  final Uint8List? plaintext;
  final int? usedGeneration;
  final String? error;

  MlsDecryptResult({this.plaintext, this.usedGeneration, this.error});

  bool get success => plaintext != null && error == null;

  Map<String, dynamic> toJson() => {
        'plaintext': plaintext?.toList(),
        'usedGeneration': usedGeneration,
        'error': error,
      };

  factory MlsDecryptResult.fromJson(Map<String, dynamic> json) =>
      MlsDecryptResult(
        plaintext: json['plaintext'] != null
            ? Uint8List.fromList(List<int>.from(json['plaintext'] as List))
            : null,
        usedGeneration: json['usedGeneration'] as int?,
        error: json['error'] as String?,
      );
}

/// Input parameters for MLS encryption in isolate
class MlsEncryptParams {
  final Uint8List plaintext;
  final Uint8List applicationSecret;
  final int senderIndex;
  final int generation;

  MlsEncryptParams({
    required this.plaintext,
    required this.applicationSecret,
    required this.senderIndex,
    required this.generation,
  });

  Map<String, dynamic> toJson() => {
        'plaintext': plaintext.toList(),
        'applicationSecret': applicationSecret.toList(),
        'senderIndex': senderIndex,
        'generation': generation,
      };

  factory MlsEncryptParams.fromJson(Map<String, dynamic> json) =>
      MlsEncryptParams(
        plaintext: Uint8List.fromList(List<int>.from(json['plaintext'] as List)),
        applicationSecret:
            Uint8List.fromList(List<int>.from(json['applicationSecret'] as List)),
        senderIndex: json['senderIndex'] as int,
        generation: json['generation'] as int,
      );
}

/// Result of MLS encryption
class MlsEncryptResult {
  final Uint8List? nonce;
  final Uint8List? ciphertext;
  final String? error;

  MlsEncryptResult({this.nonce, this.ciphertext, this.error});

  bool get success => nonce != null && ciphertext != null && error == null;

  Map<String, dynamic> toJson() => {
        'nonce': nonce?.toList(),
        'ciphertext': ciphertext?.toList(),
        'error': error,
      };

  factory MlsEncryptResult.fromJson(Map<String, dynamic> json) =>
      MlsEncryptResult(
        nonce: json['nonce'] != null
            ? Uint8List.fromList(List<int>.from(json['nonce'] as List))
            : null,
        ciphertext: json['ciphertext'] != null
            ? Uint8List.fromList(List<int>.from(json['ciphertext'] as List))
            : null,
        error: json['error'] as String?,
      );
}

/// Parameters for batch decryption of multiple messages
class MlsBatchDecryptParams {
  final List<MlsDecryptParams> messages;

  MlsBatchDecryptParams({required this.messages});

  Map<String, dynamic> toJson() => {
        'messages': messages.map((m) => m.toJson()).toList(),
      };

  factory MlsBatchDecryptParams.fromJson(Map<String, dynamic> json) =>
      MlsBatchDecryptParams(
        messages: (json['messages'] as List)
            .map((m) => MlsDecryptParams.fromJson(m as Map<String, dynamic>))
            .toList(),
      );
}

/// Result of batch decryption
class MlsBatchDecryptResult {
  final List<MlsDecryptResult> results;

  MlsBatchDecryptResult({required this.results});

  Map<String, dynamic> toJson() => {
        'results': results.map((r) => r.toJson()).toList(),
      };

  factory MlsBatchDecryptResult.fromJson(Map<String, dynamic> json) =>
      MlsBatchDecryptResult(
        results: (json['results'] as List)
            .map((r) => MlsDecryptResult.fromJson(r as Map<String, dynamic>))
            .toList(),
      );
}

/// Static methods for MLS crypto operations that can run in isolates.
/// These are designed to be used with Flutter's compute() function.
class MlsCryptoIsolate {
  /// Decrypt a single message in an isolate
  /// Top-level function for compute()
  static Future<Map<String, dynamic>> decryptInIsolate(
      Map<String, dynamic> paramsJson) async {
    final params = MlsDecryptParams.fromJson(paramsJson);
    final result = await _decryptMessage(params);
    return result.toJson();
  }

  /// Encrypt a single message in an isolate
  /// Top-level function for compute()
  static Future<Map<String, dynamic>> encryptInIsolate(
      Map<String, dynamic> paramsJson) async {
    final params = MlsEncryptParams.fromJson(paramsJson);
    final result = await _encryptMessage(params);
    return result.toJson();
  }

  /// Decrypt multiple messages in batch in an isolate
  /// More efficient than calling compute() for each message
  static Future<Map<String, dynamic>> batchDecryptInIsolate(
      Map<String, dynamic> paramsJson) async {
    final params = MlsBatchDecryptParams.fromJson(paramsJson);
    final results = <MlsDecryptResult>[];

    for (final msg in params.messages) {
      final result = await _decryptMessage(msg);
      results.add(result);
    }

    return MlsBatchDecryptResult(results: results).toJson();
  }

  /// Internal decrypt implementation
  static Future<MlsDecryptResult> _decryptMessage(
      MlsDecryptParams params) async {
    try {
      // Create crypto provider fresh in isolate
      final crypto = DefaultMlsCryptoProvider();
      final keySchedule = KeySchedule(crypto.kdf);
      final aad = Uint8List(0);

      // Try decrypting with expected generation and nearby generations
      final generationsToTry = [
        params.expectedGeneration,
        params.expectedGeneration + 1,
        params.expectedGeneration + 2,
        params.expectedGeneration - 1,
        params.expectedGeneration - 2,
      ].where((g) => g >= 0).toSet().toList()
        ..sort();

      for (final generation in generationsToTry) {
        try {
          // Derive application keys for this generation
          final keyMaterial = await keySchedule.deriveApplicationKeys(
            applicationSecret: params.applicationSecret,
            senderIndex: params.senderIndex,
            generation: generation,
          );

          // Verify nonce matches
          if (keyMaterial.nonce.toString() != params.nonce.toString()) {
            continue;
          }

          // Try to decrypt
          final decrypted = await crypto.aead.open(
            key: keyMaterial.key,
            nonce: params.nonce,
            ciphertext: params.ciphertext,
            aad: aad,
          );

          return MlsDecryptResult(
            plaintext: decrypted,
            usedGeneration: generation,
          );
        } catch (e) {
          // Continue to next generation
          continue;
        }
      }

      return MlsDecryptResult(
          error: 'Failed to decrypt with any generation');
    } catch (e) {
      return MlsDecryptResult(error: e.toString());
    }
  }

  /// Internal encrypt implementation
  static Future<MlsEncryptResult> _encryptMessage(
      MlsEncryptParams params) async {
    try {
      // Create crypto provider fresh in isolate
      final crypto = DefaultMlsCryptoProvider();
      final keySchedule = KeySchedule(crypto.kdf);
      final aad = Uint8List(0);

      // Derive application keys
      final keyMaterial = await keySchedule.deriveApplicationKeys(
        applicationSecret: params.applicationSecret,
        senderIndex: params.senderIndex,
        generation: params.generation,
      );

      // Encrypt with AEAD
      final ciphertext = await crypto.aead.seal(
        key: keyMaterial.key,
        nonce: keyMaterial.nonce,
        plaintext: params.plaintext,
        aad: aad,
      );

      return MlsEncryptResult(
        nonce: keyMaterial.nonce,
        ciphertext: ciphertext,
      );
    } catch (e) {
      return MlsEncryptResult(error: e.toString());
    }
  }
}

/// High-level API for running MLS crypto in background isolate
class MlsCryptoBackground {
  /// Decrypt a message using compute()
  static Future<MlsDecryptResult> decrypt({
    required int epoch,
    required int senderIndex,
    required Uint8List nonce,
    required Uint8List ciphertext,
    required Uint8List applicationSecret,
    required int expectedGeneration,
  }) async {
    final params = MlsDecryptParams(
      epoch: epoch,
      senderIndex: senderIndex,
      nonce: nonce,
      ciphertext: ciphertext,
      applicationSecret: applicationSecret,
      expectedGeneration: expectedGeneration,
    );

    final resultJson = await compute(
      MlsCryptoIsolate.decryptInIsolate,
      params.toJson(),
    );

    return MlsDecryptResult.fromJson(resultJson);
  }

  /// Encrypt a message using compute()
  static Future<MlsEncryptResult> encrypt({
    required Uint8List plaintext,
    required Uint8List applicationSecret,
    required int senderIndex,
    required int generation,
  }) async {
    final params = MlsEncryptParams(
      plaintext: plaintext,
      applicationSecret: applicationSecret,
      senderIndex: senderIndex,
      generation: generation,
    );

    final resultJson = await compute(
      MlsCryptoIsolate.encryptInIsolate,
      params.toJson(),
    );

    return MlsEncryptResult.fromJson(resultJson);
  }

  /// Decrypt multiple messages in batch using compute()
  /// More efficient than decrypting one by one
  static Future<List<MlsDecryptResult>> batchDecrypt(
      List<MlsDecryptParams> messages) async {
    if (messages.isEmpty) return [];

    final params = MlsBatchDecryptParams(messages: messages);

    final resultJson = await compute(
      MlsCryptoIsolate.batchDecryptInIsolate,
      params.toJson(),
    );

    final batchResult = MlsBatchDecryptResult.fromJson(resultJson);
    return batchResult.results;
  }
}

