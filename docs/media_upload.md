# Media Upload (Blossom Protocol)

How the app uploads media files to the relay using the [Blossom protocol](https://github.com/hzrd149/blossom) with NIP-29 group-based organization.

## Service Location

- `lib/services/media/media_upload.dart` - Core upload logic (to be implemented)
- `lib/services/nostr/nostr.dart` - Nostr event signing

## Overview

The Blossom protocol provides a simple media storage mechanism where:
1. Files are identified by their SHA-256 hash
2. Authentication uses signed Nostr events (kind 24242)
3. Files are organized by NIP-29 group IDs

## Upload Flow

### 1. Calculate File Hash

Before uploading, calculate the SHA-256 hash of the file content:

```dart
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart' as crypto;

Future<String> calculateSha256(Uint8List fileBytes) async {
  final sha256 = crypto.Sha256();
  final hash = await sha256.hash(fileBytes);
  return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
```

### 2. Create Authorization Event (kind 24242)

Create and sign a Nostr event that authorizes the upload:

```dart
import 'package:dart_nostr/dart_nostr.dart';
import 'package:comunifi/services/nostr/client_signature.dart';

Future<Map<String, dynamic>> createUploadAuthEvent({
  required String sha256,
  required String groupId,
  required int fileSize,
  required NostrKeyPairs keyPairs,
}) async {
  final createdAt = DateTime.now();
  final timestamp = createdAt.millisecondsSinceEpoch ~/ 1000;
  
  // Base tags for the auth event
  final baseTags = [
    ['t', 'upload'],           // Action type
    ['x', sha256],             // File hash
    ['h', groupId],            // NIP-29 group ID
    ['size', fileSize.toString()],
  ];
  
  // Add client signature tags
  final tags = await addClientTagsWithSignature(baseTags, createdAt: createdAt);
  
  // Create and sign the event
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
```

### 3. Upload via HTTP PUT

Send the file to the relay's upload endpoint:

```dart
import 'dart:convert';
import 'dart:io';

Future<String> uploadMedia({
  required Uint8List fileBytes,
  required String mimeType,
  required String sha256,
  required String groupId,
  required NostrKeyPairs keyPairs,
  required String relayUrl,
}) async {
  // Create auth event
  final authEvent = await createUploadAuthEvent(
    sha256: sha256,
    groupId: groupId,
    fileSize: fileBytes.length,
    keyPairs: keyPairs,
  );
  
  // Encode auth event as base64
  final authJson = jsonEncode(authEvent);
  final authBase64 = base64Encode(utf8.encode(authJson));
  
  // Build upload URL (convert wss:// to https://)
  final uploadUrl = relayUrl
      .replaceFirst('wss://', 'https://')
      .replaceFirst('ws://', 'http://');
  
  // Make HTTP PUT request
  final client = HttpClient();
  final request = await client.putUrl(Uri.parse('$uploadUrl/upload'));
  
  request.headers.set(HttpHeaders.contentTypeHeader, mimeType);
  request.headers.set(HttpHeaders.authorizationHeader, 'Nostr $authBase64');
  
  request.add(fileBytes);
  
  final response = await request.close();
  
  if (response.statusCode != 200) {
    final body = await response.transform(utf8.decoder).join();
    throw Exception('Upload failed: ${response.statusCode} - $body');
  }
  
  // Parse response to get blob URL
  final responseBody = await response.transform(utf8.decoder).join();
  final result = jsonDecode(responseBody);
  
  return result['url'] as String;
}
```

### 4. Retrieve the Blob

Access uploaded files via their hash:

```
GET https://your-relay.com/{sha256}
GET https://your-relay.com/{sha256}.jpg  // with extension hint
```

## Complete Upload Service Example

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as crypto;
import 'package:dart_nostr/dart_nostr.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

import 'package:comunifi/services/nostr/client_signature.dart';

/// Service for uploading media files using the Blossom protocol
class MediaUploadService {
  static const int maxFileSize = 50 * 1024 * 1024; // 50MB
  
  /// Upload a media file to the relay
  /// 
  /// Returns the URL of the uploaded blob
  Future<String> upload({
    required Uint8List fileBytes,
    required String mimeType,
    required String groupId,
    required NostrKeyPairs keyPairs,
  }) async {
    // Validate file size
    if (fileBytes.length > maxFileSize) {
      throw Exception('File exceeds maximum size of 50MB');
    }
    
    // Calculate SHA-256 hash
    final sha256 = await _calculateHash(fileBytes);
    debugPrint('MediaUpload: File hash: $sha256');
    
    // Create authorization event
    final authEvent = await _createAuthEvent(
      sha256: sha256,
      groupId: groupId,
      fileSize: fileBytes.length,
      keyPairs: keyPairs,
    );
    
    // Upload the file
    final url = await _uploadFile(
      fileBytes: fileBytes,
      mimeType: mimeType,
      authEvent: authEvent,
    );
    
    debugPrint('MediaUpload: Upload complete: $url');
    return url;
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
    
    final baseTags = [
      ['t', 'upload'],
      ['x', sha256],
      ['h', groupId],
      ['size', fileSize.toString()],
    ];
    
    final tags = await addClientTagsWithSignature(baseTags, createdAt: createdAt);
    
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
    
    // Convert WebSocket URL to HTTP URL
    final baseUrl = relayUrl
        .replaceFirst('wss://', 'https://')
        .replaceFirst('ws://', 'http://');
    
    // Encode auth event
    final authJson = jsonEncode(authEvent);
    final authBase64 = base64Encode(utf8.encode(authJson));
    
    // Make request
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 30);
    
    try {
      final request = await client.putUrl(Uri.parse('$baseUrl/upload'));
      
      request.headers.set(HttpHeaders.contentTypeHeader, mimeType);
      request.headers.set(HttpHeaders.authorizationHeader, 'Nostr $authBase64');
      
      request.add(fileBytes);
      
      final response = await request.close();
      final responseBody = await response.transform(utf8.decoder).join();
      
      if (response.statusCode != 200) {
        throw Exception('Upload failed: ${response.statusCode} - $responseBody');
      }
      
      final result = jsonDecode(responseBody) as Map<String, dynamic>;
      return result['url'] as String;
    } finally {
      client.close();
    }
  }
}
```

## Auth Event Tags

| Tag | Required | Description |
|-----|----------|-------------|
| `t` | Yes | Action type: `upload`, `get`, `list`, or `delete` |
| `x` | Yes | SHA-256 hash of the file |
| `expiration` | **Yes** | Unix timestamp when auth expires (e.g., 5 min from now) |
| `h` | For groups | NIP-29 group ID - stores under group folder |
| `size` | No | File size hint |
| `client` | Auto | Added by `addClientTagsWithSignature()` |
| `client_sig` | Auto | Added by `addClientTagsWithSignature()` |

> ⚠️ **Important**: The `expiration` tag is **required** by the relay. Without it, uploads will fail with a 404 error.

## Validation

The relay validates uploads against:

1. **Authentication**: The signed Nostr event proves the user's identity
2. **Group membership**: If `h` tag is present, verifies the pubkey is a member of that NIP-29 group
3. **File size**: Must be under **50MB**
4. **Hash match**: The uploaded file's hash must match the `x` tag

## Storage Location

Files are stored in S3 based on the `h` tag:

- **With group ID**: `s3://bucket/blobs/{groupId}/{sha256}`
- **Without group ID**: `s3://bucket/blobs/{sha256}`

