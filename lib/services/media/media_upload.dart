import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:dart_nostr/dart_nostr.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'package:comunifi/services/nostr/client_signature.dart';
import 'package:comunifi/services/media/encrypted_media.dart';
import 'package:comunifi/services/mls/mls_group.dart';

/// Result of a successful media upload
class MediaUploadResult {
  final String url;
  final String sha256;
  final int size;
  final String mimeType;

  /// Whether the uploaded content is MLS encrypted
  final bool isEncrypted;

  const MediaUploadResult({
    required this.url,
    required this.sha256,
    required this.size,
    required this.mimeType,
    this.isEncrypted = false,
  });
}

/// Service for uploading media files using the Blossom protocol
class MediaUploadService {
  static const int maxFileSize = 50 * 1024 * 1024; // 50MB

  final EncryptedMediaService _encryptedMediaService = EncryptedMediaService();

  /// Upload a media file to the relay
  ///
  /// If [mlsGroup] is provided, the file will be encrypted using MLS before upload.
  /// The [isEncrypted] flag in the result will be true for encrypted uploads.
  ///
  /// Returns a [MediaUploadResult] containing the URL and metadata
  Future<MediaUploadResult> upload({
    required Uint8List fileBytes,
    required String mimeType,
    required String groupId,
    required NostrKeyPairs keyPairs,
    MlsGroup? mlsGroup,
  }) async {
    // Validate file size
    if (fileBytes.length > maxFileSize) {
      throw Exception('File exceeds maximum size of 50MB');
    }

    Uint8List bytesToUpload = fileBytes;
    bool isEncrypted = false;

    // Encrypt if MLS group is provided
    if (mlsGroup != null) {
      debugPrint('MediaUpload: Encrypting with MLS before upload');
      final encryptResult = await _encryptedMediaService.encryptMedia(
        fileBytes,
        mlsGroup,
      );
      bytesToUpload = encryptResult.encryptedBytes;
      isEncrypted = true;
      debugPrint(
        'MediaUpload: Encrypted ${fileBytes.length} -> ${bytesToUpload.length} bytes',
      );
    }

    // Calculate SHA-256 hash of the bytes being uploaded (encrypted or plain)
    final sha256 = await _calculateHash(bytesToUpload);
    debugPrint(
      'MediaUpload: File hash: $sha256 (${bytesToUpload.length} bytes)',
    );

    // Create authorization event
    final authEvent = await _createAuthEvent(
      sha256: sha256,
      groupId: groupId,
      fileSize: bytesToUpload.length,
      keyPairs: keyPairs,
    );

    // Use application/octet-stream for encrypted content
    final uploadMimeType = isEncrypted ? 'application/octet-stream' : mimeType;

    // Upload the file
    final url = await _uploadFile(
      fileBytes: bytesToUpload,
      mimeType: uploadMimeType,
      authEvent: authEvent,
    );

    debugPrint('MediaUpload: Upload complete: $url (encrypted: $isEncrypted)');

    return MediaUploadResult(
      url: url,
      sha256: sha256,
      size: bytesToUpload.length,
      mimeType: mimeType,
      isEncrypted: isEncrypted,
    );
  }

