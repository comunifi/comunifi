import 'dart:io';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'package:comunifi/services/mls/mls_group.dart';
import 'package:comunifi/services/mls/messages/messages.dart';
import 'package:comunifi/services/mls/group_state/group_state.dart';

/// Result of encrypting media
class EncryptedMediaResult {
  /// The encrypted bytes ready to upload
  final Uint8List encryptedBytes;

  /// The MLS group ID used for encryption (hex string)
  final String groupIdHex;

  /// The epoch at which encryption occurred
  final int epoch;

  /// The sender's leaf index
  final int senderIndex;

  const EncryptedMediaResult({
    required this.encryptedBytes,
    required this.groupIdHex,
    required this.epoch,
    required this.senderIndex,
  });
}

/// Service for encrypting and decrypting media files using MLS
class EncryptedMediaService {
  /// Directory name for cached decrypted images
  static const String _cacheDir = 'encrypted_media_cache';

  /// Encrypt media bytes using the group's MLS encryption
  ///
  /// Returns [EncryptedMediaResult] containing encrypted bytes and metadata
  Future<EncryptedMediaResult> encryptMedia(
    Uint8List plainBytes,
    MlsGroup group,
  ) async {
    // Encrypt using MLS
    final ciphertext = await group.encryptApplicationMessage(plainBytes);

    // Serialize MlsCiphertext to bytes
    final encryptedBytes = _serializeCiphertext(ciphertext);

    // Get group ID as hex
    final groupIdHex = ciphertext.groupId.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    return EncryptedMediaResult(
      encryptedBytes: encryptedBytes,
      groupIdHex: groupIdHex,
      epoch: ciphertext.epoch,
      senderIndex: ciphertext.senderIndex,
    );
  }

  /// Decrypt and cache media from a URL
  ///
  /// Downloads the encrypted blob, decrypts it using the MLS group,
  /// caches to local filesystem, and returns the local file path.
  ///
  /// [url] - URL of the encrypted blob
  /// [sha256] - SHA-256 hash of the encrypted blob (used as cache key)
  /// [group] - MLS group for decryption
  ///
  /// Returns the local file path of the decrypted image
  Future<String> decryptAndCacheMedia({
    required String url,
    required String sha256,
    required MlsGroup group,
  }) async {
    // Check if already cached
    final cachedPath = await getCachedPath(sha256);
    if (cachedPath != null) {
      debugPrint('EncryptedMedia: Using cached file: $cachedPath');
      return cachedPath;
    }

    debugPrint('EncryptedMedia: Downloading encrypted blob from $url');

    // Download encrypted blob
    final encryptedBytes = await _downloadBlob(url);

    // Deserialize and decrypt
    final ciphertext = _deserializeCiphertext(encryptedBytes, group.id);
    final decryptedBytes = await group.decryptApplicationMessage(ciphertext);

    debugPrint(
      'EncryptedMedia: Decrypted ${decryptedBytes.length} bytes',
    );

    // Cache to local filesystem
    final localPath = await _cacheDecryptedMedia(sha256, decryptedBytes);

    debugPrint('EncryptedMedia: Cached to $localPath');

    return localPath;
  }

  /// Check if a decrypted media file is already cached
  ///
  /// Returns the local file path if cached, null otherwise
  Future<String?> getCachedPath(String sha256) async {
    try {
      final cacheDirectory = await _getCacheDirectory();
      final filePath = '${cacheDirectory.path}/$sha256';
      final file = File(filePath);

      if (await file.exists()) {
        return filePath;
      }
      return null;
    } catch (e) {
      debugPrint('EncryptedMedia: Error checking cache: $e');
      return null;
    }
  }

  /// Clear all cached decrypted media
  Future<void> clearCache() async {
    try {
      final cacheDirectory = await _getCacheDirectory();
      if (await cacheDirectory.exists()) {
        await cacheDirectory.delete(recursive: true);
        debugPrint('EncryptedMedia: Cache cleared');
      }
    } catch (e) {
      debugPrint('EncryptedMedia: Error clearing cache: $e');
    }
  }

  /// Get cache size in bytes
  Future<int> getCacheSize() async {
    try {
      final cacheDirectory = await _getCacheDirectory();
      if (!await cacheDirectory.exists()) {
        return 0;
      }

      int totalSize = 0;
      await for (final entity in cacheDirectory.list()) {
        if (entity is File) {
          totalSize += await entity.length();
        }
      }
      return totalSize;
    } catch (e) {
      debugPrint('EncryptedMedia: Error getting cache size: $e');
      return 0;
    }
  }

