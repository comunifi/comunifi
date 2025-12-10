import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:cryptography/cryptography.dart' as crypto;
import 'package:dart_nostr/dart_nostr.dart';
import 'package:flutter/foundation.dart';

// =============================================================================
// WhatsApp Chat Export Import Service
// =============================================================================
//
// This service handles importing WhatsApp chat exports into ComuniFi groups.
//
// ## WhatsApp Export Format
//
// WhatsApp exports chats as a .zip file containing:
// - `_chat.txt` - The chat history in a specific text format
// - Attachment files (photos, videos, audio, documents)
//
// ## Message Format
//
// Messages in `_chat.txt` follow this format:
// ```
// [M/D/YY, H:MM:SS AM/PM] Author Name: Message content
// [8/20/19, 3:11:37 AM] Kevin: Hello world
// [8/20/19, 3:11:37 AM] Kevin: ‎<attached: 00000065-PHOTO-2019-08-23-16-44-10.jpg>
// ```
//
// ## Import Process
//
// 1. User selects a WhatsApp export .zip file
// 2. Service parses the `_chat.txt` to extract messages
// 3. For each unique author, a deterministic throwaway key is generated
// 4. Messages are imported chronologically with 'imported' tags
// 5. Attachments are uploaded with MLS encryption
//
// ## Imported Message Tags
//
// Imported posts include these tags for identification:
// - `['imported', 'whatsapp']` - Marks the post as imported from WhatsApp
// - `['imported_author', 'Kevin']` - Original author name from WhatsApp
// - `['imported_time', '1566280297']` - Original message Unix timestamp
//
// ## Performance
//
// Heavy operations (zip decoding, parsing) run in isolates via `compute()`
// to avoid blocking the main UI thread.
//
// =============================================================================

/// Represents a single message parsed from a WhatsApp chat export.
///
/// Each message contains:
/// - [timestamp] - When the message was originally sent
/// - [author] - The name of the person who sent it (as shown in WhatsApp)
/// - [content] - The text content of the message
/// - [attachmentFilename] - Optional filename if the message had an attachment
///
/// Example:
/// ```dart
/// final message = WhatsAppMessage(
///   timestamp: DateTime(2019, 8, 20, 3, 11, 37),
///   author: 'Kevin',
///   content: 'Hello world',
///   attachmentFilename: null,
/// );
/// ```
class WhatsAppMessage {
  /// The timestamp when the message was originally sent in WhatsApp.
  final DateTime timestamp;

  /// The author's display name as it appeared in WhatsApp.
  /// This is used to generate a deterministic throwaway key for attribution.
  final String author;

  /// The text content of the message.
  /// For attachment-only messages, this will be '[Attachment]'.
  final String content;

  /// The filename of an attached file, if any.
  /// Example: '00000065-PHOTO-2019-08-23-16-44-10.jpg'
  final String? attachmentFilename;

  const WhatsAppMessage({
    required this.timestamp,
    required this.author,
    required this.content,
    this.attachmentFilename,
  });

  /// Whether this message has an attachment file.
  bool get hasAttachment => attachmentFilename != null;

  @override
  String toString() {
    final preview = content.length > 50
        ? '${content.substring(0, 50)}...'
        : content;
    return 'WhatsAppMessage($author at $timestamp: $preview)';
  }

  /// Convert to a Map for isolate communication.
  Map<String, dynamic> toMap() => {
    'timestamp': timestamp.millisecondsSinceEpoch,
    'author': author,
    'content': content,
    'attachmentFilename': attachmentFilename,
  };

  /// Create from a Map (for isolate communication).
  factory WhatsAppMessage.fromMap(Map<String, dynamic> map) => WhatsAppMessage(
    timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
    author: map['author'] as String,
    content: map['content'] as String,
    attachmentFilename: map['attachmentFilename'] as String?,
  );
}

