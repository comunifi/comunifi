import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/state/feed.dart';
import 'package:comunifi/state/post_detail.dart';
import 'package:comunifi/state/profile.dart';
import 'package:comunifi/services/profile/profile.dart';

/// Widget that displays a preview of a quoted post
/// Tapping it navigates to the full post
class QuotedPostPreview extends StatefulWidget {
  final String quotedEventId;
  final bool compact;

  const QuotedPostPreview({
    super.key,
    required this.quotedEventId,
    this.compact = false,
  });

  @override
  State<QuotedPostPreview> createState() => _QuotedPostPreviewState();
}

class _QuotedPostPreviewState extends State<QuotedPostPreview> {
  NostrEventModel? _quotedEvent;
  bool _isLoading = true;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _loadQuotedEvent();
  }

  Future<void> _loadQuotedEvent() async {
    if (!mounted) return;

    try {
      NostrEventModel? event;

      // Try FeedState first (available on feed screen)
      try {
        final feedState = context.read<FeedState>();
        event = await feedState.getEvent(widget.quotedEventId);
      } catch (_) {
        // FeedState not available, try PostDetailState
      }

      // If FeedState didn't work, try PostDetailState (available on post detail screen)
      if (event == null) {
        try {
          final postDetailState = context.read<PostDetailState>();
          event = await postDetailState.getEvent(widget.quotedEventId);
        } catch (_) {
          // PostDetailState not available either
        }
      }

      if (mounted) {
        setState(() {
          _quotedEvent = event;
          _isLoading = false;
          _failed = event == null;
        });

        // Load profile for the quoted event author
        if (event != null) {
          final profileState = context.read<ProfileState>();
          if (!profileState.profiles.containsKey(event.pubkey)) {
            profileState.getProfile(event.pubkey);
          }
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _failed = true;
        });
      }
    }
  }

  String _truncatePubkey(String pubkey) {
    if (pubkey.length <= 12) return pubkey;
    return '${pubkey.substring(0, 6)}...${pubkey.substring(pubkey.length - 6)}';
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: CupertinoColors.separator),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(
          child: CupertinoActivityIndicator(),
        ),
      );
    }

    if (_failed || _quotedEvent == null) {
      return Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: CupertinoColors.separator),
          borderRadius: BorderRadius.circular(12),
          color: CupertinoColors.systemGrey6,
        ),
        child: Row(
          children: [
            const Icon(
              CupertinoIcons.exclamationmark_circle,
              size: 16,
              color: CupertinoColors.secondaryLabel,
            ),
            const SizedBox(width: 8),
            Text(
              'Quoted post not available',
              style: TextStyle(
                color: CupertinoColors.secondaryLabel,
                fontSize: widget.compact ? 13 : 14,
              ),
            ),
          ],
        ),
      );
    }

    // Get profile for display name
    final profile = context.select<ProfileState, ProfileData?>(
      (profileState) => profileState.profiles[_quotedEvent!.pubkey],
    );
    final username = profile?.getUsername();
    final displayName = username ?? _truncatePubkey(_quotedEvent!.pubkey);

    // Truncate content for preview
    final maxLength = widget.compact ? 100 : 200;
    final content = _quotedEvent!.content.length > maxLength
        ? '${_quotedEvent!.content.substring(0, maxLength)}...'
        : _quotedEvent!.content;

    return GestureDetector(
      onTap: () {
        context.push('/post/${_quotedEvent!.id}');
      },
      child: Container(
        margin: const EdgeInsets.only(top: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: CupertinoColors.separator),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  CupertinoIcons.arrow_2_squarepath,
                  size: 12,
                  color: CupertinoColors.secondaryLabel,
                ),
                const SizedBox(width: 4),
                Text(
                  displayName,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: widget.compact ? 12 : 13,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _formatDate(_quotedEvent!.createdAt),
                  style: TextStyle(
                    color: CupertinoColors.secondaryLabel,
                    fontSize: widget.compact ? 11 : 12,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              content,
              style: TextStyle(
                fontSize: widget.compact ? 13 : 14,
                color: CupertinoColors.label,
              ),
              maxLines: widget.compact ? 2 : 4,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Static version of quoted post preview for use in modals
/// where the event is already known
class QuotedPostPreviewStatic extends StatelessWidget {
  final NostrEventModel quotedEvent;
  final String displayName;
  final bool compact;

  const QuotedPostPreviewStatic({
    super.key,
    required this.quotedEvent,
    required this.displayName,
    this.compact = false,
  });

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }

  @override
  Widget build(BuildContext context) {
    // Truncate content for preview
    final maxLength = compact ? 100 : 200;
    final content = quotedEvent.content.length > maxLength
        ? '${quotedEvent.content.substring(0, maxLength)}...'
        : quotedEvent.content;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: CupertinoColors.separator),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                CupertinoIcons.arrow_2_squarepath,
                size: 12,
                color: CupertinoColors.secondaryLabel,
              ),
              const SizedBox(width: 4),
              Text(
                displayName,
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: compact ? 12 : 13,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatDate(quotedEvent.createdAt),
                style: TextStyle(
                  color: CupertinoColors.secondaryLabel,
                  fontSize: compact ? 11 : 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            content,
            style: TextStyle(
              fontSize: compact ? 13 : 14,
              color: CupertinoColors.label,
            ),
            maxLines: compact ? 2 : 4,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