## Usage in State Providers

### From GroupState

```dart
// In lib/state/group.dart

Future<String> uploadImage(Uint8List imageBytes, String mimeType) async {
  if (_activeGroupId == null || _keyPairs == null) {
    throw Exception('No active group or not authenticated');
  }
  
  final uploadService = MediaUploadService();
  
  return await uploadService.upload(
    fileBytes: imageBytes,
    mimeType: mimeType,
    groupId: _activeGroupId!,
    keyPairs: _keyPairs!,
  );
}
```

### From a Post Screen

```dart
// Example: Uploading an image before posting

Future<void> _handleImagePost(Uint8List imageBytes) async {
  final groupState = context.read<GroupState>();
  
  // Upload the image
  final imageUrl = await groupState.uploadImage(
    imageBytes,
    'image/jpeg',
  );
  
  // Create post content with image URL
  final content = 'Check out this image: $imageUrl';
  
  // Post the message
  await groupState.postMessage(content);
}
```

## Other Operations

### List User's Blobs

```dart
Future<List<Map<String, dynamic>>> listBlobs({
  required String pubkey,
  required NostrKeyPairs keyPairs,
}) async {
  final createdAt = DateTime.now();
  
  final tags = await addClientTagsWithSignature(
    [['t', 'list']],
    createdAt: createdAt,
  );
  
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
  final request = await client.getUrl(Uri.parse('$relayUrl/list/$pubkey'));
  request.headers.set(HttpHeaders.authorizationHeader, 'Nostr $authBase64');
  
  final response = await request.close();
  final responseBody = await response.transform(utf8.decoder).join();
  
  return List<Map<String, dynamic>>.from(jsonDecode(responseBody));
}
```