/// Result of parsing a WhatsApp export file.
///
/// Contains:
/// - [messages] - All parsed messages in chronological order (oldest first)
/// - [authors] - Set of unique author names found in the chat
/// - [messageCountByAuthor] - How many messages each author sent
///
/// Example:
/// ```dart
/// final result = await service.parseExport(zipBytes);
/// print('Found ${result.messages.length} messages');
/// print('Authors: ${result.authors.join(", ")}');
/// for (final author in result.authors) {
///   print('$author: ${result.messageCountByAuthor[author]} messages');
/// }
/// ```
class WhatsAppExportResult {
  /// All messages parsed from the export, sorted chronologically (oldest first).
  final List<WhatsAppMessage> messages;

  /// Set of unique author names found in the chat.
  final Set<String> authors;

  /// Map of author name to message count.
  final Map<String, int> messageCountByAuthor;

  const WhatsAppExportResult({
    required this.messages,
    required this.authors,
    required this.messageCountByAuthor,
  });

  /// Convert to a Map for isolate communication.
  Map<String, dynamic> toMap() => {
    'messages': messages.map((m) => m.toMap()).toList(),
    'authors': authors.toList(),
    'messageCountByAuthor': messageCountByAuthor,
  };

  /// Create from a Map (for isolate communication).
  factory WhatsAppExportResult.fromMap(Map<String, dynamic> map) {
    final messagesList = (map['messages'] as List)
        .map((m) => WhatsAppMessage.fromMap(m as Map<String, dynamic>))
        .toList();
    return WhatsAppExportResult(
      messages: messagesList,
      authors: Set<String>.from(map['authors'] as List),
      messageCountByAuthor: Map<String, int>.from(
        map['messageCountByAuthor'] as Map,
      ),
    );
  }
}

// =============================================================================
// Isolate Worker Functions (Top-level for compute())
// =============================================================================

/// Parameters for the parse export isolate function.
class _ParseExportParams {
  final Uint8List zipBytes;
  const _ParseExportParams(this.zipBytes);
}

/// Parameters for the get attachment isolate function.
class _GetAttachmentParams {
  final Uint8List zipBytes;
  final String filename;
  const _GetAttachmentParams(this.zipBytes, this.filename);
}

/// Parse a WhatsApp export zip file in an isolate.
///
/// This is a top-level function that can be passed to `compute()`.
/// It handles the heavy work of:
/// 1. Decoding the zip archive
/// 2. Finding and reading the chat file
/// 3. Parsing all messages with regex
/// 4. Sorting and organizing results
Map<String, dynamic> _parseExportInIsolate(_ParseExportParams params) {
  try {
    // Decode the zip archive (CPU-intensive for large files)
    final archive = ZipDecoder().decodeBytes(params.zipBytes);

    // Find the chat file (usually _chat.txt)
    final chatFile = archive.files.firstWhere(
      (file) => file.name.endsWith('_chat.txt') || file.name.endsWith('.txt'),
      orElse: () => throw Exception('No chat file found in zip archive'),
    );

    // Decode the chat content
    final chatContent = utf8.decode(chatFile.content as List<int>);

    // Parse messages
    final result = _parseChatContentInIsolate(chatContent);

    return {'success': true, 'result': result.toMap()};
  } catch (e) {
    return {'success': false, 'error': e.toString()};
  }
}

