import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/feed.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/profile.dart';
import 'package:comunifi/services/profile/profile.dart';
import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/screens/feed/invite_user_modal.dart';
import 'package:comunifi/widgets/groups_sidebar.dart';
import 'package:comunifi/widgets/comment_bubble.dart';
import 'package:comunifi/widgets/heart_button.dart';

class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _messageController = TextEditingController();
  bool _isPublishing = false;
  String? _publishError;
  static final Map<String, VoidCallback> _commentCountReloaders = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);

    // Set up profile callback in GroupState so it can trigger profile creation
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final groupState = context.read<GroupState>();
      final profileState = context.read<ProfileState>();

      // Set callback so GroupState can trigger profile creation
      groupState.setEnsureProfileCallback((pubkey, privateKey) async {
        await profileState.ensureUserProfile(
          pubkey: pubkey,
          privateKey: privateKey,
        );
      });

      // Also ensure profile immediately if GroupState already has keys
      _ensureUserProfile();

      // Load user profile for display in navigation bar
      _loadUserProfile();
    });
  }

  Future<void> _loadUserProfile() async {
    try {
      final groupState = context.read<GroupState>();
      final profileState = context.read<ProfileState>();

      final pubkey = await groupState.getNostrPublicKey();
      if (pubkey != null) {
        // Load profile to ensure it's in cache
        await profileState.getProfile(pubkey);
      }
    } catch (e) {
      debugPrint('FeedScreen: Error loading user profile: $e');
    }
  }

  Future<void> _ensureUserProfile() async {
    try {
      final groupState = context.read<GroupState>();
      final profileState = context.read<ProfileState>();

      // Wait a bit for GroupState to be fully initialized
      await Future.delayed(const Duration(milliseconds: 500));

      // Get keys from GroupState and ensure profile exists
      final pubkey = await groupState.getNostrPublicKey();
      if (pubkey != null) {
        final privateKey = await groupState.getNostrPrivateKey();
        if (privateKey != null) {
          debugPrint(
            'FeedScreen: Ensuring user profile with pubkey: ${pubkey.substring(0, 8)}...',
          );
          // Use GroupState's keys to ensure profile exists
          await profileState.ensureUserProfile(
            pubkey: pubkey,
            privateKey: privateKey,
          );
          debugPrint('FeedScreen: Profile ensured');
        } else {
          debugPrint('FeedScreen: No private key available from GroupState');
        }
      } else {
        debugPrint('FeedScreen: No pubkey available from GroupState');
      }
    } catch (e) {
      debugPrint('FeedScreen: Error ensuring user profile: $e');
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _publishMessage() async {
    final content = _messageController.text.trim();
    if (content.isEmpty || _isPublishing) return;

    final groupState = context.read<GroupState>();

    // If there's an active group, post to the group
    if (groupState.activeGroup != null) {
      if (!groupState.isConnected) {
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
        await groupState.postMessage(content);
        _messageController.clear();
        setState(() {
          _isPublishing = false;
        });
      } catch (e) {
        setState(() {
          _isPublishing = false;
          _publishError = e.toString();
        });
      }
      return;
    }

    // Otherwise, use regular feed
    final feedState = context.read<FeedState>();
    if (!feedState.isConnected) {
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
      await feedState.publishMessage(content);
      _messageController.clear();
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

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent * 0.8) {
      // Load more when scrolled 80% down
      final feedState = context.read<FeedState>();
      if (feedState.hasMoreEvents && !feedState.isLoadingMore) {
        feedState.loadMoreEvents();
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Reload all comment counts when navigating back to feed
    // This is called when the route becomes active again
    // Add a small delay to ensure any cached comments are fully written
    Future.delayed(const Duration(milliseconds: 200), () {
      if (!mounted) return;
      // Create a copy of the values to avoid issues if map changes during iteration
      final reloaders = List<VoidCallback>.from(_commentCountReloaders.values);
      for (final reloader in reloaders) {
        try {
          reloader();
        } catch (e) {
          // Ignore errors from disposed widgets
          debugPrint('Error reloading comment count: $e');
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Consumer3<FeedState, GroupState, ProfileState>(
      builder: (context, feedState, groupState, profileState, child) {
        final activeGroup = groupState.activeGroup;
        return CupertinoPageScaffold(
          navigationBar: CupertinoNavigationBar(
            leading: CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () {
                showCupertinoModalPopup(
                  context: context,
                  builder: (context) => const GroupsSidebar(),
                );
              },
              child: const Icon(CupertinoIcons.bars),
            ),
            middle: Text(activeGroup?.name ?? 'Feed'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Username button
                _UsernameButton(),
                // Group-specific actions
                if (activeGroup != null) ...[
                  const SizedBox(width: 8),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      showCupertinoModalPopup(
                        context: context,
                        builder: (context) => const InviteUserModal(),
                      );
                    },
                    child: const Icon(CupertinoIcons.person_add),
                  ),
                ],
              ],
            ),
          ),
          child: SafeArea(
            child: Builder(
              builder: (context) {
                // If there's an active group, show group messages
                if (groupState.activeGroup != null) {
                  if (!groupState.isConnected &&
                      groupState.errorMessage != null) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            groupState.errorMessage!,
                            style: const TextStyle(
                              color: CupertinoColors.systemRed,
                            ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          CupertinoButton(
                            onPressed: groupState.retryConnection,
                            child: const Text('Retry'),
                          ),
                        ],
                      ),
                    );
                  }

                  if (groupState.isLoading &&
                      groupState.groupMessages.isEmpty) {
                    return const Center(child: CupertinoActivityIndicator());
                  }

                  return Column(
                    children: [
                      Expanded(
                        child: groupState.groupMessages.isEmpty
                            ? const Center(
                                child: Text('No messages in this group yet'),
                              )
                            : CustomScrollView(
                                controller: _scrollController,
                                slivers: [
                                  CupertinoSliverRefreshControl(
                                    onRefresh: () async {
                                      await groupState
                                          .refreshActiveGroupMessages();
                                    },
                                  ),
                                  SliverList(
                                    delegate: SliverChildBuilderDelegate(
                                      (context, index) {
                                        if (index <
                                            groupState.groupMessages.length) {
                                          return _EventItem(
                                            event:
                                                groupState.groupMessages[index],
                                          );
                                        }
                                        return const SizedBox.shrink();
                                      },
                                      childCount:
                                          groupState.groupMessages.length,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                      _ComposeMessageWidget(
                        controller: _messageController,
                        isPublishing: _isPublishing,
                        error: _publishError,
                        onPublish: _publishMessage,
                        placeholder:
                            'Write a message to ${groupState.activeGroup!.name}...',
                        onErrorDismiss: () {
                          setState(() {
                            _publishError = null;
                          });
                        },
                      ),
                    ],
                  );
                }

                // Otherwise, show regular feed
                if (!feedState.isConnected && feedState.errorMessage != null) {
                  return Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          feedState.errorMessage!,
                          style: const TextStyle(
                            color: CupertinoColors.systemRed,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 16),
                        CupertinoButton(
                          onPressed: feedState.retryConnection,
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  );
                }

                if (feedState.isLoading && feedState.events.isEmpty) {
                  return const Center(child: CupertinoActivityIndicator());
                }

                return Column(
                  children: [
                    Expanded(
                      child: feedState.events.isEmpty
                          ? const Center(child: Text('No events yet'))
                          : CustomScrollView(
                              controller: _scrollController,
                              slivers: [
                                CupertinoSliverRefreshControl(
                                  onRefresh: () async {
                                    await feedState.refreshEvents();
                                    // Reload all comment counts after refresh
                                    // Wait a bit for the refresh to complete
                                    await Future.delayed(
                                      const Duration(milliseconds: 100),
                                    );
                                    if (mounted) {
                                      // Create a copy of the values to avoid issues if map changes during iteration
                                      final reloaders = List<VoidCallback>.from(
                                        _commentCountReloaders.values,
                                      );
                                      for (final reloader in reloaders) {
                                        try {
                                          reloader();
                                        } catch (e) {
                                          // Ignore errors from disposed widgets
                                          debugPrint(
                                            'Error reloading comment count: $e',
                                          );
                                        }
                                      }
                                    }
                                  },
                                ),
                                SliverList(
                                  delegate: SliverChildBuilderDelegate(
                                    (context, index) {
                                      if (index < feedState.events.length) {
                                        return _EventItem(
                                          event: feedState.events[index],
                                        );
                                      } else if (feedState.isLoadingMore) {
                                        return const Padding(
                                          padding: EdgeInsets.all(16.0),
                                          child: Center(
                                            child: CupertinoActivityIndicator(),
                                          ),
                                        );
                                      } else if (feedState.hasMoreEvents) {
                                        return const SizedBox.shrink();
                                      } else {
                                        return const Padding(
                                          padding: EdgeInsets.all(16.0),
                                          child: Center(
                                            child: Text(
                                              'No more events',
                                              style: TextStyle(
                                                color: CupertinoColors
                                                    .secondaryLabel,
                                              ),
                                            ),
                                          ),
                                        );
                                      }
                                    },
                                    childCount:
                                        feedState.events.length +
                                        (feedState.isLoadingMore ? 1 : 0) +
                                        (feedState.hasMoreEvents ? 0 : 1),
                                  ),
                                ),
                              ],
                            ),
                    ),
                    _ComposeMessageWidget(
                      controller: _messageController,
                      isPublishing: _isPublishing,
                      error: _publishError,
                      onPublish: _publishMessage,
                      onErrorDismiss: () {
                        setState(() {
                          _publishError = null;
                        });
                      },
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }
}

class _UsernameButton extends StatefulWidget {
  const _UsernameButton();

  @override
  State<_UsernameButton> createState() => _UsernameButtonState();
}

class _UsernameButtonState extends State<_UsernameButton> {
  String? _pubkey;

  @override
  void initState() {
    super.initState();
    _loadPubkey();
  }

  Future<void> _loadPubkey() async {
    final groupState = context.read<GroupState>();
    final pubkey = await groupState.getNostrPublicKey();
    if (mounted) {
      setState(() {
        _pubkey = pubkey;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_pubkey == null) {
      return const SizedBox.shrink();
    }

    // Watch for profile changes
    final profile = context.select<ProfileState, ProfileData?>(
      (profileState) => profileState.profiles[_pubkey!],
    );

    final username =
        profile?.getUsername() ??
        (_pubkey!.length > 12
            ? '${_pubkey!.substring(0, 6)}...${_pubkey!.substring(_pubkey!.length - 6)}'
            : _pubkey!);

    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: () {
        context.push('/profile');
      },
      child: Text(
        username,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _EventItem extends StatefulWidget {
  final NostrEventModel event;

  const _EventItem({required this.event});

  @override
  State<_EventItem> createState() => _EventItemState();
}

class _EventItemState extends State<_EventItem> {
  @override
  void initState() {
    super.initState();
    // Load profile asynchronously after build
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
    // Use context.select to only rebuild when the specific profile changes
    final profile = context.select<ProfileState, ProfileData?>(
      (profileState) => profileState.profiles[widget.event.pubkey],
    );

    // Profile will always have a value now (either from network or local username)
    // So we always show a username, no loading indicator needed
    final username = profile?.getUsername();
    final displayName = username ?? _truncatePubkey(widget.event.pubkey);

    return _EventItemContent(event: widget.event, displayName: displayName);
  }
}

class _EventItemContent extends StatefulWidget {
  final NostrEventModel event;
  final String displayName;

  const _EventItemContent({required this.event, required this.displayName});

  @override
  State<_EventItemContent> createState() => _EventItemContentState();
}

class _EventItemContentState extends State<_EventItemContent> {
  int _commentCount = 0;
  bool _isLoadingCount = true;
  int _reactionCount = 0;
  bool _isLoadingReactionCount = true;
  bool _hasUserReacted = false;
  bool _isReacting = false;
  bool _wasLoading = false;

  @override
  void initState() {
    super.initState();
    // Register reloader so FeedScreen can trigger reloads
    _FeedScreenState._commentCountReloaders[widget.event.id] =
        _loadCommentCount;
    _loadCommentCount();
    _loadReactionData();
  }

  @override
  void dispose() {
    // Unregister reloader
    _FeedScreenState._commentCountReloaders.remove(widget.event.id);
    super.dispose();
  }

  Future<void> _loadCommentCount() async {
    if (!mounted) return;

    final feedState = context.read<FeedState>();
    final count = await feedState.getCommentCount(widget.event.id);
    if (mounted) {
      setState(() {
        _commentCount = count;
        _isLoadingCount = false;
      });
    }
  }

  Future<void> _loadReactionData() async {
    if (!mounted) return;

    final feedState = context.read<FeedState>();
    final count = await feedState.getReactionCount(widget.event.id);
    final hasReacted = await feedState.hasUserReacted(widget.event.id);
    if (mounted) {
      setState(() {
        _reactionCount = count;
        _hasUserReacted = hasReacted;
        _isLoadingReactionCount = false;
      });
    }
  }

  Future<void> _toggleReaction() async {
    if (_isReacting || !mounted) return;

    setState(() {
      _isReacting = true;
    });

    try {
      final feedState = context.read<FeedState>();

      // If user has already reacted, publish an unlike reaction
      // Some Nostr clients use "-" content to indicate unliking
      await feedState.publishReaction(
        widget.event.id,
        widget.event.pubkey,
        isUnlike: _hasUserReacted,
      );

      // Add a small delay to ensure cache is written before reloading
      await Future.delayed(const Duration(milliseconds: 100));

      // Reload reaction data after publishing
      await _loadReactionData();
    } catch (e) {
      debugPrint('Failed to toggle reaction: $e');
    } finally {
      if (mounted) {
        setState(() {
          _isReacting = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Listen to FeedState loading state - reload comment count when feed finishes loading/refreshing
    final isLoading = context.select<FeedState, bool>(
      (feedState) => feedState.isLoading,
    );

    // Reload comment count when feed finishes loading (after refresh or initial load)
    // Only reload once per loading cycle to avoid duplicate loads
    if (_wasLoading && !isLoading && !_isLoadingCount) {
      _wasLoading = false; // Set immediately to prevent duplicate reloads
      // Add a small delay to ensure cache is updated
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted) {
          _loadCommentCount();
          _loadReactionData();
        }
      });
    } else if (isLoading) {
      _wasLoading = true;
    }

    return _EventItemContentWidget(
      event: widget.event,
      displayName: widget.displayName,
      commentCount: _commentCount,
      isLoadingCount: _isLoadingCount,
      reactionCount: _reactionCount,
      isLoadingReactionCount: _isLoadingReactionCount,
      hasUserReacted: _hasUserReacted,
      isReacting: _isReacting,
      onReactionPressed: _toggleReaction,
    );
  }
}

class _EventItemContentWidget extends StatelessWidget {
  final NostrEventModel event;
  final String displayName;
  final int commentCount;
  final bool isLoadingCount;
  final int reactionCount;
  final bool isLoadingReactionCount;
  final bool hasUserReacted;
  final bool isReacting;
  final VoidCallback onReactionPressed;

  const _EventItemContentWidget({
    required this.event,
    required this.displayName,
    required this.commentCount,
    required this.isLoadingCount,
    required this.reactionCount,
    required this.isLoadingReactionCount,
    required this.hasUserReacted,
    required this.isReacting,
    required this.onReactionPressed,
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

  /// Extract group ID from event's 'g' tag
  /// Handles both decrypted messages (kind 1) and encrypted envelopes (kind 1059)
  String? _getGroupIdFromEvent(NostrEventModel event) {
    // For encrypted envelopes, try the encryptedEnvelopeMlsGroupId property first
    if (event.isEncryptedEnvelope) {
      final groupId = event.encryptedEnvelopeMlsGroupId;
      if (groupId != null) return groupId;
    }

    // For decrypted messages or as fallback, check 'g' tag
    for (final tag in event.tags) {
      if (tag.isNotEmpty && tag[0] == 'g' && tag.length > 1) {
        return tag[1];
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final groupState = context.watch<GroupState>();
    final activeGroup = groupState.activeGroup;

    // Only show group name when no active group is selected
    final shouldShowGroupName = activeGroup == null;
    final groupIdHex = shouldShowGroupName ? _getGroupIdFromEvent(event) : null;
    // Use GroupState's getGroupName which resolves from DB and MLS groups
    final groupName = groupIdHex != null
        ? groupState.getGroupName(groupIdHex)
        : null;

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
                displayName,
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatDate(event.createdAt),
                style: const TextStyle(
                  color: CupertinoColors.secondaryLabel,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          if (groupName != null) ...[
            const SizedBox(height: 4),
            Text(
              groupName,
              style: const TextStyle(
                color: CupertinoColors.systemBlue,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Text(event.content, style: const TextStyle(fontSize: 15)),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              HeartButton(
                eventId: event.id,
                reactionCount: reactionCount,
                isLoadingCount: isLoadingReactionCount || isReacting,
                isReacted: hasUserReacted,
                onPressed: isReacting ? () {} : onReactionPressed,
              ),
              const SizedBox(width: 16),
              CommentBubble(
                eventId: event.id,
                commentCount: commentCount,
                isLoadingCount: isLoadingCount,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _ComposeMessageWidget extends StatelessWidget {
  final TextEditingController controller;
  final bool isPublishing;
  final String? error;
  final VoidCallback onPublish;
  final VoidCallback onErrorDismiss;
  final String? placeholder;

  const _ComposeMessageWidget({
    required this.controller,
    required this.isPublishing,
    this.error,
    required this.onPublish,
    required this.onErrorDismiss,
    this.placeholder,
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
                    child: CupertinoTextField(
                      controller: controller,
                      placeholder: placeholder ?? 'Write a message...',
                      maxLines: null,
                      minLines: 1,
                      textInputAction: TextInputAction.newline,
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
