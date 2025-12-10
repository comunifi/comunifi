import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:comunifi/services/recovery/recovery_service.dart';
import 'package:flutter/foundation.dart';

/// Callback for when a recovery link is received
typedef RecoveryLinkCallback = Future<void> Function(RecoveryPayload payload);

/// Service for handling deep links (comunifi:// URLs)
class DeepLinkService {
  static DeepLinkService? _instance;
  static DeepLinkService get instance => _instance ??= DeepLinkService._();

  DeepLinkService._();

  final AppLinks _appLinks = AppLinks();
  StreamSubscription<Uri>? _linkSubscription;

  /// Callback for recovery links
  RecoveryLinkCallback? onRecoveryLink;

  /// Pending recovery payload (if app was opened via deep link before initialized)
  RecoveryPayload? pendingRecoveryPayload;

  /// Initialize deep link handling
  Future<void> initialize() async {
    debugPrint('Initializing deep link service');

    // Handle app link if opened via deep link
    try {
      final initialLink = await _appLinks.getInitialLink();
      if (initialLink != null) {
        debugPrint('App opened with initial link: $initialLink');
        await _handleUri(initialLink);
      }
    } catch (e) {
      debugPrint('Error getting initial link: $e');
    }

    // Listen for incoming links while app is running
    _linkSubscription = _appLinks.uriLinkStream.listen(
      _handleUri,
      onError: (e) => debugPrint('Error in link stream: $e'),
    );
  }

  /// Handle incoming URI
  Future<void> _handleUri(Uri uri) async {
    debugPrint('Received deep link: $uri');

    if (uri.scheme != 'comunifi') {
      debugPrint('Ignoring non-comunifi link');
      return;
    }

    // Handle recovery link: comunifi://restore?backup=<base64>
    if (uri.host == 'restore') {
      final backup = uri.queryParameters['backup'];
      if (backup != null && backup.isNotEmpty) {
        try {
          final payload = RecoveryPayload.fromCompressedBase64(backup);
          debugPrint(
            'Parsed recovery payload for group: ${payload.groupId.substring(0, 8)}...',
          );

          if (onRecoveryLink != null) {
            await onRecoveryLink!(payload);
          } else {
            // Store for later processing
            pendingRecoveryPayload = payload;
            debugPrint('Stored pending recovery payload');
          }
        } catch (e) {
          debugPrint('Failed to parse recovery link: $e');
        }
      }
    }
  }

  /// Check if there's a pending recovery payload and process it
  Future<bool> processPendingRecovery() async {
    if (pendingRecoveryPayload != null && onRecoveryLink != null) {
      final payload = pendingRecoveryPayload!;
      pendingRecoveryPayload = null;
      await onRecoveryLink!(payload);
      return true;
    }
    return false;
  }

  /// Clear pending recovery
  void clearPendingRecovery() {
    pendingRecoveryPayload = null;
  }

  /// Dispose of the service
  void dispose() {
    _linkSubscription?.cancel();
    _linkSubscription = null;
  }
}