/// Parse the chat content from _chat.txt (runs in isolate).
WhatsAppExportResult _parseChatContentInIsolate(String content) {
  // Regex to match WhatsApp message format
  final messageRegex = RegExp(
    r'^\[(\d{1,2}/\d{1,2}/\d{2,4}),\s*(\d{1,2}:\d{2}:\d{2}(?:\s*[AP]M)?)\]\s*([^:]+):\s*(.*)$',
    multiLine: true,
  );

  final attachmentRegex = RegExp(r'<attached:\s*([^>]+)>');

  final systemIndicators = [
    'Messages and calls are end-to-end encrypted',
    'created group',
    'added you',
    'removed you',
    'left',
    'changed the subject',
    'changed this group',
    'changed the group description',
    'deleted this group',
    'You were added',
    'security code changed',
  ];

  bool isSystemMessage(String author, String msgContent) {
    final combinedText = '$author: $msgContent'.toLowerCase();
    return systemIndicators.any(
      (indicator) => combinedText.contains(indicator.toLowerCase()),
    );
  }

  String cleanContent(String c) => c.trim().replaceAll(RegExp(r'\s+'), ' ');

  DateTime parseDateTime(String dateStr, String timeStr) {
    try {
      final dateParts = dateStr.split('/');
      int month, day, year;

      if (dateParts.length == 3) {
        month = int.parse(dateParts[0]);
        day = int.parse(dateParts[1]);
        year = int.parse(dateParts[2]);
        if (year < 100) year += 2000;
      } else {
        throw Exception('Invalid date format');
      }

      final timeClean = timeStr.trim().toUpperCase();
      final isPM = timeClean.contains('PM');
      final isAM = timeClean.contains('AM');
      final timeOnly = timeClean
          .replaceAll('AM', '')
          .replaceAll('PM', '')
          .trim();
      final timeParts = timeOnly.split(':');

      int hour = int.parse(timeParts[0]);
      final minute = int.parse(timeParts[1]);
      final second = timeParts.length > 2 ? int.parse(timeParts[2]) : 0;

      if (isPM && hour != 12) hour += 12;
      if (isAM && hour == 12) hour = 0;

      return DateTime(year, month, day, hour, minute, second);
    } catch (e) {
      return DateTime.now();
    }
  }

  final messages = <WhatsAppMessage>[];
  final authors = <String>{};
  final messageCountByAuthor = <String, int>{};

  final lines = content.split('\n');
  String? currentAuthor;
  String? currentContent;
  DateTime? currentTimestamp;
  String? currentAttachment;

  for (final line in lines) {
    final match = messageRegex.firstMatch(line);

    if (match != null) {
      // Save previous message
      if (currentAuthor != null &&
          currentContent != null &&
          currentTimestamp != null) {
        if (!isSystemMessage(currentAuthor, currentContent)) {
          messages.add(
            WhatsAppMessage(
              timestamp: currentTimestamp,
              author: currentAuthor.trim(),
              content: cleanContent(currentContent),
              attachmentFilename: currentAttachment,
            ),
          );
          authors.add(currentAuthor.trim());
          messageCountByAuthor[currentAuthor.trim()] =
              (messageCountByAuthor[currentAuthor.trim()] ?? 0) + 1;
        }
      }

      // Parse new message
      final dateStr = match.group(1)!;
      final timeStr = match.group(2)!;
      currentAuthor = match.group(3)!;
      currentContent = match.group(4)!;
      currentTimestamp = parseDateTime(dateStr, timeStr);

      // Check for attachment
      final attachmentMatch = attachmentRegex.firstMatch(currentContent);
      if (attachmentMatch != null) {
        currentAttachment = attachmentMatch.group(1)?.trim();
        currentContent = currentContent.replaceAll(attachmentRegex, '').trim();
        if (currentContent.isEmpty) currentContent = '[Attachment]';
      } else {
        currentAttachment = null;
      }
    } else if (currentContent != null && line.trim().isNotEmpty) {
      currentContent = '$currentContent\n${line.trim()}';
    }
  }

  // Don't forget the last message
  if (currentAuthor != null &&
      currentContent != null &&
      currentTimestamp != null) {
    if (!isSystemMessage(currentAuthor, currentContent)) {
      messages.add(
        WhatsAppMessage(
          timestamp: currentTimestamp,
          author: currentAuthor.trim(),
          content: cleanContent(currentContent),
          attachmentFilename: currentAttachment,
        ),
      );
      authors.add(currentAuthor.trim());
      messageCountByAuthor[currentAuthor.trim()] =
          (messageCountByAuthor[currentAuthor.trim()] ?? 0) + 1;
    }
  }

  // Sort chronologically (oldest first)
  messages.sort((a, b) => a.timestamp.compareTo(b.timestamp));

  return WhatsAppExportResult(
    messages: messages,
    authors: authors,
    messageCountByAuthor: messageCountByAuthor,
  );
}