  /// Calculate SHA-256 hash of file bytes
  Future<String> _calculateHash(Uint8List fileBytes) async {
    final sha256 = crypto.Sha256();
    final hash = await sha256.hash(fileBytes);
    return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Create a signed authorization event (kind 24242)
  Future<Map<String, dynamic>> _createAuthEvent({
    required String sha256,
    required String groupId,
    required int fileSize,
    required NostrKeyPairs keyPairs,
  }) async {
    final createdAt = DateTime.now();
    final timestamp = createdAt.millisecondsSinceEpoch ~/ 1000;
    // Expiration is required by the relay - set to 5 minutes from now
    final expiration = timestamp + 300;

    final baseTags = [
      ['t', 'upload'],
      ['x', sha256],
      ['expiration', expiration.toString()], // Required!
      ['h', groupId],
      ['size', fileSize.toString()],
    ];

    final tags = await addClientTagsWithSignature(
      baseTags,
      createdAt: createdAt,
    );

    final authEvent = NostrEvent.fromPartialData(
      kind: 24242,
      content: '',
      keyPairs: keyPairs,
      tags: tags,
      createdAt: createdAt,
    );

    return {
      'id': authEvent.id,
      'pubkey': authEvent.pubkey,
      'created_at': timestamp,
      'kind': authEvent.kind,
      'tags': authEvent.tags,
      'content': authEvent.content,
      'sig': authEvent.sig,
    };
  }

  /// Upload file via HTTP PUT
  Future<String> _uploadFile({
    required Uint8List fileBytes,
    required String mimeType,
    required Map<String, dynamic> authEvent,
  }) async {
    final relayUrl = dotenv.env['RELAY_URL'];
    if (relayUrl == null) {
      throw Exception('RELAY_URL not configured');
    }

    // Convert WebSocket URL to HTTP URL and extract base (strip any path)
    final uri = Uri.parse(relayUrl);
    final scheme = uri.scheme == 'wss'
        ? 'https'
        : (uri.scheme == 'ws' ? 'http' : uri.scheme);
    final baseUrl = '$scheme://${uri.host}${uri.hasPort ? ':${uri.port}' : ''}';
    final uploadUrl = '$baseUrl/upload';

    debugPrint('MediaUpload: Uploading to $uploadUrl');
    debugPrint('mimeType: $mimeType');
    debugPrint('authEvent: $authEvent');
    debugPrint('fileBytes: ${fileBytes.length}');

    // Encode auth event
    final authJson = jsonEncode(authEvent);
    final authBase64 = base64Encode(utf8.encode(authJson));

    debugPrint('authBase64: $authBase64');

    // Make request
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);

    debugPrint('MediaUpload: Auth event: $uploadUrl');

    try {
      final request = await client.openUrl('PUT', Uri.parse(uploadUrl));

      // Disable redirect following (PUT requests can be converted to GET on redirect)
      request.followRedirects = false;

      request.headers.set(HttpHeaders.contentTypeHeader, mimeType);
      request.headers.set(HttpHeaders.authorizationHeader, 'Nostr $authBase64');
      request.headers.set(
        HttpHeaders.contentLengthHeader,
        fileBytes.length.toString(),
      );

      request.add(fileBytes);

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      debugPrint(
        'MediaUpload: PUT $uploadUrl -> ${response.statusCode}: $responseBody',
      );

      if (response.statusCode != 200) {
        throw Exception(
          'Upload failed: ${response.statusCode} - $responseBody',
        );
      }

      final result = jsonDecode(responseBody) as Map<String, dynamic>;
      return result['url'] as String;
    } finally {
      client.close();
    }
  }

  /// List blobs for a user
  Future<List<Map<String, dynamic>>> listBlobs({
    required String pubkey,
    required NostrKeyPairs keyPairs,
  }) async {
    final createdAt = DateTime.now();

    final tags = await addClientTagsWithSignature([
      ['t', 'list'],
    ], createdAt: createdAt);

    final authEvent = NostrEvent.fromPartialData(
      kind: 24242,
      content: '',
      keyPairs: keyPairs,
      tags: tags,
      createdAt: createdAt,
    );

    final authJson = jsonEncode({
      'id': authEvent.id,
      'pubkey': authEvent.pubkey,
      'created_at': createdAt.millisecondsSinceEpoch ~/ 1000,
      'kind': authEvent.kind,
      'tags': authEvent.tags,
      'content': authEvent.content,
      'sig': authEvent.sig,
    });
    final authBase64 = base64Encode(utf8.encode(authJson));

    final relayUrl = dotenv.env['RELAY_URL']!
        .replaceFirst('wss://', 'https://')
        .replaceFirst('ws://', 'http://');

    final client = HttpClient();
    try {
      final request = await client.getUrl(Uri.parse('$relayUrl/list/$pubkey'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Nostr $authBase64');

      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();

      if (response.statusCode != 200) {
        throw Exception('List failed: ${response.statusCode} - $responseBody');
      }

      return List<Map<String, dynamic>>.from(jsonDecode(responseBody));
    } finally {
      client.close();
    }
  }

  /// Delete a blob
  Future<void> deleteBlob({
    required String sha256,
    required NostrKeyPairs keyPairs,
  }) async {
    final createdAt = DateTime.now();

    final tags = await addClientTagsWithSignature([
      ['t', 'delete'],
      ['x', sha256],
    ], createdAt: createdAt);

    final authEvent = NostrEvent.fromPartialData(
      kind: 24242,
      content: '',
      keyPairs: keyPairs,
      tags: tags,
      createdAt: createdAt,
    );

    final authJson = jsonEncode({
      'id': authEvent.id,
      'pubkey': authEvent.pubkey,
      'created_at': createdAt.millisecondsSinceEpoch ~/ 1000,
      'kind': authEvent.kind,
      'tags': authEvent.tags,
      'content': authEvent.content,
      'sig': authEvent.sig,
    });
    final authBase64 = base64Encode(utf8.encode(authJson));

    final relayUrl = dotenv.env['RELAY_URL']!
        .replaceFirst('wss://', 'https://')
        .replaceFirst('ws://', 'http://');

    final client = HttpClient();
    try {
      final request = await client.deleteUrl(Uri.parse('$relayUrl/$sha256'));
      request.headers.set(HttpHeaders.authorizationHeader, 'Nostr $authBase64');

      final response = await request.close();

      if (response.statusCode != 200) {
        final body = await response.transform(utf8.decoder).join();
        throw Exception('Delete failed: ${response.statusCode} - $body');
      }
    } finally {
      client.close();
    }
  }
}
