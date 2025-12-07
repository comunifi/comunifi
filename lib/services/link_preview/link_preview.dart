import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// Metadata extracted from a URL's OpenGraph tags
class LinkMetadata {
  final String url;
  final String? title;
  final String? description;
  final String? imageUrl;
  final String? siteName;
  final String? type;
  final String? favicon;

  const LinkMetadata({
    required this.url,
    this.title,
    this.description,
    this.imageUrl,
    this.siteName,
    this.type,
    this.favicon,
  });

  /// Check if this metadata has meaningful content to display
  bool get hasContent =>
      title != null || description != null || imageUrl != null;

  Map<String, dynamic> toJson() => {
        'url': url,
        'title': title,
        'description': description,
        'imageUrl': imageUrl,
        'siteName': siteName,
        'type': type,
        'favicon': favicon,
      };

  factory LinkMetadata.fromJson(Map<String, dynamic> json) => LinkMetadata(
        url: json['url'] as String,
        title: json['title'] as String?,
        description: json['description'] as String?,
        imageUrl: json['imageUrl'] as String?,
        siteName: json['siteName'] as String?,
        type: json['type'] as String?,
        favicon: json['favicon'] as String?,
      );

  @override
  String toString() =>
      'LinkMetadata(url: $url, title: $title, description: $description)';
}

/// Service for extracting URLs from content and fetching metadata
class LinkPreviewService {
  // Cache for fetched metadata to avoid repeated network requests
  final Map<String, LinkMetadata> _cache = {};

  // In-flight requests to prevent duplicate fetches
  final Map<String, Future<LinkMetadata?>> _pendingRequests = {};

  /// Regular expression to match URLs in text
  /// Matches http://, https://, and www. URLs
  static final RegExp urlRegex = RegExp(
    r'''(?:https?://|www\.)[^\s<>\[\]{}|\\^`'"]+''',
    caseSensitive: false,
  );

  /// Extract all URLs from a text content
  List<String> extractUrls(String content) {
    final matches = urlRegex.allMatches(content);
    final urls = <String>[];

    for (final match in matches) {
      var url = match.group(0);
      if (url != null) {
        // Ensure URL has a protocol
        if (url.startsWith('www.')) {
          url = 'https://$url';
        }
        // Clean up trailing punctuation that might have been captured
        url = _cleanUrl(url);
        if (url.isNotEmpty && !urls.contains(url)) {
          urls.add(url);
        }
      }
    }

    return urls;
  }