  /// Serialize MlsCiphertext to bytes for storage/upload
  ///
  /// Format:
  /// - 4 bytes: groupId length
  /// - N bytes: groupId bytes
  /// - 4 bytes: epoch
  /// - 4 bytes: senderIndex
  /// - 4 bytes: nonce length
  /// - N bytes: nonce
  /// - 4 bytes: ciphertext length
  /// - N bytes: ciphertext
  Uint8List _serializeCiphertext(MlsCiphertext ciphertext) {
    final groupIdBytes = ciphertext.groupId.bytes;

    // Calculate total length
    final totalLength = 4 +
        groupIdBytes.length +
        4 +
        4 +
        4 +
        ciphertext.nonce.length +
        4 +
        ciphertext.ciphertext.length;

    final result = Uint8List(totalLength);
    int offset = 0;

    // Group ID
    _writeInt32(result, offset, groupIdBytes.length);
    offset += 4;
    result.setRange(offset, offset + groupIdBytes.length, groupIdBytes);
    offset += groupIdBytes.length;

    // Epoch
    _writeInt32(result, offset, ciphertext.epoch);
    offset += 4;

    // Sender index
    _writeInt32(result, offset, ciphertext.senderIndex);
    offset += 4;

    // Nonce
    _writeInt32(result, offset, ciphertext.nonce.length);
    offset += 4;
    result.setRange(
      offset,
      offset + ciphertext.nonce.length,
      ciphertext.nonce,
    );
    offset += ciphertext.nonce.length;

    // Ciphertext
    _writeInt32(result, offset, ciphertext.ciphertext.length);
    offset += 4;
    result.setRange(
      offset,
      offset + ciphertext.ciphertext.length,
      ciphertext.ciphertext,
    );

    return result;
  }

  /// Deserialize bytes back to MlsCiphertext
  MlsCiphertext _deserializeCiphertext(Uint8List bytes, GroupId groupId) {
    int offset = 0;

    // Group ID (we skip it and use the provided one for verification)
    final groupIdLength = _readInt32(bytes, offset);
    offset += 4 + groupIdLength;

    // Epoch
    final epoch = _readInt32(bytes, offset);
    offset += 4;

    // Sender index
    final senderIndex = _readInt32(bytes, offset);
    offset += 4;

    // Nonce
    final nonceLength = _readInt32(bytes, offset);
    offset += 4;
    final nonce = Uint8List.fromList(
      bytes.sublist(offset, offset + nonceLength),
    );
    offset += nonceLength;

    // Ciphertext
    final ciphertextLength = _readInt32(bytes, offset);
    offset += 4;
    final ciphertext = Uint8List.fromList(
      bytes.sublist(offset, offset + ciphertextLength),
    );

    return MlsCiphertext(
      groupId: groupId,
      epoch: epoch,
      senderIndex: senderIndex,
      nonce: nonce,
      ciphertext: ciphertext,
      contentType: MlsContentType.application,
    );
  }

  /// Write a 32-bit integer in big-endian format
  void _writeInt32(Uint8List buffer, int offset, int value) {
    buffer[offset] = (value >> 24) & 0xFF;
    buffer[offset + 1] = (value >> 16) & 0xFF;
    buffer[offset + 2] = (value >> 8) & 0xFF;
    buffer[offset + 3] = value & 0xFF;
  }

  /// Read a 32-bit integer in big-endian format
  int _readInt32(Uint8List buffer, int offset) {
    return (buffer[offset] << 24) |
        (buffer[offset + 1] << 16) |
        (buffer[offset + 2] << 8) |
        buffer[offset + 3];
  }

  /// Download a blob from URL
  Future<Uint8List> _downloadBlob(String url) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);

    try {
      final request = await client.getUrl(Uri.parse(url));
      final response = await request.close();

      if (response.statusCode != 200) {
        throw Exception(
          'Failed to download blob: ${response.statusCode}',
        );
      }

      final bytes = await consolidateHttpClientResponseBytes(response);
      return bytes;
    } finally {
      client.close();
    }
  }

  /// Cache decrypted media to local filesystem
  Future<String> _cacheDecryptedMedia(
    String sha256,
    Uint8List decryptedBytes,
  ) async {
    final cacheDirectory = await _getCacheDirectory();

    // Ensure cache directory exists
    if (!await cacheDirectory.exists()) {
      await cacheDirectory.create(recursive: true);
    }

    final filePath = '${cacheDirectory.path}/$sha256';
    final file = File(filePath);
    await file.writeAsBytes(decryptedBytes);

    return filePath;
  }

  /// Get the cache directory for decrypted media
  Future<Directory> _getCacheDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    return Directory('${appDir.path}/$_cacheDir');
  }
}

/// Calculate SHA-256 hash of bytes and return as hex string
Future<String> calculateSha256Hex(Uint8List bytes) async {
  final sha256 = crypto.Sha256();
  final hash = await sha256.hash(bytes);
  return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

