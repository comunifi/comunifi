import 'package:flutter/cupertino.dart';
import 'package:comunifi/services/link_preview/link_preview.dart';
import 'package:url_launcher/url_launcher.dart';

/// A widget that displays a preview of a URL with its metadata
class LinkPreview extends StatefulWidget {
  final String url;
  final LinkPreviewService? linkPreviewService;

  const LinkPreview({
    super.key,
    required this.url,
    this.linkPreviewService,
  });

  @override
  State<LinkPreview> createState() => _LinkPreviewState();
}

class _LinkPreviewState extends State<LinkPreview> {
  late final LinkPreviewService _service;
  LinkMetadata? _metadata;
  bool _isLoading = true;
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _service = widget.linkPreviewService ?? LinkPreviewService();
    _loadMetadata();
  }

  Future<void> _loadMetadata() async {
    try {
      final metadata = await _service.fetchMetadata(widget.url);
      if (mounted) {
        setState(() {
          _metadata = metadata;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _hasError = true;
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _launchUrl() async {
    final uri = Uri.tryParse(widget.url);
    if (uri != null) {
      try {
        await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
      } catch (e) {
        debugPrint('Could not launch URL: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return _buildLoadingState();
    }

    if (_hasError || _metadata == null || !_metadata!.hasContent) {
      return _buildMinimalLink();
    }

    return _buildRichPreview();
  }

  Widget _buildLoadingState() {
    return Container(
      margin: const EdgeInsets.only(top: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: CupertinoColors.separator.resolveFrom(context),
          width: 0.5,
        ),
      ),
      child: Row(
        children: [
          const CupertinoActivityIndicator(),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _extractDomain(widget.url),
              style: TextStyle(
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
                fontSize: 13,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMinimalLink() {
    return GestureDetector(
      onTap: _launchUrl,
      child: Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: CupertinoColors.systemGrey6.resolveFrom(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: CupertinoColors.separator.resolveFrom(context),
            width: 0.5,
          ),
        ),
        child: Row(
          children: [
            Icon(
              CupertinoIcons.link,
              size: 18,
              color: CupertinoColors.systemBlue.resolveFrom(context),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                widget.url,
                style: TextStyle(
                  color: CupertinoColors.systemBlue.resolveFrom(context),
                  fontSize: 14,
                  decoration: TextDecoration.underline,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              CupertinoIcons.chevron_right,
              size: 16,
              color: CupertinoColors.tertiaryLabel.resolveFrom(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRichPreview() {
    final hasImage = _metadata?.imageUrl != null;

    return GestureDetector(
      onTap: _launchUrl,
      child: Container(
        margin: const EdgeInsets.only(top: 12),
        decoration: BoxDecoration(
          color: CupertinoColors.systemGrey6.resolveFrom(context),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: CupertinoColors.separator.resolveFrom(context),
            width: 0.5,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Image preview
            if (hasImage)
              AspectRatio(
                aspectRatio: 1.91 / 1, // Standard OG image ratio
                child: Image.network(
                  _metadata!.imageUrl!,
                  fit: BoxFit.cover,
                  errorBuilder: (context, error, stackTrace) {
                    return Container(
                      color: CupertinoColors.systemGrey5.resolveFrom(context),
                      child: Center(
                        child: Icon(
                          CupertinoIcons.photo,
                          size: 32,
                          color: CupertinoColors.tertiaryLabel.resolveFrom(context),
                        ),
                      ),
                    );
                  },
                  loadingBuilder: (context, child, loadingProgress) {
                    if (loadingProgress == null) return child;
                    return Container(
                      color: CupertinoColors.systemGrey5.resolveFrom(context),
                      child: const Center(
                        child: CupertinoActivityIndicator(),
                      ),
                    );
                  },
                ),
              ),
            // Text content
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Site name and favicon
                  Row(
                    children: [
                      if (_metadata?.favicon != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(3),
                            child: Image.network(
                              _metadata!.favicon!,
                              width: 16,
                              height: 16,
                              errorBuilder: (context, error, stackTrace) {
                                return const SizedBox.shrink();
                              },
                            ),
                          ),
                        ),
                      Expanded(
                        child: Text(
                          _metadata?.siteName ?? _extractDomain(widget.url),
                          style: TextStyle(
                            color: CupertinoColors.secondaryLabel.resolveFrom(context),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                  if (_metadata?.title != null) ...[
                    const SizedBox(height: 6),
                    Text(
                      _metadata!.title!,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                  if (_metadata?.description != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      _metadata!.description!,
                      style: TextStyle(
                        color: CupertinoColors.secondaryLabel.resolveFrom(context),
                        fontSize: 13,
                      ),
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _extractDomain(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host;
    } catch (e) {
      return url;
    }
  }
}

/// A widget that displays multiple link previews for a text content
class ContentLinkPreviews extends StatelessWidget {
  final String content;
  final LinkPreviewService? linkPreviewService;
  final int maxPreviews;

  const ContentLinkPreviews({
    super.key,
    required this.content,
    this.linkPreviewService,
    this.maxPreviews = 3,
  });

  @override
  Widget build(BuildContext context) {
    final service = linkPreviewService ?? LinkPreviewService();
    final urls = service.extractUrls(content);

    if (urls.isEmpty) {
      return const SizedBox.shrink();
    }

    // Limit the number of previews
    final previewUrls = urls.take(maxPreviews).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: previewUrls.map((url) {
        return LinkPreview(
          url: url,
          linkPreviewService: service,
        );
      }).toList(),
    );
  }
}

