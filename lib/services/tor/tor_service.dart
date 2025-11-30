import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:socks5_proxy/socks.dart';

/// Custom exception for Tor connection errors
class TorConnectionException implements Exception {
  final String message;
  TorConnectionException(this.message);

  @override
  String toString() => 'TorConnectionException: $message';
}

/// Tor service for macOS Tor SOCKS proxy connection
class TorService {
  static const String _torHost = '127.0.0.1';
  static const int _torPort = 9050;

  /// Check if a host is localhost
  bool isLocalhost(String host) {
    debugPrint('isLocalhost: $host');
    return host == 'localhost' ||
        host == '127.0.0.1' ||
        host == '::1' ||
        host.startsWith('192.168.') ||
        host.startsWith('10.') ||
        host.startsWith('172.');
  }

  /// Check if Tor daemon is running on the local machine
  Future<bool> isTorRunning() async {
    if (!Platform.isMacOS) {
      return false;
    }

    try {
      // Try to connect to Tor SOCKS proxy
      final socket = await Socket.connect(
        _torHost,
        _torPort,
        timeout: const Duration(seconds: 5),
      );
      socket.destroy();
      return true;
    } catch (e) {
      return false;
    }
  }

  /// Connect to a WebSocket through Tor SOCKS proxy
  Future<Socket> connectThroughTor(String host, int port) async {
    debugPrint('Connecting to $host:$port through Tor');
    if (!Platform.isMacOS) {
      throw TorConnectionException('TorService: Only macOS is supported');
    }

    // For localhost connections, connect directly without Tor
    if (isLocalhost(host)) {
      try {
        final socket = await Socket.connect(
          host,
          port,
          timeout: const Duration(seconds: 10),
        );
        return socket;
      } catch (e) {
        throw TorConnectionException(
          'Failed to connect to localhost $host:$port: $e',
        );
      }
    }

    if (!await isTorRunning()) {
      throw TorConnectionException(
        'Tor daemon is not running. Install with: brew install tor && brew services start tor',
      );
    }

    try {
      // Create SOCKS5 client for Tor proxy with timeout
      final socksSocket =
          await SocksTCPClient.connect(
            [ProxySettings(InternetAddress(_torHost), _torPort)],
            InternetAddress(host),
            port,
          ).timeout(
            const Duration(seconds: 30),
            onTimeout: () {
              throw TorConnectionException(
                'Connection timeout: Failed to connect to $host:$port through Tor within 30 seconds',
              );
            },
          );

      return socksSocket;
    } on TorConnectionException {
      rethrow;
    } catch (e) {
      // Provide more specific error messages based on the error type
      if (e.toString().contains('Connection refused')) {
        throw TorConnectionException(
          'Tor SOCKS proxy connection refused. Make sure Tor is running on $_torHost:$_torPort',
        );
      } else if (e.toString().contains('Network is unreachable')) {
        throw TorConnectionException(
          'Network unreachable. Check your internet connection and Tor configuration',
        );
      } else if (e.toString().contains('No route to host')) {
        throw TorConnectionException(
          'No route to host $host:$port. The target server may be down or unreachable',
        );
      } else {
        throw TorConnectionException('Failed to connect through Tor: $e');
      }
    }
  }

  /// Get user-friendly error message for Tor connection failures
  String getTorErrorMessage() {
    return 'Tor not detected. Install with: brew install tor && brew services start tor';
  }

  /// Verify that we're actually using Tor by checking our IP address
  Future<String> verifyTorConnection() async {
    if (!Platform.isMacOS) {
      throw TorConnectionException('TorService: Only macOS is supported');
    }

    HttpClient? client;
    try {
      // Create HttpClient with Tor SOCKS proxy
      client = HttpClient();
      SocksTCPClient.assignToHttpClient(client, [
        ProxySettings(InternetAddress(_torHost), _torPort),
      ]);

      // Make request to IP checking service (try multiple services for reliability)
      final ipServices = [
        'http://httpbin.org/ip',
        'http://ipinfo.io/ip',
        'http://icanhazip.com',
        'http://checkip.amazonaws.com',
      ];

      String? ip;
      for (final service in ipServices) {
        try {
          final request = await client.getUrl(Uri.parse(service));
          final response = await request.close();

          if (response.statusCode == 200) {
            final body = await response.transform(utf8.decoder).join();

            if (service.contains('httpbin.org')) {
              // Parse JSON response
              final jsonData = json.decode(body);
              ip = jsonData['origin'] as String;
            } else {
              // Parse plain text response
              ip = body.trim();
            }
            break;
          }
        } catch (e) {
          debugPrint('Failed to get IP from $service: $e');
          continue;
        }
      }

      if (ip != null) {
        return ip;
      } else {
        throw TorConnectionException(
          'All IP verification services are unavailable',
        );
      }
    } catch (e) {
      throw TorConnectionException('Failed to verify Tor connection: $e');
    } finally {
      client?.close();
    }
  }

  /// Verify localhost connection (returns local IP)
  Future<String> verifyLocalhostConnection() async {
    try {
      // For localhost, we can't verify through external services
      // Return a local identifier instead
      return 'localhost';
    } catch (e) {
      throw TorConnectionException('Failed to verify localhost connection: $e');
    }
  }

  /// Get installation instructions for macOS
  String getInstallationInstructions() {
    return '''
To use Tor connectivity:

1. Install Tor:
   brew install tor

2. Start Tor daemon:
   brew services start tor

3. Verify Tor is running:
   brew services list | grep tor

4. Try connecting again
''';
  }
}