/// Extract an attachment from the zip archive in an isolate.
///
/// Returns the file bytes or null if not found.
Uint8List? _getAttachmentInIsolate(_GetAttachmentParams params) {
  try {
    final archive = ZipDecoder().decodeBytes(params.zipBytes);

    final file = archive.files.firstWhere(
      (f) => f.name.endsWith(params.filename) || f.name == params.filename,
      orElse: () => ArchiveFile('', 0, []),
    );

    if (file.size == 0) return null;

    return Uint8List.fromList(file.content as List<int>);
  } catch (e) {
    return null;
  }
}

/// List all files in the zip archive in an isolate.
List<String> _listFilesInIsolate(Uint8List zipBytes) {
  try {
    final archive = ZipDecoder().decodeBytes(zipBytes);
    return archive.files.map((f) => f.name).toList();
  } catch (e) {
    return [];
  }
}

// =============================================================================
// WhatsApp Import Service
// =============================================================================

/// Service for importing WhatsApp chat exports into ComuniFi groups.
///
/// This service provides functionality to:
/// - Parse WhatsApp export .zip files
/// - Extract messages and attachments
/// - Generate deterministic throwaway keys for author attribution
///
/// ## Usage
///
/// ```dart
/// final service = WhatsAppImportService();
///
/// // Parse the export to preview
/// final result = await service.parseExport(zipBytes);
/// print('Found ${result.messages.length} messages from ${result.authors.length} authors');
///
/// // Extract an attachment
/// final photoBytes = await service.getAttachment(zipBytes, 'photo.jpg');
///
/// // Generate a throwaway key for an author
/// final keyPair = await service.generateThrowawayKey('Kevin', groupIdHex);
/// ```
///
/// ## Performance
///
/// Heavy operations like zip decoding and message parsing run in isolates
/// via `compute()` to keep the UI responsive during large imports.
class WhatsAppImportService {
  /// Parse a WhatsApp export zip file.
  ///
  /// The zip should contain a `_chat.txt` file with the chat history.
  /// Attachments (photos, videos, etc.) should be in the same zip.
  ///
  /// This operation runs in an isolate to avoid blocking the UI thread,
  /// as zip decoding and message parsing can be CPU-intensive for large exports.
  ///
  /// Returns a [WhatsAppExportResult] containing:
  /// - All messages sorted chronologically (oldest first)
  /// - Set of unique author names
  /// - Message count per author
  ///
  /// Throws an [Exception] if:
  /// - The zip cannot be decoded
  /// - No `_chat.txt` file is found
  ///
  /// Example:
  /// ```dart
  /// final zipBytes = await file.readAsBytes();
  /// final result = await service.parseExport(zipBytes);
  /// print('Found ${result.messages.length} messages');
  /// ```
  Future<WhatsAppExportResult> parseExport(Uint8List zipBytes) async {
    debugPrint(
      'WhatsAppImport: Starting parse in isolate (${zipBytes.length} bytes)',
    );

    // Run heavy parsing in isolate
    final resultMap = await compute(
      _parseExportInIsolate,
      _ParseExportParams(zipBytes),
    );

    if (resultMap['success'] != true) {
      throw Exception(resultMap['error'] ?? 'Failed to parse WhatsApp export');
    }

    final result = WhatsAppExportResult.fromMap(
      resultMap['result'] as Map<String, dynamic>,
    );

    debugPrint(
      'WhatsAppImport: Parsed ${result.messages.length} messages from ${result.authors.length} authors',
    );

    return result;
  }