  /// Clean up URL by removing trailing punctuation
  String _cleanUrl(String url) {
    // Remove trailing punctuation that's likely not part of the URL
    final trailingChars = ['.', ',', '!', '?', ')', ']', '}', ';', ':', '"', "'"];
    while (url.isNotEmpty && trailingChars.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// Generate 'r' tags for all URLs in content (Nostr convention)
  List<List<String>> generateUrlTags(String content) {
    final urls = extractUrls(content);
    return urls.map((url) => ['r', url]).toList();
  }

  /// Fetch metadata for a URL
  /// Returns cached result if available
  Future<LinkMetadata?> fetchMetadata(String url) async {
    // Check cache first
    if (_cache.containsKey(url)) {
      return _cache[url];
    }

    // Check if there's already a pending request for this URL
    if (_pendingRequests.containsKey(url)) {
      return _pendingRequests[url];
    }

    // Start new request
    final future = _fetchMetadataInternal(url);
    _pendingRequests[url] = future;

    try {
      final result = await future;
      _pendingRequests.remove(url);
      return result;
    } catch (e) {
      _pendingRequests.remove(url);
      rethrow;
    }
  }

  Future<LinkMetadata?> _fetchMetadataInternal(String url) async {
    try {
      // Validate URL
      final uri = Uri.tryParse(url);
      if (uri == null || !uri.hasScheme) {
        return null;
      }

      // Fetch the HTML content
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 10);

      final request = await client.getUrl(uri);
      // Set a user agent to avoid being blocked
      request.headers.set(HttpHeaders.userAgentHeader, 'Mozilla/5.0 (compatible; LinkPreview/1.0)');
      request.headers.set(HttpHeaders.acceptHeader, 'text/html,application/xhtml+xml');

      final response = await request.close();

      if (response.statusCode != 200) {
        debugPrint('LinkPreviewService: Failed to fetch $url: ${response.statusCode}');
        return LinkMetadata(url: url);
      }

      // Limit response size to avoid memory issues
      final bytes = await response.take(200 * 1024).toList(); // 200KB max
      final html = utf8.decode(bytes.expand((x) => x).toList(), allowMalformed: true);

      // Parse OpenGraph and meta tags
      final metadata = _parseHtmlMetadata(url, html);

      // Cache the result
      _cache[url] = metadata;

      return metadata;
    } catch (e) {
      debugPrint('LinkPreviewService: Error fetching metadata for $url: $e');
      // Return basic metadata with just the URL
      final metadata = LinkMetadata(url: url);
      _cache[url] = metadata;
      return metadata;
    }
  }

  /// Parse HTML to extract OpenGraph and other meta tags
  LinkMetadata _parseHtmlMetadata(String url, String html) {
    String? title;
    String? description;
    String? imageUrl;
    String? siteName;
    String? type;
    String? favicon;

    // Extract OpenGraph tags
    title = _extractMetaContent(html, 'og:title') ??
        _extractMetaContent(html, 'twitter:title');
    description = _extractMetaContent(html, 'og:description') ??
        _extractMetaContent(html, 'twitter:description') ??
        _extractMetaContent(html, 'description');
    imageUrl = _extractMetaContent(html, 'og:image') ??
        _extractMetaContent(html, 'twitter:image');
    siteName = _extractMetaContent(html, 'og:site_name');
    type = _extractMetaContent(html, 'og:type');

    // Fallback to <title> tag if no OG title
    if (title == null) {
      final titleMatch = RegExp(
        r'<title[^>]*>([^<]+)</title>',
        caseSensitive: false,
      ).firstMatch(html);
      if (titleMatch != null) {
        title = _decodeHtmlEntities(titleMatch.group(1)?.trim() ?? '');
      }
    }

    // Try to find favicon
    favicon = _extractFavicon(html, url);

    // Make relative URLs absolute
    if (imageUrl != null && !imageUrl.startsWith('http')) {
      imageUrl = _makeAbsoluteUrl(url, imageUrl);
    }
    if (favicon != null && !favicon.startsWith('http')) {
      favicon = _makeAbsoluteUrl(url, favicon);
    }

    // Decode HTML entities in text fields
    if (title != null) title = _decodeHtmlEntities(title);
    if (description != null) description = _decodeHtmlEntities(description);
    if (siteName != null) siteName = _decodeHtmlEntities(siteName);

    return LinkMetadata(
      url: url,
      title: title,
      description: description,
      imageUrl: imageUrl,
      siteName: siteName,
      type: type,
      favicon: favicon,
    );
  }

  /// Extract content from a meta tag
  String? _extractMetaContent(String html, String property) {
    // Try property attribute (OpenGraph style)
    var regex = RegExp(
      '<meta[^>]+property=["\']$property["\'][^>]+content=["\']([^"\']+)["\']',
      caseSensitive: false,
    );
    var match = regex.firstMatch(html);
    if (match != null) return match.group(1);

    // Try content before property
    regex = RegExp(
      '<meta[^>]+content=["\']([^"\']+)["\'][^>]+property=["\']$property["\']',
      caseSensitive: false,
    );
    match = regex.firstMatch(html);
    if (match != null) return match.group(1);

    // Try name attribute (standard meta tags)
    regex = RegExp(
      '<meta[^>]+name=["\']$property["\'][^>]+content=["\']([^"\']+)["\']',
      caseSensitive: false,
    );
    match = regex.firstMatch(html);
    if (match != null) return match.group(1);

    // Try content before name
    regex = RegExp(
      '<meta[^>]+content=["\']([^"\']+)["\'][^>]+name=["\']$property["\']',
      caseSensitive: false,
    );
    match = regex.firstMatch(html);
    if (match != null) return match.group(1);

    return null;
  }

  /// Extract favicon from HTML
  String? _extractFavicon(String html, String baseUrl) {
    // Try to find apple-touch-icon first (usually higher quality)
    var regex = RegExp(
      r'''<link[^>]+rel=["']apple-touch-icon["'][^>]+href=["']([^"']+)["']''',
      caseSensitive: false,
    );
    var match = regex.firstMatch(html);
    if (match != null) return match.group(1);

    // Try icon
    regex = RegExp(
      r'''<link[^>]+rel=["'](?:shortcut )?icon["'][^>]+href=["']([^"']+)["']''',
      caseSensitive: false,
    );
    match = regex.firstMatch(html);
    if (match != null) return match.group(1);

    // Fallback to /favicon.ico
    try {
      final uri = Uri.parse(baseUrl);
      return '${uri.scheme}://${uri.host}/favicon.ico';
    } catch (e) {
      return null;
    }
  }

  /// Convert a relative URL to absolute
  String _makeAbsoluteUrl(String baseUrl, String relativeUrl) {
    try {
      final base = Uri.parse(baseUrl);
      if (relativeUrl.startsWith('//')) {
        return '${base.scheme}:$relativeUrl';
      }
      if (relativeUrl.startsWith('/')) {
        return '${base.scheme}://${base.host}$relativeUrl';
      }
      // Relative path
      final basePath = base.path.contains('/')
          ? base.path.substring(0, base.path.lastIndexOf('/') + 1)
          : '/';
      return '${base.scheme}://${base.host}$basePath$relativeUrl';
    } catch (e) {
      return relativeUrl;
    }
  }

  /// Decode common HTML entities
  String _decodeHtmlEntities(String text) {
    return text
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'")
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#x27;', "'")
        .replaceAll('&#x2F;', '/')
        .replaceAll('&#x60;', '`')
        .replaceAll('&#x3D;', '=');
  }

  /// Clear the metadata cache
  void clearCache() {
    _cache.clear();
  }

  /// Get cached metadata for a URL (if available)
  LinkMetadata? getCachedMetadata(String url) {
    return _cache[url];
  }
}