### Delete a Blob

```dart
Future<void> deleteBlob({
  required String sha256,
  required NostrKeyPairs keyPairs,
}) async {
  final createdAt = DateTime.now();
  
  final tags = await addClientTagsWithSignature(
    [
      ['t', 'delete'],
      ['x', sha256],
    ],
    createdAt: createdAt,
  );
  
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
  final request = await client.deleteUrl(Uri.parse('$relayUrl/$sha256'));
  request.headers.set(HttpHeaders.authorizationHeader, 'Nostr $authBase64');
  
  final response = await request.close();
  
  if (response.statusCode != 200) {
    final body = await response.transform(utf8.decoder).join();
    throw Exception('Delete failed: ${response.statusCode} - $body');
  }
}
```

## Error Handling

| Error | Cause | Solution |
|-------|-------|----------|
| `File exceeds maximum size` | File larger than 50MB | Compress or resize the image |
| `Upload failed: 401` | Invalid or expired auth event | Regenerate auth event with fresh timestamp |
| `Upload failed: 403` | Not a member of the group | Verify group membership |
| `Upload failed: 409` | Hash mismatch | Recalculate hash and retry |
| `RELAY_URL not configured` | Missing environment variable | Add `RELAY_URL` to `.env` file |

## Security Considerations

1. **Hash verification**: The relay verifies the uploaded file matches the declared hash
2. **Group isolation**: Files with a group ID are only accessible to group members
3. **Signed authentication**: All operations require a valid Nostr signature
4. **Client identification**: `client` and `client_sig` tags prove the request came from Comunifi

## Image Handling Best Practices

1. **Compress images** before upload to reduce bandwidth and storage
2. **Generate thumbnails** client-side for previews
3. **Validate file type** before uploading (check magic bytes, not just extension)
4. **Handle upload failures** gracefully with retry logic
5. **Show upload progress** for large files using chunked uploads

## MLS Encryption for Images

Images uploaded to groups are encrypted using MLS before upload. This ensures only group members can view the images.

### How It Works

1. **Upload Flow**:
   - Image bytes are encrypted using `MlsGroup.encryptApplicationMessage()`
   - The resulting `MlsCiphertext` is serialized to bytes
   - Encrypted bytes are uploaded as `application/octet-stream`
   - The `imeta` tag includes `encrypted mls` flag and SHA-256 hash

2. **Download/Display Flow**:
   - `EncryptedImage` widget detects encrypted images via `imeta` tag
   - Downloads the encrypted blob from the URL
   - Deserializes and decrypts using the active group's MLS
   - Caches decrypted image locally (keyed by SHA-256 hash)
   - Displays from local file via `Image.file()`

### imeta Tag Format

For encrypted images:
```
['imeta', 'url <url>', 'x <sha256>', 'encrypted mls']
```

For non-encrypted images (profile photos, etc.):
```
['imeta', 'url <url>']
```

### Key Files

- `lib/services/media/encrypted_media.dart` - Encryption/decryption/caching service
- `lib/services/media/media_upload.dart` - Upload service with optional MLS encryption
- `lib/widgets/encrypted_image.dart` - Widget for displaying encrypted images
- `lib/models/nostr_event.dart` - `EventImageInfo` model for parsing imeta tags

### Cache Location

Decrypted images are cached at:
```
{app_documents}/encrypted_media_cache/{sha256}
```

## Future Improvements

- [ ] Add upload progress callbacks
- [ ] Implement image compression before upload
- [ ] Add retry logic with exponential backoff
- [ ] Support for resumable uploads
- [ ] Client-side thumbnail generation
- [ ] Tor support for uploads (via SOCKS proxy)
- [x] MLS encryption for images
- [ ] Cache cleanup (LRU or time-based eviction)