  /// Extract an attachment file from the zip archive.
  ///
  /// WhatsApp includes attachments in the export zip with filenames like:
  /// - `00000065-PHOTO-2019-08-23-16-44-10.jpg`
  /// - `00000066-VIDEO-2019-08-24-12-30-45.mp4`
  /// - `00000067-AUDIO-2019-08-25-09-15-00.opus`
  ///
  /// This operation runs in an isolate as zip decoding can be slow.
  ///
  /// [zipBytes] - The raw bytes of the WhatsApp export .zip file
  /// [filename] - The attachment filename to extract
  ///
  /// Returns the file bytes, or `null` if the file is not found.
  ///
  /// Example:
  /// ```dart
  /// final photoBytes = await service.getAttachment(
  ///   zipBytes,
  ///   '00000065-PHOTO-2019-08-23-16-44-10.jpg',
  /// );
  /// if (photoBytes != null) {
  ///   // Upload or process the photo
  /// }
  /// ```
  Future<Uint8List?> getAttachment(Uint8List zipBytes, String filename) async {
    debugPrint('WhatsAppImport: Extracting attachment "$filename" in isolate');

    final result = await compute(
      _getAttachmentInIsolate,
      _GetAttachmentParams(zipBytes, filename),
    );

    if (result != null) {
      debugPrint(
        'WhatsAppImport: Extracted "$filename" (${result.length} bytes)',
      );
    } else {
      debugPrint('WhatsAppImport: Attachment not found: "$filename"');
    }

    return result;
  }

  /// List all files in the zip archive.
  ///
  /// Useful for debugging or displaying the export contents.
  /// Runs in an isolate for large archives.
  ///
  /// Returns a list of file paths within the zip.
  ///
  /// Example:
  /// ```dart
  /// final files = await service.listFiles(zipBytes);
  /// for (final file in files) {
  ///   print('  - $file');
  /// }
  /// ```
  Future<List<String>> listFiles(Uint8List zipBytes) async {
    return await compute(_listFilesInIsolate, zipBytes);
  }

  /// Generate a deterministic throwaway keypair for an author.
  ///
  /// This creates a Nostr keypair that is:
  /// - **Deterministic**: Same author name + group ID always produces the same key
  /// - **Unique per group**: Same author in different groups gets different keys
  /// - **Not tied to real identity**: These are "throwaway" keys for attribution only
  ///
  /// The key is derived by hashing: `"whatsapp_import:{groupIdHex}:{authorName}"`
  ///
  /// [authorName] - The author's display name from WhatsApp
  /// [groupIdHex] - The hex-encoded group ID where messages are being imported
  ///
  /// Returns a [NostrKeyPairs] that can be used to sign imported messages.
  ///
  /// Example:
  /// ```dart
  /// final keyPair = await service.generateThrowawayKey('Kevin', groupIdHex);
  /// print('Throwaway pubkey for Kevin: ${keyPair.public}');
  /// ```
  Future<NostrKeyPairs> generateThrowawayKey(
    String authorName,
    String groupIdHex,
  ) async {
    // Create deterministic seed from author name + group ID
    final seedString = 'whatsapp_import:$groupIdHex:$authorName';
    final seedBytes = utf8.encode(seedString);

    // Hash to create a 32-byte private key
    final sha256 = crypto.Sha256();
    final hash = await sha256.hash(seedBytes);
    final privateKeyHex = hash.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();

    // Create NostrKeyPairs from the deterministic private key
    return NostrKeyPairs(private: privateKeyHex);
  }

  /// Get the MIME type for an attachment based on its filename extension.
  ///
  /// Supports common media types found in WhatsApp exports:
  /// - Images: jpg, jpeg, png, gif, webp
  /// - Videos: mp4, mov
  /// - Audio: mp3, ogg, opus
  /// - Documents: pdf
  ///
  /// Returns 'application/octet-stream' for unknown extensions.
  ///
  /// Example:
  /// ```dart
  /// final mimeType = service.getMimeType('photo.jpg');
  /// print(mimeType); // 'image/jpeg'
  /// ```
  String getMimeType(String filename) {
    final ext = filename.toLowerCase().split('.').last;
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      case 'mp4':
        return 'video/mp4';
      case 'mov':
        return 'video/quicktime';
      case 'mp3':
        return 'audio/mpeg';
      case 'ogg':
        return 'audio/ogg';
      case 'opus':
        return 'audio/opus';
      case 'pdf':
        return 'application/pdf';
      default:
        return 'application/octet-stream';
    }
  }
}
