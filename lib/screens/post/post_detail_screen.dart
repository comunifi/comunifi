import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/post_detail.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/profile.dart';
import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/services/profile/profile.dart';
import 'package:comunifi/widgets/heart_button.dart';
import 'package:comunifi/widgets/quote_button.dart';
import 'package:comunifi/widgets/quoted_post_preview.dart';
import 'package:comunifi/widgets/link_preview.dart';
import 'package:comunifi/widgets/encrypted_image.dart';
import 'package:comunifi/services/link_preview/link_preview.dart';
import 'package:comunifi/screens/feed/quote_post_modal.dart';
import 'package:url_launcher/url_launcher.dart';

class PostDetailScreen extends StatefulWidget {
  final String postId;

  const PostDetailScreen({super.key, required this.postId});

  @override
  State<PostDetailScreen> createState() => _PostDetailScreenState();
}

class _PostDetailScreenState extends State<PostDetailScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _commentController = TextEditingController();
  bool _isPublishing = false;
  String? _publishError;

  @override
  void dispose() {
    _scrollController.dispose();
    _commentController.dispose();
    super.dispose();
  }

  Future<void> _publishComment() async {
    final content = _commentController.text.trim();
    if (content.isEmpty || _isPublishing) return;

    final postDetailState = context.read<PostDetailState>();
    if (!postDetailState.isConnected) {
      setState(() {
        _publishError = 'Not connected to relay';
      });
      return;
    }

    setState(() {
      _isPublishing = true;
      _publishError = null;
    });

    try {
      await postDetailState.publishComment(content);
      _commentController.clear();
      setState(() {
        _isPublishing = false;
      });
    } catch (e) {
      setState(() {
        _isPublishing = false;
        _publishError = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<PostDetailState, ProfileState>(
      builder: (context, postDetailState, profileState, child) {
        return CupertinoPageScaffold(
          navigationBar: const CupertinoNavigationBar(
            middle: Text('Post'),
          ),
          child: SafeArea(
            child: Builder(
              builder: (context) {
                if (!postDetailState.isConnected &&
                    postDetailState.errorMessage != null) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          postDetailState.errorMessage!,
                          style: const TextStyle(
                            color: CupertinoColors.systemRed,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        CupertinoButton(
                          onPressed: postDetailState.retryConnection,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  );
                }

                if (postDetailState.isLoading && postDetailState.post == null) {
                  return const Center(child: CupertinoActivityIndicator());
                }

                if (postDetailState.post == null) {
                  return const Center(
                    child: Text('Post not found'),
                  );
                }

                return GestureDetector(
                  onTap: () => FocusScope.of(context).unfocus(),
                  behavior: HitTestBehavior.translucent,
                  child: Column(
                    children: [
                      Expanded(
                        child: CustomScrollView(
                          controller: _scrollController,
                          slivers: [
                            CupertinoSliverRefreshControl(
                              onRefresh: () async {
                                await postDetailState.refreshComments();
                              },
                            ),
                            // Post content
                            SliverToBoxAdapter(
                              child: _PostItem(
                                event: postDetailState.post!,
                              ),
                            ),
                            // Comments header
                            SliverToBoxAdapter(
                              child: Container(
                                padding: const EdgeInsets.all(16.0),
                                decoration: const BoxDecoration(
                                  border: Border(
                                    top: BorderSide(
                                      color: CupertinoColors.separator,
                                      width: 0.5,
                                    ),
                                    bottom: BorderSide(
                                      color: CupertinoColors.separator,
                                      width: 0.5,
                                    ),
                                  ),
                                ),
                                child: Text(
                                  'Comments (${postDetailState.comments.length})',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 16,
                                  ),
                                ),
                              ),
                            ),
                            // Comments list
                            if (postDetailState.isLoadingComments &&
                                postDetailState.comments.isEmpty)
                              const SliverToBoxAdapter(
                                child: Padding(
                                  padding: EdgeInsets.all(16.0),
                                  child: Center(
                                    child: CupertinoActivityIndicator(),
                                  ),
                                ),
                              )
                            else if (postDetailState.comments.isEmpty)
                              const SliverToBoxAdapter(
                                child: Padding(
                                  padding: EdgeInsets.all(16.0),
                                  child: Center(
                                    child: Text(
                                      'No comments yet',
                                      style: TextStyle(
                                        color: CupertinoColors.secondaryLabel,
                                      ),
                                    ),
                                  ),
                                ),
                              )
                            else
                              SliverList(
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) {
                                    if (index < postDetailState.comments.length) {
                                      return _CommentItem(
                                        event: postDetailState.comments[index],
                                      );
                                    }
                                    return const SizedBox.shrink();
                                  },
                                  childCount: postDetailState.comments.length,
                                ),
                              ),
                          ],
                        ),
                      ),
                      _ComposeCommentWidget(
                        controller: _commentController,
                        isPublishing: _isPublishing,
                        error: _publishError,
                        onPublish: _publishComment,
                        onErrorDismiss: () {
                          setState(() {
                            _publishError = null;
                          });
                        },
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _PostItem extends StatefulWidget {
  final NostrEventModel event;

  const _PostItem({required this.event});

  @override
  State<_PostItem> createState() => _PostItemState();
}

class _PostItemState extends State<_PostItem> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final profileState = context.read<ProfileState>();
      if (!profileState.profiles.containsKey(widget.event.pubkey)) {
        profileState.getProfile(widget.event.pubkey);
      }
    });
  }

  String _truncatePubkey(String pubkey) {
    if (pubkey.length <= 12) return pubkey;
    return '${pubkey.substring(0, 6)}...${pubkey.substring(pubkey.length - 6)}';
  }

  @override
  Widget build(BuildContext context) {
    final profile = context.select<ProfileState, ProfileData?>(
      (profileState) => profileState.profiles[widget.event.pubkey],
    );

    final username = profile?.getUsername();
    final displayName = username ?? _truncatePubkey(widget.event.pubkey);

    return _PostItemContent(event: widget.event, displayName: displayName);
  }
}

class _PostItemContent extends StatefulWidget {
  final NostrEventModel event;
  final String displayName;

  const _PostItemContent({
    required this.event,
    required this.displayName,
  });

  @override
  State<_PostItemContent> createState() => _PostItemContentState();
}

class _PostItemContentState extends State<_PostItemContent> {
  int _reactionCount = 0;
  bool _isLoadingReactionCount = true;
  bool _hasUserReacted = false;
  bool _isReacting = false;
  StreamSubscription<GroupReactionUpdate>? _groupReactionSubscription;
  StreamSubscription<PostReactionUpdate>? _postReactionSubscription;

  /// Get group ID from event's 'g' tag (for encrypted group messages)
  String? get _groupIdHex {
    for (final tag in widget.event.tags) {
      if (tag.isNotEmpty && tag[0] == 'g' && tag.length > 1) {
        return tag[1];
      }
    }
    return null;
  }

  /// Whether this event belongs to a group (has encrypted reactions)
  bool get _isGroupEvent => _groupIdHex != null;

  @override
  void initState() {
    super.initState();
    _loadReactionData();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      if (_isGroupEvent) {
        // Subscribe to real-time reaction updates for group events
        final groupState = context.read<GroupState>();
        _groupReactionSubscription = groupState.reactionUpdates.listen((update) {
          if (update.eventId == widget.event.id && mounted) {
            _loadReactionData();
          }
        });
      } else {
        // Subscribe to real-time reaction updates for regular events
        final postDetailState = context.read<PostDetailState>();
        _postReactionSubscription =
            postDetailState.reactionUpdates.listen((update) {
          if (update.eventId == widget.event.id && mounted) {
            _loadReactionData();
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _groupReactionSubscription?.cancel();
    _postReactionSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadReactionData() async {
    if (!mounted) return;

    final groupIdHex = _groupIdHex;

    if (groupIdHex != null) {
      // Group event - use GroupState for encrypted reactions
      final groupState = context.read<GroupState>();
      final count = await groupState.getGroupReactionCount(
        widget.event.id,
        groupIdHex,
      );
      final hasReacted = await groupState.hasUserReactedInGroup(
        widget.event.id,
        groupIdHex,
      );
      if (mounted) {
        setState(() {
          _reactionCount = count;
          _hasUserReacted = hasReacted;
          _isLoadingReactionCount = false;
        });
      }
    } else {
      // Regular feed event - use PostDetailState for unencrypted reactions
      final postDetailState = context.read<PostDetailState>();
      final count = await postDetailState.getReactionCount(widget.event.id);
      final hasReacted = await postDetailState.hasUserReacted(widget.event.id);
      if (mounted) {
        setState(() {
          _reactionCount = count;
          _hasUserReacted = hasReacted;
          _isLoadingReactionCount = false;
        });
      }
    }
  }

  Future<void> _toggleReaction() async {
    if (_isReacting || !mounted) return;

    // Store previous state for rollback on error
    final wasReacted = _hasUserReacted;
    final previousCount = _reactionCount;

    setState(() {
      _isReacting = true;
      // Optimistic UI update - immediately toggle the heart
      _hasUserReacted = !wasReacted;
      _reactionCount = wasReacted
          ? (_reactionCount > 0 ? _reactionCount - 1 : 0)
          : _reactionCount + 1;
    });

    try {
      final groupIdHex = _groupIdHex;

      if (groupIdHex != null) {
        // Group event - publish encrypted reaction via GroupState
        final groupState = context.read<GroupState>();
        await groupState.publishGroupReaction(
          widget.event.id,
          widget.event.pubkey,
          groupIdHex,
          isUnlike: wasReacted,
        );
      } else {
        // Regular feed event - publish unencrypted reaction via PostDetailState
        final postDetailState = context.read<PostDetailState>();
        await postDetailState.publishReaction(
          widget.event.id,
          widget.event.pubkey,
          isUnlike: wasReacted,
        );
      }

      // Add a small delay to ensure cache is written before reloading
      await Future.delayed(const Duration(milliseconds: 150));

      await _loadReactionData();
    } catch (e) {
      debugPrint('Failed to toggle reaction: $e');
      // Rollback optimistic update on error
      if (mounted) {
        setState(() {
          _hasUserReacted = wasReacted;
          _reactionCount = previousCount;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isReacting = false;
        });
      }
    }
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
    return Container(
          padding: const EdgeInsets.all(16.0),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: CupertinoColors.separator, width: 0.5),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    widget.displayName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _formatDate(widget.event.createdAt),
                    style: const TextStyle(
                      color: CupertinoColors.secondaryLabel,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _RichContentText(content: widget.event.content),
              // Display attached images (NIP-92 imeta)
              if (widget.event.hasImages)
                EventImages(images: widget.event.imageInfoList),
              // Link previews
              Builder(
                builder: (context) {
                  final postDetailState = context.read<PostDetailState>();
                  return ContentLinkPreviews(
                    content: widget.event.content,
                    linkPreviewService: postDetailState.linkPreviewService,
                  );
                },
              ),
              // Quoted post preview (if this is a quote post)
              if (widget.event.isQuotePost && widget.event.quotedEventId != null)
                QuotedPostPreview(
                  quotedEventId: widget.event.quotedEventId!,
                ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  HeartButton(
                    eventId: widget.event.id,
                    reactionCount: _reactionCount,
                    isLoadingCount: _isLoadingReactionCount || _isReacting,
                    isReacted: _hasUserReacted,
                    onPressed: _isReacting ? () {} : _toggleReaction,
                  ),
                  const SizedBox(width: 16),
                  QuoteButton(
                    event: widget.event,
                    onPressed: () => _openQuoteModal(context),
                  ),
                ],
              ),
            ],
          ),
    );
  }

  void _openQuoteModal(BuildContext context) {
    final postDetailState = context.read<PostDetailState>();
    showCupertinoModalPopup(
      context: context,
      builder: (modalContext) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.5,
        child: QuotePostModal(
          quotedEvent: widget.event,
          isConnected: postDetailState.isConnected,
          onPublishQuotePost: postDetailState.publishQuotePost,
        ),
      ),
    );
  }
}

class _CommentItem extends StatefulWidget {
  final NostrEventModel event;

  const _CommentItem({required this.event});

  @override
  State<_CommentItem> createState() => _CommentItemState();
}

class _CommentItemState extends State<_CommentItem> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final profileState = context.read<ProfileState>();
      if (!profileState.profiles.containsKey(widget.event.pubkey)) {
        profileState.getProfile(widget.event.pubkey);
      }
    });
  }

  String _truncatePubkey(String pubkey) {
    if (pubkey.length <= 12) return pubkey;
    return '${pubkey.substring(0, 6)}...${pubkey.substring(pubkey.length - 6)}';
  }

  @override
  Widget build(BuildContext context) {
    final profile = context.select<ProfileState, ProfileData?>(
      (profileState) => profileState.profiles[widget.event.pubkey],
    );

    final username = profile?.getUsername();
    final displayName = username ?? _truncatePubkey(widget.event.pubkey);

    return _CommentItemContent(event: widget.event, displayName: displayName);
  }
}

class _CommentItemContent extends StatefulWidget {
  final NostrEventModel event;
  final String displayName;

  const _CommentItemContent({
    required this.event,
    required this.displayName,
  });

  @override
  State<_CommentItemContent> createState() => _CommentItemContentState();
}

class _CommentItemContentState extends State<_CommentItemContent> {
  int _reactionCount = 0;
  bool _isLoadingReactionCount = true;
  bool _hasUserReacted = false;
  bool _isReacting = false;
  StreamSubscription<GroupReactionUpdate>? _groupReactionSubscription;
  StreamSubscription<PostReactionUpdate>? _postReactionSubscription;

  /// Get group ID from event's 'g' tag (for encrypted group messages)
  String? get _groupIdHex {
    for (final tag in widget.event.tags) {
      if (tag.isNotEmpty && tag[0] == 'g' && tag.length > 1) {
        return tag[1];
      }
    }
    return null;
  }

  /// Whether this event belongs to a group (has encrypted reactions)
  bool get _isGroupEvent => _groupIdHex != null;

  @override
  void initState() {
    super.initState();
    _loadReactionData();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      if (_isGroupEvent) {
        // Subscribe to real-time reaction updates for group events
        final groupState = context.read<GroupState>();
        _groupReactionSubscription = groupState.reactionUpdates.listen((update) {
          if (update.eventId == widget.event.id && mounted) {
            _loadReactionData();
          }
        });
      } else {
        // Subscribe to real-time reaction updates for regular events
        final postDetailState = context.read<PostDetailState>();
        _postReactionSubscription =
            postDetailState.reactionUpdates.listen((update) {
          if (update.eventId == widget.event.id && mounted) {
            _loadReactionData();
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _groupReactionSubscription?.cancel();
    _postReactionSubscription?.cancel();
    super.dispose();
  }

  Future<void> _loadReactionData() async {
    if (!mounted) return;

    final groupIdHex = _groupIdHex;

    if (groupIdHex != null) {
      // Group event - use GroupState for encrypted reactions
      final groupState = context.read<GroupState>();
      final count = await groupState.getGroupReactionCount(
        widget.event.id,
        groupIdHex,
      );
      final hasReacted = await groupState.hasUserReactedInGroup(
        widget.event.id,
        groupIdHex,
      );
      if (mounted) {
        setState(() {
          _reactionCount = count;
          _hasUserReacted = hasReacted;
          _isLoadingReactionCount = false;
        });
      }
    } else {
      // Regular comment - use PostDetailState for unencrypted reactions
      final postDetailState = context.read<PostDetailState>();
      final count = await postDetailState.getReactionCount(widget.event.id);
      final hasReacted = await postDetailState.hasUserReacted(widget.event.id);
      if (mounted) {
        setState(() {
          _reactionCount = count;
          _hasUserReacted = hasReacted;
          _isLoadingReactionCount = false;
        });
      }
    }
  }

  Future<void> _toggleReaction() async {
    if (_isReacting || !mounted) return;

    // Store previous state for rollback on error
    final wasReacted = _hasUserReacted;
    final previousCount = _reactionCount;

    setState(() {
      _isReacting = true;
      // Optimistic UI update - immediately toggle the heart
      _hasUserReacted = !wasReacted;
      _reactionCount = wasReacted
          ? (_reactionCount > 0 ? _reactionCount - 1 : 0)
          : _reactionCount + 1;
    });

    try {
      final groupIdHex = _groupIdHex;

      if (groupIdHex != null) {
        // Group event - publish encrypted reaction via GroupState
        final groupState = context.read<GroupState>();
        await groupState.publishGroupReaction(
          widget.event.id,
          widget.event.pubkey,
          groupIdHex,
          isUnlike: wasReacted,
        );
      } else {
        // Regular comment - publish unencrypted reaction via PostDetailState
        final postDetailState = context.read<PostDetailState>();
        await postDetailState.publishReaction(
          widget.event.id,
          widget.event.pubkey,
          isUnlike: wasReacted,
        );
      }

      // Add a small delay to ensure cache is written before reloading
      await Future.delayed(const Duration(milliseconds: 150));

      await _loadReactionData();
    } catch (e) {
      debugPrint('Failed to toggle reaction: $e');
      // Rollback optimistic update on error
      if (mounted) {
        setState(() {
          _hasUserReacted = wasReacted;
          _reactionCount = previousCount;
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isReacting = false;
        });
      }
    }
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
    return Container(
          padding: const EdgeInsets.all(16.0),
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: CupertinoColors.separator, width: 0.5),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    widget.displayName,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    _formatDate(widget.event.createdAt),
                    style: const TextStyle(
                      color: CupertinoColors.secondaryLabel,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              _RichContentText(content: widget.event.content),
              // Display attached images (NIP-92 imeta)
              if (widget.event.hasImages)
                EventImages(images: widget.event.imageInfoList),
              // Link previews for comments
              Builder(
                builder: (context) {
                  final postDetailState = context.read<PostDetailState>();
                  return ContentLinkPreviews(
                    content: widget.event.content,
                    linkPreviewService: postDetailState.linkPreviewService,
                  );
                },
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  HeartButton(
                    eventId: widget.event.id,
                    reactionCount: _reactionCount,
                    isLoadingCount: _isLoadingReactionCount || _isReacting,
                    isReacted: _hasUserReacted,
                    onPressed: _isReacting ? () {} : _toggleReaction,
                  ),
                ],
              ),
            ],
          ),
    );
  }
}

/// Widget that renders text content with clickable URLs
class _RichContentText extends StatelessWidget {
  final String content;

  const _RichContentText({required this.content});

  @override
  Widget build(BuildContext context) {
    final spans = _buildTextSpans(context);
    return RichText(
      text: TextSpan(
        style: DefaultTextStyle.of(context).style.copyWith(fontSize: 15),
        children: spans,
      ),
    );
  }

  List<InlineSpan> _buildTextSpans(BuildContext context) {
    final spans = <InlineSpan>[];
    final urlRegex = LinkPreviewService.urlRegex;
    final matches = urlRegex.allMatches(content);

    int lastEnd = 0;

    for (final match in matches) {
      // Add text before the URL
      if (match.start > lastEnd) {
        spans.add(TextSpan(
          text: content.substring(lastEnd, match.start),
        ));
      }

      // Add the URL as a clickable span
      var url = match.group(0) ?? '';
      if (url.startsWith('www.')) {
        url = 'https://$url';
      }
      // Clean trailing punctuation
      final cleanUrl = _cleanUrl(url);
      final originalUrl = match.group(0) ?? '';
      
      spans.add(TextSpan(
        text: originalUrl,
        style: TextStyle(
          color: CupertinoColors.systemBlue.resolveFrom(context),
          decoration: TextDecoration.underline,
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () => _launchUrl(cleanUrl),
      ));

      lastEnd = match.end;
    }

    // Add remaining text after last URL
    if (lastEnd < content.length) {
      spans.add(TextSpan(
        text: content.substring(lastEnd),
      ));
    }

    // If no URLs found, just return the plain text
    if (spans.isEmpty) {
      spans.add(TextSpan(text: content));
    }

    return spans;
  }

  String _cleanUrl(String url) {
    final trailingChars = ['.', ',', '!', '?', ')', ']', '}', ';', ':', '"', "'"];
    while (url.isNotEmpty && trailingChars.contains(url[url.length - 1])) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri != null) {
      try {
        await launchUrl(uri, mode: LaunchMode.inAppBrowserView);
      } catch (e) {
        debugPrint('Could not launch URL: $e');
      }
    }
  }
}

class _ComposeCommentWidget extends StatelessWidget {
  final TextEditingController controller;
  final bool isPublishing;
  final String? error;
  final VoidCallback onPublish;
  final VoidCallback onErrorDismiss;

  const _ComposeCommentWidget({
    required this.controller,
    required this.isPublishing,
    this.error,
    required this.onPublish,
    required this.onErrorDismiss,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground,
        border: Border(
          top: BorderSide(color: CupertinoColors.separator, width: 0.5),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (error != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 8.0,
                ),
                color: CupertinoColors.systemRed.withOpacity(0.1),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        error!,
                        style: const TextStyle(
                          color: CupertinoColors.systemRed,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      minSize: 0,
                      onPressed: onErrorDismiss,
                      child: const Icon(
                        CupertinoIcons.xmark_circle_fill,
                        color: CupertinoColors.systemRed,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Focus(
                      onKeyEvent: (node, event) {
                        final isDesktop =
                            defaultTargetPlatform == TargetPlatform.macOS ||
                                defaultTargetPlatform ==
                                    TargetPlatform.windows ||
                                defaultTargetPlatform == TargetPlatform.linux;
                        if (isDesktop &&
                            event is KeyDownEvent &&
                            event.logicalKey == LogicalKeyboardKey.enter &&
                            !HardwareKeyboard.instance.isShiftPressed) {
                          if (!isPublishing) {
                            onPublish();
                          }
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: CupertinoTextField(
                        controller: controller,
                        placeholder: 'Write a comment...',
                        maxLines: null,
                        minLines: 1,
                        textInputAction: TextInputAction.newline,
                        autofocus: true,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12.0,
                          vertical: 8.0,
                        ),
                        decoration: BoxDecoration(
                          color: CupertinoColors.systemGrey6,
                          borderRadius: BorderRadius.circular(20.0),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 0,
                    onPressed: isPublishing ? null : onPublish,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: isPublishing
                            ? CupertinoColors.systemGrey
                            : CupertinoColors.systemBlue,
                        shape: BoxShape.circle,
                      ),
                      child: isPublishing
                          ? const CupertinoActivityIndicator(
                              color: CupertinoColors.white,
                            )
                          : const Icon(
                              CupertinoIcons.arrow_up,
                              color: CupertinoColors.white,
                              size: 20,
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

