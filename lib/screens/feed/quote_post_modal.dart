import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/state/profile.dart';
import 'package:comunifi/services/profile/profile.dart';
import 'package:comunifi/widgets/quoted_post_preview.dart';

/// Modal for creating a quote post (repost with comment)
class QuotePostModal extends StatefulWidget {
  final NostrEventModel quotedEvent;
  final bool isConnected;
  final Future<void> Function(String content, NostrEventModel quotedEvent)
      onPublishQuotePost;

  const QuotePostModal({
    super.key,
    required this.quotedEvent,
    required this.isConnected,
    required this.onPublishQuotePost,
  });

  @override
  State<QuotePostModal> createState() => _QuotePostModalState();
}

class _QuotePostModalState extends State<QuotePostModal> {
  final TextEditingController _controller = TextEditingController();
  bool _isPublishing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Load profile for quoted event author
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final profileState = context.read<ProfileState>();
      if (!profileState.profiles.containsKey(widget.quotedEvent.pubkey)) {
        profileState.getProfile(widget.quotedEvent.pubkey);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String _truncatePubkey(String pubkey) {
    if (pubkey.length <= 12) return pubkey;
    return '${pubkey.substring(0, 6)}...${pubkey.substring(pubkey.length - 6)}';
  }

  Future<void> _publishQuotePost() async {
    final content = _controller.text.trim();
    if (content.isEmpty || _isPublishing) return;

    if (!widget.isConnected) {
      setState(() {
        _error = 'Not connected to relay';
      });
      return;
    }

    setState(() {
      _isPublishing = true;
      _error = null;
    });

    try {
      await widget.onPublishQuotePost(content, widget.quotedEvent);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isPublishing = false;
          _error = e.toString();
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final profile = context.select<ProfileState, ProfileData?>(
      (profileState) => profileState.profiles[widget.quotedEvent.pubkey],
    );
    final username = profile?.getUsername();
    final displayName = username ?? _truncatePubkey(widget.quotedEvent.pubkey);

    return Container(
      decoration: const BoxDecoration(
        color: CupertinoColors.systemBackground,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: CupertinoColors.systemGrey4,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 0,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const Text(
                    'Quote Post',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 0,
                    onPressed: _isPublishing ? null : _publishQuotePost,
                    child: _isPublishing
                        ? const CupertinoActivityIndicator()
                        : const Text(
                            'Post',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                  ),
                ],
              ),
            ),
            Container(height: 0.5, color: CupertinoColors.separator),
            // Content
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_error != null) ...[
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: CupertinoColors.systemRed.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _error!,
                                style: const TextStyle(
                                  color: CupertinoColors.systemRed,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                            CupertinoButton(
                              padding: EdgeInsets.zero,
                              minSize: 0,
                              onPressed: () {
                                setState(() {
                                  _error = null;
                                });
                              },
                              child: const Icon(
                                CupertinoIcons.xmark_circle_fill,
                                color: CupertinoColors.systemRed,
                                size: 20,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    // Compose area
                    CupertinoTextField(
                      controller: _controller,
                      placeholder: 'Add your comment...',
                      maxLines: 6,
                      minLines: 3,
                      textAlignVertical: TextAlignVertical.top,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: CupertinoColors.systemGrey6,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      autofocus: true,
                    ),
                    const SizedBox(height: 16),
                    // Quoted post preview
                    const Text(
                      'Quoting',
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                        color: CupertinoColors.secondaryLabel,
                      ),
                    ),
                    const SizedBox(height: 8),
                    QuotedPostPreviewStatic(
                      quotedEvent: widget.quotedEvent,
                      displayName: displayName,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

