import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/main.dart' show routeObserver;
import 'package:comunifi/state/feed.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/profile.dart';
import 'package:comunifi/services/profile/profile.dart';
import 'package:comunifi/services/mls/mls_group.dart';
import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/screens/feed/quote_post_modal.dart';
import 'package:comunifi/screens/feed/edit_group_modal.dart';
import 'package:comunifi/screens/feed/group_settings_modal.dart';
import 'package:comunifi/widgets/groups_sidebar.dart';
import 'package:comunifi/widgets/profile_sidebar.dart';
import 'package:comunifi/widgets/members_sidebar.dart';
import 'package:comunifi/widgets/slide_in_sidebar.dart';
import 'package:comunifi/widgets/comment_bubble.dart';
import 'package:comunifi/widgets/heart_button.dart';
import 'package:comunifi/widgets/quote_button.dart';
import 'package:comunifi/widgets/quoted_post_preview.dart';
import 'package:comunifi/widgets/link_preview.dart';
import 'package:comunifi/widgets/encrypted_image.dart';
import 'package:comunifi/services/link_preview/link_preview.dart';
import 'package:comunifi/services/media/media_upload.dart';
import 'package:url_launcher/url_launcher.dart';

class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> with RouteAware {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _messageController = TextEditingController();
  final ImagePicker _imagePicker = ImagePicker();
  bool _isPublishing = false;
  String? _publishError;
  bool _isLeftSidebarOpen = false;
  bool _isRightSidebarOpen = false;
  Uint8List? _selectedImageBytes;
  String? _selectedImageMimeType;
  bool _hasFetchedDiscoveredGroups = false;
  static final Map<String, VoidCallback> _commentCountReloaders = {};
  static final Map<String, VoidCallback> _reactionDataReloaders = {};

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);

    // Set up profile callback in GroupState so it can trigger profile creation
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Check if widget is still mounted before accessing context
      if (!mounted) return;

      final groupState = context.read<GroupState>();
      final profileState = context.read<ProfileState>();

      // Set callback so GroupState can trigger profile creation
      groupState.setEnsureProfileCallback((
        pubkey,
        privateKey,
        hpkePublicKeyHex,
      ) async {
        await profileState.ensureUserProfile(
          pubkey: pubkey,
          privateKey: privateKey,
          hpkePublicKeyHex: hpkePublicKeyHex,
        );
      });

      // Also ensure profile immediately if GroupState already has keys
      _ensureUserProfile();

      // Load user profile for display in navigation bar
      _loadUserProfile();

      // Fetch discovered groups (for group images, covers, etc.)
      // This ensures data is available even when sidebar isn't open (mobile)
      _fetchDiscoveredGroupsIfNeeded(groupState);
    });
  }

  /// Fetches discovered groups if connected and not yet fetched
  void _fetchDiscoveredGroupsIfNeeded(GroupState groupState) {
    if (groupState.isConnected && !_hasFetchedDiscoveredGroups) {
      _hasFetchedDiscoveredGroups = true;
      groupState.refreshDiscoveredGroups(limit: 1000);
    }
  }

  @override
  void didPopNext() {
    // Called when a route has been popped off and this route is now visible
    // Reload all data for visible items after a small delay
    Future.delayed(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      _reloadAllCommentCounts();
      _reloadAllReactionData();
    });
  }

  void _reloadAllCommentCounts() {
    final reloaders = List<VoidCallback>.from(_commentCountReloaders.values);
    for (final reloader in reloaders) {
      try {
        reloader();
      } catch (e) {
        debugPrint('Error reloading comment count: $e');
      }
    }
  }

  void _reloadAllReactionData() {
    final reloaders = List<VoidCallback>.from(_reactionDataReloaders.values);
    for (final reloader in reloaders) {
      try {
        reloader();
      } catch (e) {
        debugPrint('Error reloading reaction data: $e');
      }
    }
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

  /// Get the display name for a group, preferring the name from relay announcements
  String _getGroupDisplayName(GroupState groupState, MlsGroup? group) {
    if (group == null) return 'Comunifi';

    // First try to get the name from relay announcements (group name cache)
    final groupIdHex = group.id.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final announcementName = groupState.getGroupName(groupIdHex);
    if (announcementName != null) {
      return announcementName;
    }

    // Fallback to the MlsGroup name
    return group.name;
  }

  @override
  void dispose() {
    routeObserver.unsubscribe(this);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _pickImage() async {
    try {
      final XFile? image = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 1920,
        imageQuality: 85,
      );

      if (image != null) {
        final bytes = await image.readAsBytes();
        final mimeType = image.mimeType ?? 'image/jpeg';

        setState(() {
          _selectedImageBytes = bytes;
          _selectedImageMimeType = mimeType;
        });
      }
    } catch (e) {
      debugPrint('Failed to pick image: $e');
      setState(() {
        _publishError = 'Failed to select image';
      });
    }
  }

  void _clearSelectedImage() {
    setState(() {
      _selectedImageBytes = null;
      _selectedImageMimeType = null;
    });
  }

  Future<void> _publishMessage() async {
    final content = _messageController.text.trim();
    if (content.isEmpty && _selectedImageBytes == null) return;
    if (_isPublishing) return;

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
        MediaUploadResult? uploadResult;

        // Upload image if selected (will be encrypted with MLS)
        if (_selectedImageBytes != null) {
          uploadResult = await groupState.uploadMedia(
            _selectedImageBytes!,
            _selectedImageMimeType ?? 'image/jpeg',
          );
        }

        await groupState.postMessage(
          content,
          imageUrl: uploadResult?.url,
          isImageEncrypted: uploadResult?.isEncrypted ?? false,
          imageSha256: uploadResult?.sha256,
        );
        _messageController.clear();
        _clearSelectedImage();
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

    // Otherwise, use regular feed (no image support for now)
    final feedState = context.read<FeedState>();
    final profileState = context.read<ProfileState>();
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
      // Resolve @username mentions to pubkeys
      final resolvedMentions = await FeedState.resolveMentions(content, (
        username,
      ) async {
        final profile = await profileState.searchByUsername(username);
        return profile?.pubkey;
      });

      await feedState.publishMessage(
        content,
        resolvedMentions: resolvedMentions,
      );
      _messageController.clear();
      _clearSelectedImage();
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
      final groupState = context.read<GroupState>();

      // If there's an active group, load more group messages
      if (groupState.activeGroup != null) {
        if (groupState.hasMoreGroupMessages &&
            !groupState.isLoadingMoreGroupMessages) {
          groupState.loadMoreGroupMessages();
        }
      } else {
        // Otherwise load more from regular feed
        final feedState = context.read<FeedState>();
        if (feedState.hasMoreEvents && !feedState.isLoadingMore) {
          feedState.loadMoreEvents();
        }
      }
    }
  }

  /// Merge feed events with group messages and sort by date
  /// Also applies hashtag filter if set
  List<NostrEventModel> _mergeAndSortEvents(
    List<NostrEventModel> feedEvents,
    List<NostrEventModel> groupMessages,
    String? hashtagFilter,
  ) {
    // Combine events, avoiding duplicates by ID
    final seenIds = <String>{};
    final merged = <NostrEventModel>[];

    for (final event in feedEvents) {
      if (!seenIds.contains(event.id)) {
        seenIds.add(event.id);
        merged.add(event);
      }
    }

    for (final event in groupMessages) {
      if (!seenIds.contains(event.id)) {
        seenIds.add(event.id);
        // Apply hashtag filter to group messages too
        if (hashtagFilter != null) {
          final filterLower = hashtagFilter.toLowerCase();
          final hasTag =
              event.hashtags.contains(filterLower) ||
              NostrEventModel.extractHashtagsFromContent(
                event.content,
              ).contains(filterLower);
          if (hasTag) {
            merged.add(event);
          }
        } else {
          merged.add(event);
        }
      }
    }

    // Sort by date (newest first)
    merged.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return merged;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe to route observer to detect when we come back from another screen
    final route = ModalRoute.of(context);
    if (route != null) {
      routeObserver.subscribe(this, route);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer3<FeedState, GroupState, ProfileState>(
      builder: (context, feedState, groupState, profileState, child) {
        // Fetch discovered groups when connection is established (for mobile where sidebar isn't always mounted)
        if (groupState.isConnected && !_hasFetchedDiscoveredGroups) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _fetchDiscoveredGroupsIfNeeded(groupState);
          });
        } else if (!groupState.isConnected) {
          // Reset flag when disconnected so we fetch again on reconnect
          _hasFetchedDiscoveredGroups = false;
        }

        final activeGroup = groupState.activeGroup;
        final screenWidth = MediaQuery.of(context).size.width;
        final isWideScreen = screenWidth > 1000;
        final sidebarWidth = 320.0;

        // For wide screens, use persistent sidebars in a Row layout
        if (isWideScreen) {
          return Row(
            children: [
              // Left sidebar (Groups) - always visible on wide screens
              GroupsSidebar(
                onClose: () {
                  // On wide screens, sidebars are persistent, so this is a no-op
                  // But we keep it for consistency with the sidebar widget
                },
                showCloseButton: false,
              ),
              // Main feed content
              Expanded(
                child: activeGroup != null
                    // Group view: no navigation bar, banner reaches top
                    ? ColoredBox(
                        color: CupertinoColors.systemBackground,
                        child: _buildFeedContent(
                          feedState,
                          groupState,
                          activeGroup,
                        ),
                      )
                    : groupState.isExploreMode
                    // Explore view: show discoverable groups
                    ? CupertinoPageScaffold(
                        navigationBar: const CupertinoNavigationBar(
                          middle: Text('Explore Groups'),
                          trailing: _UsernameButton(),
                        ),
                        child: SafeArea(
                          child: _ExploreGroupsView(
                            onJoinRequested: () {
                              // Refresh groups after join request
                              groupState.refreshDiscoveredGroups(limit: 1000);
                            },
                          ),
                        ),
                      )
                    // Main feed: show navigation bar with "Comunifi"
                    : CupertinoPageScaffold(
                        navigationBar: CupertinoNavigationBar(
                          middle: Text(
                            _getGroupDisplayName(groupState, activeGroup),
                          ),
                          trailing: _UsernameButton(),
                        ),
                        child: SafeArea(
                          child: _buildFeedContent(
                            feedState,
                            groupState,
                            activeGroup,
                          ),
                        ),
                      ),
              ),
              // Right sidebar - shows Profile (global/explore) or Members (group)
              Container(
                width: sidebarWidth,
                decoration: const BoxDecoration(
                  color: CupertinoColors.systemBackground,
                  border: Border(
                    left: BorderSide(
                      color: CupertinoColors.separator,
                      width: 0.5,
                    ),
                  ),
                ),
                child: activeGroup != null
                    ? MembersSidebar(onClose: () {}, showCloseButton: false)
                    : ProfileSidebar(onClose: () {}, showCloseButton: false),
              ),
            ],
          );
        }

        // For narrow screens, use overlay sidebars
        return Stack(
          children: [
            // Group view: no navigation bar, content reaches top with floating buttons
            if (activeGroup != null)
              ColoredBox(
                color: CupertinoColors.systemBackground,
                child: Stack(
                  children: [
                    _buildFeedContent(feedState, groupState, activeGroup),
                    // Floating menu button (left)
                    Positioned(
                      top: MediaQuery.of(context).padding.top + 8,
                      left: 8,
                      child: CupertinoButton(
                        padding: const EdgeInsets.all(8),
                        color: CupertinoColors.systemBackground.withOpacity(
                          0.8,
                        ),
                        borderRadius: BorderRadius.circular(20),
                        minSize: 36,
                        onPressed: () {
                          setState(() {
                            _isLeftSidebarOpen = true;
                          });
                        },
                        child: const Icon(CupertinoIcons.bars, size: 20),
                      ),
                    ),
                    // Floating members button (right)
                    Positioned(
                      top: MediaQuery.of(context).padding.top + 8,
                      right: 8,
                      child: CupertinoButton(
                        padding: const EdgeInsets.all(8),
                        color: CupertinoColors.systemBackground.withOpacity(
                          0.8,
                        ),
                        borderRadius: BorderRadius.circular(20),
                        minSize: 36,
                        onPressed: () {
                          setState(() {
                            _isRightSidebarOpen = true;
                          });
                        },
                        child: const Icon(CupertinoIcons.person_2, size: 20),
                      ),
                    ),
                  ],
                ),
              )
            // Explore view: show navigation bar with "Explore Groups"
            else if (groupState.isExploreMode)
              CupertinoPageScaffold(
                navigationBar: CupertinoNavigationBar(
                  leading: CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      setState(() {
                        _isLeftSidebarOpen = true;
                      });
                    },
                    child: const Icon(CupertinoIcons.bars),
                  ),
                  middle: const Text('Explore Groups'),
                  trailing: _UsernameButton(
                    onTap: () {
                      setState(() {
                        _isRightSidebarOpen = true;
                      });
                    },
                  ),
                ),
                child: SafeArea(
                  child: _ExploreGroupsView(
                    onJoinRequested: () {
                      groupState.refreshDiscoveredGroups(limit: 1000);
                    },
                  ),
                ),
              )
            // Main feed: show navigation bar with "Comunifi"
            else
              CupertinoPageScaffold(
                navigationBar: CupertinoNavigationBar(
                  leading: CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      setState(() {
                        _isLeftSidebarOpen = true;
                      });
                    },
                    child: const Icon(CupertinoIcons.bars),
                  ),
                  middle: Text(_getGroupDisplayName(groupState, activeGroup)),
                  trailing: _UsernameButton(
                    onTap: () {
                      setState(() {
                        _isRightSidebarOpen = true;
                      });
                    },
                  ),
                ),
                child: SafeArea(
                  child: _buildFeedContent(feedState, groupState, activeGroup),
                ),
              ),
            // Left sidebar (Groups) - overlay on narrow screens
            SlideInSidebar(
              isOpen: _isLeftSidebarOpen,
              onClose: () {
                setState(() {
                  _isLeftSidebarOpen = false;
                });
              },
              position: SlideInSidebarPosition.left,
              width: 108,
              child: GroupsSidebar(
                onClose: () {
                  setState(() {
                    _isLeftSidebarOpen = false;
                  });
                },
              ),
            ),
            // Right sidebar - Profile (global feed) or Members (group) - overlay on narrow screens
            SlideInSidebar(
              isOpen: _isRightSidebarOpen,
              onClose: () {
                setState(() {
                  _isRightSidebarOpen = false;
                });
              },
              position: SlideInSidebarPosition.right,
              width: sidebarWidth,
              child: activeGroup != null
                  ? MembersSidebar(
                      onClose: () {
                        setState(() {
                          _isRightSidebarOpen = false;
                        });
                      },
                    )
                  : ProfileSidebar(
                      onClose: () {
                        setState(() {
                          _isRightSidebarOpen = false;
                        });
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildFeedContent(
    FeedState feedState,
    GroupState groupState,
    dynamic activeGroup,
  ) {
    return Builder(
      builder: (context) {
        // If there's an active group, show group messages
        if (activeGroup != null) {
          if (!groupState.isConnected && groupState.errorMessage != null) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    groupState.errorMessage!,
                    style: const TextStyle(color: CupertinoColors.systemRed),
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

          if (groupState.isLoading && groupState.groupMessages.isEmpty) {
            return const Center(child: CupertinoActivityIndicator());
          }

          return GestureDetector(
            onTap: () => FocusScope.of(context).unfocus(),
            behavior: HitTestBehavior.translucent,
            child: Column(
              children: [
                // Hashtag filter indicator for groups
                if (groupState.hashtagFilter != null)
                  _HashtagFilterIndicator(
                    hashtag: groupState.hashtagFilter!,
                    onClear: () => groupState.clearHashtagFilter(),
                  ),
                Expanded(
                  child: groupState.groupMessages.isEmpty
                      ? Center(
                          child: Text(
                            groupState.hashtagFilter != null
                                ? 'No messages with #${groupState.hashtagFilter}'
                                : 'No messages in this group yet',
                          ),
                        )
                      : CustomScrollView(
                          controller: _scrollController,
                          physics: const AlwaysScrollableScrollPhysics(),
                          slivers: [
                            // Collapsing group header - pinned at top, shrinks on scroll
                            _GroupHeaderSliver(
                              group: groupState.activeGroup!,
                              groupState: groupState,
                            ),
                            CupertinoSliverRefreshControl(
                              onRefresh: () async {
                                await groupState.refreshActiveGroupMessages();
                              },
                            ),
                            SliverList(
                              delegate: SliverChildBuilderDelegate((
                                context,
                                index,
                              ) {
                                if (index < groupState.groupMessages.length) {
                                  final event = groupState.groupMessages[index];
                                  return _EventItem(
                                    key: ValueKey(event.id),
                                    event: event,
                                  );
                                }
                                return const SizedBox.shrink();
                              }, childCount: groupState.groupMessages.length),
                            ),
                            // Loading indicator for infinite scroll
                            if (groupState.isLoadingMoreGroupMessages)
                              const SliverToBoxAdapter(
                                child: Padding(
                                  padding: EdgeInsets.symmetric(vertical: 16.0),
                                  child: Center(
                                    child: CupertinoActivityIndicator(),
                                  ),
                                ),
                              ),
                            // "No more messages" indicator
                            if (!groupState.hasMoreGroupMessages &&
                                groupState.groupMessages.isNotEmpty)
                              const SliverToBoxAdapter(
                                child: Padding(
                                  padding: EdgeInsets.symmetric(vertical: 16.0),
                                  child: Center(
                                    child: Text(
                                      'No more messages',
                                      style: TextStyle(
                                        color: CupertinoColors.systemGrey,
                                        fontSize: 14,
                                      ),
                                    ),
                                  ),
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
                  onPickImage: _pickImage,
                  selectedImageBytes: _selectedImageBytes,
                  onClearImage: _clearSelectedImage,
                  showImagePicker: true,
                ),
              ],
            ),
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
                  style: const TextStyle(color: CupertinoColors.systemRed),
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

        // Merge feed events with group messages for unified view
        // Combine public posts (kind 1) with decrypted group messages
        final mergedEvents = _mergeAndSortEvents(
          feedState.events,
          groupState.allDecryptedMessages,
          feedState.hashtagFilter,
        );

        // Check if user is a member of any non-personal groups (for welcome card)
        // Don't show welcome card while groups/announcements are still loading
        final isGroupsLoading =
            !groupState.isConnected ||
            groupState.isLoading ||
            groupState.isLoadingGroups ||
            (groupState.groups.isNotEmpty &&
                groupState.discoveredGroups.isEmpty);

        bool hasNonPersonalGroups = false;
        if (!isGroupsLoading) {
          for (final mlsGroup in groupState.groups) {
            final groupIdHex = mlsGroup.id.bytes
                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                .join();
            final announcement = groupState.getGroupAnnouncementByHexId(
              groupIdHex,
            );
            if (announcement != null && !announcement.isPersonal) {
              hasNonPersonalGroups = true;
              break;
            }
          }
        }

        return GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.translucent,
          child: Column(
            children: [
              // Welcome card for new users without groups
              // Only show after groups have loaded to avoid flicker
              if (!hasNonPersonalGroups &&
                  !isGroupsLoading &&
                  feedState.hashtagFilter == null)
                _WelcomeCard(
                  onCreateGroup: () {
                    // Open left sidebar to show create group option
                    setState(() {
                      _isLeftSidebarOpen = true;
                    });
                  },
                  onExploreGroups: () {
                    groupState.setExploreMode(true);
                  },
                ),
              // Hashtag filter indicator
              if (feedState.hashtagFilter != null)
                _HashtagFilterIndicator(
                  hashtag: feedState.hashtagFilter!,
                  onClear: () => feedState.clearHashtagFilter(),
                ),
              Expanded(
                child: mergedEvents.isEmpty
                    ? Center(
                        child: Text(
                          feedState.hashtagFilter != null
                              ? 'No posts with #${feedState.hashtagFilter}'
                              : 'No events yet',
                        ),
                      )
                    : CustomScrollView(
                        controller: _scrollController,
                        physics: const AlwaysScrollableScrollPhysics(),
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
                                if (index < mergedEvents.length) {
                                  final event = mergedEvents[index];
                                  return _EventItem(
                                    key: ValueKey(event.id),
                                    event: event,
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
                                          color: CupertinoColors.secondaryLabel,
                                        ),
                                      ),
                                    ),
                                  );
                                }
                              },
                              childCount:
                                  mergedEvents.length +
                                  (feedState.isLoadingMore ? 1 : 0) +
                                  (feedState.hasMoreEvents ? 0 : 1),
                            ),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _UsernameButton extends StatefulWidget {
  final VoidCallback? onTap;

  const _UsernameButton({this.onTap});

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

    final profilePicture = profile?.picture;

    final content = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          username,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 8),
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: CupertinoColors.systemGrey4,
            image: profilePicture != null
                ? DecorationImage(
                    image: NetworkImage(profilePicture),
                    fit: BoxFit.cover,
                  )
                : null,
          ),
          child: profilePicture == null
              ? const Icon(
                  CupertinoIcons.person_fill,
                  size: 16,
                  color: CupertinoColors.systemGrey,
                )
              : null,
        ),
      ],
    );

    if (widget.onTap != null) {
      return GestureDetector(onTap: widget.onTap, child: content);
    }

    return content;
  }
}

class _EventItem extends StatefulWidget {
  final NostrEventModel event;

  const _EventItem({super.key, required this.event});

  @override
  State<_EventItem> createState() => _EventItemState();
}

class _EventItemState extends State<_EventItem> {
  @override
  void initState() {
    super.initState();
    // Load profile asynchronously after build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Check if widget is still mounted before accessing context
      if (!mounted) return;
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
  StreamSubscription<GroupReactionUpdate>? _reactionSubscription;

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
    // Register reloaders so FeedScreen can trigger reloads when navigating back
    _FeedScreenState._commentCountReloaders[widget.event.id] =
        _loadCommentCount;
    _FeedScreenState._reactionDataReloaders[widget.event.id] =
        _loadReactionData;
    _loadCommentCount();
    _loadReactionData();

    // Subscribe to real-time reaction updates for group events
    if (_isGroupEvent) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final groupState = context.read<GroupState>();
        _reactionSubscription = groupState.reactionUpdates.listen((update) {
          if (update.eventId == widget.event.id && mounted) {
            // Reload reaction data when we receive an update for this event
            _loadReactionData();
          }
        });
      });
    }
  }

  @override
  void dispose() {
    // Unregister reloaders
    _FeedScreenState._commentCountReloaders.remove(widget.event.id);
    _FeedScreenState._reactionDataReloaders.remove(widget.event.id);
    // Cancel reaction subscription
    _reactionSubscription?.cancel();
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
      // Regular feed event - use FeedState for unencrypted reactions
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
  }

  Future<void> _toggleReaction() async {
    if (_isReacting || !mounted) return;

    // Store previous state for rollback on error
    final wasReacted = _hasUserReacted;
    final previousCount = _reactionCount;

    // Provide haptic feedback: heavy for like, light for unlike
    if (wasReacted) {
      HapticFeedback.lightImpact();
    } else {
      HapticFeedback.heavyImpact();
    }

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
        // Regular feed event - publish unencrypted reaction via FeedState
        final feedState = context.read<FeedState>();
        await feedState.publishReaction(
          widget.event.id,
          widget.event.pubkey,
          isUnlike: wasReacted,
        );
      }

      // Add a small delay to ensure cache is written before reloading
      await Future.delayed(const Duration(milliseconds: 150));

      // Reload reaction data to get accurate count from cache
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

  @override
  Widget build(BuildContext context) {
    // Listen to FeedState loading state - reload comment count when feed finishes loading/refreshing
    final isLoading = context.select<FeedState, bool>(
      (feedState) => feedState.isLoading,
    );

    // Reload comment count when feed finishes loading (after refresh or initial load)
    // Only reload once per loading cycle to avoid duplicate loads
    // Don't reload while user is actively reacting (would overwrite optimistic update)
    if (_wasLoading && !isLoading && !_isLoadingCount && !_isReacting) {
      _wasLoading = false; // Set immediately to prevent duplicate reloads
      // Add a small delay to ensure cache is updated
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted && !_isReacting) {
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
      onQuotePressed: () => _openQuoteModal(context),
      onHashtagTap: (hashtag) => _filterByHashtag(context, hashtag),
      onMentionTap: (pubkey) => _showMentionProfile(context, pubkey),
    );
  }

  void _openQuoteModal(BuildContext context) {
    final feedState = context.read<FeedState>();
    final groupState = context.read<GroupState>();

    // Use group's publishQuotePost if a group is active, otherwise use feed's
    final isConnected = groupState.activeGroup != null
        ? groupState.isConnected
        : feedState.isConnected;

    final publishQuotePost = groupState.activeGroup != null
        ? groupState.publishQuotePost
        : feedState.publishQuotePost;

    showCupertinoModalPopup(
      context: context,
      builder: (modalContext) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.5,
        child: QuotePostModal(
          quotedEvent: widget.event,
          isConnected: isConnected,
          onPublishQuotePost: publishQuotePost,
        ),
      ),
    );
  }

  void _filterByHashtag(BuildContext context, String hashtag) {
    final groupState = context.read<GroupState>();
    // If in a group, filter group messages; otherwise filter feed
    if (groupState.activeGroup != null) {
      groupState.setHashtagFilter(hashtag);
    } else {
      final feedState = context.read<FeedState>();
      feedState.setHashtagFilter(hashtag);
    }
  }

  void _showMentionProfile(BuildContext context, String username) {
    // Show a modal with profile info - will resolve username to profile
    showCupertinoModalPopup(
      context: context,
      builder: (modalContext) => _MentionProfileModal(username: username),
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
  final VoidCallback onQuotePressed;
  final void Function(String hashtag)? onHashtagTap;
  final void Function(String pubkey)? onMentionTap;

  /// Wide screen breakpoint (same as sidebar layout)
  static const double wideScreenBreakpoint = 1000;

  /// Groups sidebar width (left, minimal)
  static const double groupsSidebarWidth = 68;

  /// Profile sidebar width (right)
  static const double profileSidebarWidth = 320;

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
    required this.onQuotePressed,
    this.onHashtagTap,
    this.onMentionTap,
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

    // Get group announcement for the picture - O(1) lookup
    final groupAnnouncement = groupIdHex != null
        ? groupState.getGroupAnnouncementByHexId(groupIdHex)
        : null;
    final groupPicture = groupAnnouncement?.picture;

    // Calculate max width based on feed area (screen width minus sidebars on wide screens)
    final screenWidth = MediaQuery.of(context).size.width;
    final isWideScreen = screenWidth > wideScreenBreakpoint;
    final maxContentWidth = isWideScreen
        ? screenWidth - groupsSidebarWidth - profileSidebarWidth
        : screenWidth;

    final hasGroupFrame = groupName != null && groupIdHex != null;

    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxContentWidth),
        child: Container(
          margin: hasGroupFrame
              ? const EdgeInsets.symmetric(horizontal: 8, vertical: 4)
              : EdgeInsets.zero,
          decoration: hasGroupFrame
              ? BoxDecoration(
                  border: Border.all(
                    color: CupertinoColors.systemIndigo.withOpacity(0.3),
                    width: 1,
                  ),
                  borderRadius: BorderRadius.circular(12),
                )
              : const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: CupertinoColors.separator,
                      width: 0.5,
                    ),
                  ),
                ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Group frame header (when showing group)
              if (hasGroupFrame)
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    // Find the MlsGroup by groupIdHex using O(1) cached lookup
                    // Normalize to lowercase for consistent comparison
                    final matchingGroup = groupState.getGroupByHexId(
                      groupIdHex.toLowerCase(),
                    );
                    if (matchingGroup != null) {
                      groupState.setActiveGroup(matchingGroup);
                    }
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: CupertinoColors.systemIndigo.withOpacity(0.08),
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(11),
                      ),
                    ),
                    child: Row(
                      children: [
                        // Group photo
                        Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: CupertinoColors.systemGrey4,
                            image: groupPicture != null
                                ? DecorationImage(
                                    image: NetworkImage(groupPicture),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          child: groupPicture == null
                              ? const Icon(
                                  CupertinoIcons.person_2_fill,
                                  size: 12,
                                  color: CupertinoColors.systemGrey,
                                )
                              : null,
                        ),
                        const SizedBox(width: 8),
                        // Group name
                        Expanded(
                          child: Text(
                            groupName,
                            style: TextStyle(
                              color: CupertinoColors.systemIndigo.resolveFrom(
                                context,
                              ),
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        // Arrow indicator
                        Icon(
                          CupertinoIcons.chevron_right,
                          size: 14,
                          color: CupertinoColors.systemIndigo.withOpacity(0.6),
                        ),
                      ],
                    ),
                  ),
                ),
              // Main post content
              Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        _AuthorAvatar(pubkey: event.pubkey),
                        const SizedBox(width: 8),
                        // Show imported author name badge if this is an imported post
                        if (event.isImported) ...[
                          _ImportedAuthorBadge(
                            authorName: event.importedAuthorName ?? 'Unknown',
                          ),
                          const SizedBox(width: 8),
                        ] else ...[
                          Text(
                            displayName,
                            style: const TextStyle(
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          _formatDate(event.createdAt),
                          style: const TextStyle(
                            color: CupertinoColors.secondaryLabel,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    _RichContentText(
                      content: event.content,
                      onHashtagTap: onHashtagTap,
                      onMentionTap: onMentionTap,
                    ),
                    // Display attached images (NIP-92 imeta)
                    if (event.hasImages)
                      EventImages(images: event.imageInfoList),
                    // Link previews
                    ContentLinkPreviews(
                      content: event.content,
                      linkPreviewService: groupState.linkPreviewService,
                    ),
                    // Quoted post preview (if this is a quote post)
                    if (event.isQuotePost && event.quotedEventId != null)
                      QuotedPostPreview(quotedEventId: event.quotedEventId!),
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
                        QuoteButton(event: event, onPressed: onQuotePressed),
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Widget that renders text content with clickable URLs, hashtags, and mentions
class _RichContentText extends StatelessWidget {
  final String content;
  final void Function(String hashtag)? onHashtagTap;
  final void Function(String pubkey)? onMentionTap;

  const _RichContentText({
    required this.content,
    this.onHashtagTap,
    this.onMentionTap,
  });

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

    // Combined regex for URLs, hashtags, and mentions
    final urlRegex = LinkPreviewService.urlRegex;
    final hashtagRegex = NostrEventModel.hashtagRegex;
    final mentionRegex = NostrEventModel.mentionRegex;

    // Find all matches and sort by position
    final allMatches = <_ContentMatch>[];

    for (final match in urlRegex.allMatches(content)) {
      allMatches.add(
        _ContentMatch(match.start, match.end, 'url', match.group(0)!),
      );
    }

    for (final match in hashtagRegex.allMatches(content)) {
      allMatches.add(
        _ContentMatch(
          match.start,
          match.end,
          'hashtag',
          match.group(0)!,
          match.group(1),
        ),
      );
    }

    for (final match in mentionRegex.allMatches(content)) {
      allMatches.add(
        _ContentMatch(
          match.start,
          match.end,
          'mention',
          match.group(0)!,
          match.group(1),
        ),
      );
    }

    // Sort by start position
    allMatches.sort((a, b) => a.start.compareTo(b.start));

    // Remove overlapping matches (prefer URLs over hashtags/mentions)
    final filteredMatches = <_ContentMatch>[];
    int lastEnd = 0;
    for (final match in allMatches) {
      if (match.start >= lastEnd) {
        filteredMatches.add(match);
        lastEnd = match.end;
      }
    }

    int currentPos = 0;
    for (final match in filteredMatches) {
      // Add text before the match
      if (match.start > currentPos) {
        spans.add(TextSpan(text: content.substring(currentPos, match.start)));
      }

      switch (match.type) {
        case 'url':
          var url = match.text;
          if (url.startsWith('www.')) {
            url = 'https://$url';
          }
          final cleanUrl = _cleanUrl(url);
          spans.add(
            TextSpan(
              text: match.text,
              style: TextStyle(
                color: CupertinoColors.systemBlue.resolveFrom(context),
                decoration: TextDecoration.underline,
              ),
              recognizer: TapGestureRecognizer()
                ..onTap = () => _launchUrl(cleanUrl),
            ),
          );
          break;
        case 'hashtag':
          final hashtag = match.captured!;
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: GestureDetector(
                onTap: () {
                  if (onHashtagTap != null) {
                    onHashtagTap!(hashtag);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  margin: const EdgeInsets.symmetric(horizontal: 2),
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemIndigo.withOpacity(0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    hashtag,
                    style: TextStyle(
                      color: CupertinoColors.systemIndigo.resolveFrom(context),
                      fontWeight: FontWeight.w500,
                      fontSize: 14,
                      height: 1.0,
                    ),
                  ),
                ),
              ),
            ),
          );
          break;
        case 'mention':
          final username = match.captured!;
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: _MentionBadge(
                username: username,
                onTap: onMentionTap != null
                    ? () => onMentionTap!(username)
                    : null,
              ),
            ),
          );
          break;
      }

      currentPos = match.end;
    }

    // Add remaining text after last match
    if (currentPos < content.length) {
      spans.add(TextSpan(text: content.substring(currentPos)));
    }

    // If no matches found, just return the plain text
    if (spans.isEmpty) {
      spans.add(TextSpan(text: content));
    }

    return spans;
  }

  String _cleanUrl(String url) {
    final trailingChars = [
      '.',
      ',',
      '!',
      '?',
      ')',
      ']',
      '}',
      ';',
      ':',
      '"',
      "'",
    ];
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

/// Author avatar that displays profile photo by pubkey
class _AuthorAvatar extends StatefulWidget {
  final String pubkey;
  final double size;

  const _AuthorAvatar({required this.pubkey, this.size = 32});

  @override
  State<_AuthorAvatar> createState() => _AuthorAvatarState();
}

class _AuthorAvatarState extends State<_AuthorAvatar> {
  String? _profilePictureUrl;

  @override
  void initState() {
    super.initState();
    _loadProfilePicture();
  }

  Future<void> _loadProfilePicture() async {
    try {
      final profileState = context.read<ProfileState>();
      final profile = await profileState.getProfile(widget.pubkey);
      if (mounted && profile?.picture != null) {
        setState(() {
          _profilePictureUrl = profile!.picture;
        });
      }
    } catch (e) {
      // Silently fail - will show placeholder
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey4,
        shape: BoxShape.circle,
        image: _profilePictureUrl != null
            ? DecorationImage(
                image: NetworkImage(_profilePictureUrl!),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: _profilePictureUrl == null
          ? Icon(
              CupertinoIcons.person_fill,
              size: widget.size * 0.6,
              color: CupertinoColors.systemGrey,
            )
          : null,
    );
  }
}

/// Mention badge that displays username with profile photo
class _MentionBadge extends StatefulWidget {
  final String username;
  final VoidCallback? onTap;

  const _MentionBadge({required this.username, this.onTap});

  @override
  State<_MentionBadge> createState() => _MentionBadgeState();
}

class _MentionBadgeState extends State<_MentionBadge> {
  String? _profilePictureUrl;

  @override
  void initState() {
    super.initState();
    _loadProfilePicture();
  }

  Future<void> _loadProfilePicture() async {
    try {
      final profileState = context.read<ProfileState>();
      final profile = await profileState.searchByUsername(widget.username);
      if (mounted && profile?.picture != null) {
        setState(() {
          _profilePictureUrl = profile!.picture;
        });
      }
    } catch (e) {
      // Silently fail - will show placeholder
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: Container(
        padding: const EdgeInsets.only(left: 3, right: 8, top: 3, bottom: 3),
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: CupertinoColors.systemTeal.withOpacity(0.15),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Profile picture avatar
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: CupertinoColors.systemGrey4,
                shape: BoxShape.circle,
                image: _profilePictureUrl != null
                    ? DecorationImage(
                        image: NetworkImage(_profilePictureUrl!),
                        fit: BoxFit.cover,
                      )
                    : null,
              ),
              child: _profilePictureUrl == null
                  ? const Icon(
                      CupertinoIcons.person_fill,
                      size: 10,
                      color: CupertinoColors.systemGrey,
                    )
                  : null,
            ),
            const SizedBox(width: 4),
            Text(
              widget.username,
              style: TextStyle(
                color: CupertinoColors.systemTeal.resolveFrom(context),
                fontWeight: FontWeight.w500,
                fontSize: 14,
                height: 1.0,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Badge displayed for imported messages showing the original author name
class _ImportedAuthorBadge extends StatelessWidget {
  final String authorName;

  const _ImportedAuthorBadge({required this.authorName});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: CupertinoColors.systemOrange.withOpacity(0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: CupertinoColors.systemOrange.withOpacity(0.3),
          width: 0.5,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            CupertinoIcons.arrow_down_doc,
            size: 12,
            color: CupertinoColors.systemOrange.resolveFrom(context),
          ),
          const SizedBox(width: 4),
          Text(
            authorName,
            style: TextStyle(
              color: CupertinoColors.systemOrange.resolveFrom(context),
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: CupertinoColors.systemOrange.withOpacity(0.2),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              'Imported',
              style: TextStyle(
                color: CupertinoColors.systemOrange.resolveFrom(context),
                fontSize: 9,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Helper class to track content matches (URLs, hashtags, mentions)
class _ContentMatch {
  final int start;
  final int end;
  final String type;
  final String text;
  final String? captured;

  _ContentMatch(this.start, this.end, this.type, this.text, [this.captured]);
}

/// Collapsing group header delegate for SliverPersistentHeader
/// Creates a Twitter-style header that shrinks as you scroll
class _CollapsingGroupHeaderDelegate extends SliverPersistentHeaderDelegate {
  final MlsGroup group;
  final GroupAnnouncement? announcement;
  final double topPadding;
  final bool isAdmin;
  final VoidCallback? onEditTap;
  final VoidCallback? onSettingsTap;
  final bool hasFloatingOverlay;

  // Banner heights
  static const double _maxBannerHeight = 200.0;
  static const double _minBannerHeight = 100.0;
  // Profile photo and info section
  static const double _profilePhotoSize = 80.0;
  static const double _profileOverlap = 40.0;
  static const double _infoSectionHeight = 80.0;

  _CollapsingGroupHeaderDelegate({
    required this.group,
    this.announcement,
    required this.topPadding,
    required this.isAdmin,
    this.onEditTap,
    this.onSettingsTap,
    this.hasFloatingOverlay = false,
  });

  @override
  double get maxExtent =>
      topPadding + _maxBannerHeight + _profileOverlap + _infoSectionHeight;

  @override
  double get minExtent =>
      topPadding + _minBannerHeight + _profileOverlap + _infoSectionHeight;

  @override
  bool shouldRebuild(covariant _CollapsingGroupHeaderDelegate oldDelegate) {
    return group != oldDelegate.group ||
        announcement?.name != oldDelegate.announcement?.name ||
        announcement?.picture != oldDelegate.announcement?.picture ||
        announcement?.cover != oldDelegate.announcement?.cover ||
        announcement?.about != oldDelegate.announcement?.about ||
        topPadding != oldDelegate.topPadding ||
        isAdmin != oldDelegate.isAdmin ||
        hasFloatingOverlay != oldDelegate.hasFloatingOverlay;
  }

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    // Calculate the current banner height based on scroll
    final shrinkProgress = shrinkOffset / (maxExtent - minExtent);
    final clampedProgress = shrinkProgress.clamp(0.0, 1.0);
    final currentBannerHeight =
        _maxBannerHeight -
        ((_maxBannerHeight - _minBannerHeight) * clampedProgress);

    final groupName = announcement?.name ?? group.name;
    final groupPicture = announcement?.picture;
    final groupAbout = announcement?.about;
    final groupCover = announcement?.cover;

    // Profile photo scales down slightly when collapsed
    final photoScale = 1.0 - (clampedProgress * 0.2);
    final scaledPhotoSize = _profilePhotoSize * photoScale;

    return Container(
      color: CupertinoColors.systemBackground,
      child: Stack(
        children: [
          // Banner - extends to top of screen (cover photo or gradient fallback)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: topPadding + currentBannerHeight,
            child: groupCover != null
                ? Image.network(
                    groupCover,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) {
                      // Fallback to gradient if image fails to load
                      return Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              CupertinoColors.systemIndigo.withOpacity(0.6),
                              CupertinoColors.systemPurple.withOpacity(0.4),
                            ],
                          ),
                        ),
                      );
                    },
                  )
                : Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          CupertinoColors.systemIndigo.withOpacity(0.6),
                          CupertinoColors.systemPurple.withOpacity(0.4),
                        ],
                      ),
                    ),
                  ),
          ),
          // Settings button in top-right corner (admin only)
          // Offset to left when floating overlay buttons are present (mobile mode)
          // Use same structure as floating members button for alignment
          if (isAdmin && onSettingsTap != null)
            Positioned(
              top: topPadding + 8,
              right: hasFloatingOverlay ? 56 : 8,
              child: CupertinoButton(
                padding: const EdgeInsets.all(8),
                color: CupertinoColors.black.withOpacity(0.4),
                borderRadius: BorderRadius.circular(20),
                minSize: 36,
                onPressed: onSettingsTap,
                child: const Icon(
                  CupertinoIcons.gear_alt_fill,
                  size: 20,
                  color: CupertinoColors.white,
                ),
              ),
            ),
          // Profile photo overlapping the banner
          Positioned(
            left: 16,
            top: topPadding + currentBannerHeight - _profileOverlap,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: isAdmin ? onEditTap : null,
              child: Container(
                width: scaledPhotoSize,
                height: scaledPhotoSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: CupertinoColors.systemBackground,
                  border: Border.all(
                    color: CupertinoColors.systemBackground,
                    width: 4,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: CupertinoColors.black.withOpacity(0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: CupertinoColors.systemGrey4,
                          image: groupPicture != null
                              ? DecorationImage(
                                  image: NetworkImage(groupPicture),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: groupPicture == null
                            ? Center(
                                child: Icon(
                                  CupertinoIcons.person_2_fill,
                                  size: 36 * photoScale,
                                  color: CupertinoColors.systemGrey,
                                ),
                              )
                            : null,
                      ),
                    ),
                    // Edit badge for admins
                    if (isAdmin)
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          width: 24 * photoScale,
                          height: 24 * photoScale,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: CupertinoColors.activeBlue,
                            border: Border.all(
                              color: CupertinoColors.systemBackground,
                              width: 2,
                            ),
                          ),
                          child: Icon(
                            CupertinoIcons.pencil,
                            size: 12 * photoScale,
                            color: CupertinoColors.white,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          // Group name and about - positioned below the profile photo
          Positioned(
            left: 16,
            right: 16,
            top:
                topPadding +
                currentBannerHeight +
                _profileOverlap +
                8, // 8px spacing
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                GestureDetector(
                  onTap: isAdmin ? onEditTap : null,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Text(
                          groupName,
                          style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      if (isAdmin) ...[
                        const SizedBox(width: 8),
                        Icon(
                          CupertinoIcons.pencil,
                          size: 16,
                          color: CupertinoColors.activeBlue.resolveFrom(
                            context,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (groupAbout != null && groupAbout.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    groupAbout,
                    style: const TextStyle(
                      fontSize: 14,
                      color: CupertinoColors.secondaryLabel,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          // Bottom divider
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(height: 0.5, color: CupertinoColors.separator),
          ),
        ],
      ),
    );
  }
}

/// Stateful wrapper for the collapsing group header to manage admin status
class _GroupHeaderSliver extends StatefulWidget {
  final MlsGroup group;
  final GroupState groupState;

  const _GroupHeaderSliver({required this.group, required this.groupState});

  @override
  State<_GroupHeaderSliver> createState() => _GroupHeaderSliverState();
}

class _GroupHeaderSliverState extends State<_GroupHeaderSliver> {
  bool _isAdmin = false;

  String _groupIdToHex(MlsGroup group) {
    return group.id.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  @override
  void initState() {
    super.initState();
    _checkAdminStatus();
  }

  @override
  void didUpdateWidget(_GroupHeaderSliver oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_groupIdToHex(oldWidget.group) != _groupIdToHex(widget.group)) {
      _checkAdminStatus();
    }
  }

  Future<void> _checkAdminStatus() async {
    final groupIdHex = _groupIdToHex(widget.group);
    final isAdmin = await widget.groupState.isGroupAdmin(groupIdHex);
    if (mounted && _groupIdToHex(widget.group) == groupIdHex) {
      setState(() {
        _isAdmin = isAdmin;
      });
    }
  }

  void _showEditModal() {
    final groupIdHex = _groupIdToHex(widget.group);
    final announcement = widget.groupState.discoveredGroups
        .cast<GroupAnnouncement?>()
        .firstWhere((a) => a?.mlsGroupId == groupIdHex, orElse: () => null);

    final effectiveAnnouncement =
        announcement ??
        GroupAnnouncement(
          eventId: '',
          pubkey: '',
          name: widget.group.name,
          mlsGroupId: groupIdHex,
          createdAt: DateTime.now(),
        );

    showEditGroupModal(context, effectiveAnnouncement, onSaved: () {});
  }

  void _showSettingsModal() {
    final groupIdHex = _groupIdToHex(widget.group);
    final announcement = widget.groupState.discoveredGroups
        .cast<GroupAnnouncement?>()
        .firstWhere((a) => a?.mlsGroupId == groupIdHex, orElse: () => null);

    final effectiveAnnouncement =
        announcement ??
        GroupAnnouncement(
          eventId: '',
          pubkey: '',
          name: widget.group.name,
          mlsGroupId: groupIdHex,
          createdAt: DateTime.now(),
        );

    showGroupSettingsModal(context, effectiveAnnouncement);
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;
    final screenWidth = MediaQuery.of(context).size.width;
    final isNarrowScreen = screenWidth <= 1000;

    // Get the announcement for this group
    final groupIdHex = _groupIdToHex(widget.group);
    final announcement = widget.groupState.discoveredGroups
        .cast<GroupAnnouncement?>()
        .firstWhere((a) => a?.mlsGroupId == groupIdHex, orElse: () => null);

    return SliverPersistentHeader(
      pinned: true,
      delegate: _CollapsingGroupHeaderDelegate(
        group: widget.group,
        announcement: announcement,
        topPadding: topPadding,
        isAdmin: _isAdmin,
        onEditTap: _showEditModal,
        onSettingsTap: _isAdmin ? _showSettingsModal : null,
        hasFloatingOverlay: isNarrowScreen,
      ),
    );
  }
}

/// Indicator showing the current hashtag filter with clear button
class _HashtagFilterIndicator extends StatelessWidget {
  final String hashtag;
  final VoidCallback onClear;

  const _HashtagFilterIndicator({required this.hashtag, required this.onClear});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: CupertinoColors.systemIndigo.withOpacity(0.1),
        border: const Border(
          bottom: BorderSide(color: CupertinoColors.separator, width: 0.5),
        ),
      ),
      child: Row(
        children: [
          Icon(
            CupertinoIcons.number,
            size: 16,
            color: CupertinoColors.systemIndigo.resolveFrom(context),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Filtering by #$hashtag',
              style: TextStyle(
                color: CupertinoColors.systemIndigo.resolveFrom(context),
                fontWeight: FontWeight.w500,
                fontSize: 14,
              ),
            ),
          ),
          CupertinoButton(
            padding: EdgeInsets.zero,
            minSize: 28,
            onPressed: onClear,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: CupertinoColors.systemIndigo.withOpacity(0.2),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    CupertinoIcons.xmark,
                    size: 12,
                    color: CupertinoColors.systemIndigo.resolveFrom(context),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    'Clear',
                    style: TextStyle(
                      color: CupertinoColors.systemIndigo.resolveFrom(context),
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Modal to show profile info for a mentioned user (by username)
class _MentionProfileModal extends StatefulWidget {
  final String username;

  const _MentionProfileModal({required this.username});

  @override
  State<_MentionProfileModal> createState() => _MentionProfileModalState();
}

class _MentionProfileModalState extends State<_MentionProfileModal> {
  ProfileData? _profile;
  bool _isLoading = true;
  bool _notFound = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    final profileState = context.read<ProfileState>();
    final profile = await profileState.searchByUsername(widget.username);

    if (mounted) {
      setState(() {
        _profile = profile;
        _isLoading = false;
        _notFound = profile == null;
      });
    }
  }

  String _truncatePubkey(String pubkey) {
    if (pubkey.length <= 16) return pubkey;
    return '${pubkey.substring(0, 8)}...${pubkey.substring(pubkey.length - 8)}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 280,
      decoration: const BoxDecoration(
        color: CupertinoColors.systemBackground,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // Handle bar
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: CupertinoColors.systemGrey3,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            // Profile content
            if (_isLoading)
              const Expanded(child: Center(child: CupertinoActivityIndicator()))
            else if (_notFound)
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        CupertinoIcons.person_crop_circle_badge_xmark,
                        size: 48,
                        color: CupertinoColors.systemGrey,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '@${widget.username}',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      const Text(
                        'User not found',
                        style: TextStyle(
                          fontSize: 14,
                          color: CupertinoColors.secondaryLabel,
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    // Profile icon placeholder
                    Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: CupertinoColors.systemTeal.withOpacity(0.2),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        CupertinoIcons.person_fill,
                        size: 32,
                        color: CupertinoColors.systemTeal,
                      ),
                    ),
                    const SizedBox(height: 12),
                    // Username
                    Text(
                      _profile?.getUsername() ?? widget.username,
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Pubkey
                    Text(
                      _truncatePubkey(_profile?.pubkey ?? ''),
                      style: const TextStyle(
                        fontSize: 12,
                        color: CupertinoColors.secondaryLabel,
                      ),
                    ),
                    if (_profile?.about != null &&
                        _profile!.about!.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        _profile!.about!,
                        style: const TextStyle(
                          fontSize: 14,
                          color: CupertinoColors.secondaryLabel,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 16),
                    // Copy username button
                    if (_profile != null)
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 8,
                        ),
                        color: CupertinoColors.systemGrey5,
                        borderRadius: BorderRadius.circular(20),
                        onPressed: () {
                          final username = _profile!.getUsername();
                          Clipboard.setData(ClipboardData(text: '@$username'));
                          Navigator.of(context).pop();
                        },
                        child: const Text(
                          'Copy Username',
                          style: TextStyle(
                            color: CupertinoColors.label,
                            fontSize: 14,
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

class _ComposeMessageWidget extends StatelessWidget {
  final TextEditingController controller;
  final bool isPublishing;
  final String? error;
  final VoidCallback onPublish;
  final VoidCallback onErrorDismiss;
  final String? placeholder;
  final VoidCallback? onPickImage;
  final Uint8List? selectedImageBytes;
  final VoidCallback? onClearImage;
  final bool showImagePicker;

  const _ComposeMessageWidget({
    required this.controller,
    required this.isPublishing,
    this.error,
    required this.onPublish,
    required this.onErrorDismiss,
    this.placeholder,
    this.onPickImage,
    this.selectedImageBytes,
    this.onClearImage,
    this.showImagePicker = false,
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
            // Selected image preview
            if (selectedImageBytes != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Container(
                  padding: const EdgeInsets.fromLTRB(8.0, 8.0, 8.0, 0),
                  child: Stack(
                    children: [
                      ClipRRect(
                        borderRadius: BorderRadius.circular(12.0),
                        child: Image.memory(
                          selectedImageBytes!,
                          height: 80,
                          width: 80,
                          fit: BoxFit.cover,
                        ),
                      ),
                      Positioned(
                        top: 4,
                        right: 4,
                        child: CupertinoButton(
                          padding: EdgeInsets.zero,
                          minSize: 0,
                          onPressed: onClearImage,
                          child: Container(
                            width: 20,
                            height: 20,
                            decoration: BoxDecoration(
                              color: CupertinoColors.black.withOpacity(0.6),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              CupertinoIcons.xmark,
                              color: CupertinoColors.white,
                              size: 12,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Image picker button
                  if (showImagePicker && onPickImage != null)
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      minSize: 0,
                      onPressed: isPublishing ? null : onPickImage,
                      child: Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: CupertinoColors.systemGrey5,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          CupertinoIcons.photo,
                          color: isPublishing
                              ? CupertinoColors.systemGrey
                              : CupertinoColors.systemBlue,
                          size: 20,
                        ),
                      ),
                    ),
                  if (showImagePicker && onPickImage != null)
                    const SizedBox(width: 8),
                  Expanded(
                    child: Focus(
                      onKeyEvent: (node, event) {
                        final isDesktop =
                            defaultTargetPlatform == TargetPlatform.macOS ||
                            defaultTargetPlatform == TargetPlatform.windows ||
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

/// View for exploring and joining groups (displayed in feed area)
class _ExploreGroupsView extends StatefulWidget {
  final VoidCallback onJoinRequested;

  const _ExploreGroupsView({required this.onJoinRequested});

  @override
  State<_ExploreGroupsView> createState() => _ExploreGroupsViewState();
}

class _ExploreGroupsViewState extends State<_ExploreGroupsView> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  final Set<String> _requestedGroups = {};
  final Set<String> _requestingGroups = {};
  final Map<String, int> _memberCounts = {};
  bool _isLoadingMemberCounts = false;
  Map<String, bool> _memberships = {};
  bool _membershipsLoaded = false;
  List<GroupAnnouncement> _fetchedGroups = [];
  bool _isLoadingGroups = false;
  bool _isSearching = false;
  Timer? _debounceTimer;
  int _lastMembershipCacheVersion = -1;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
    _loadInitialData();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Check if membership cache was invalidated (e.g., user joined a group)
    final groupState = context.read<GroupState>();
    if (_lastMembershipCacheVersion != groupState.membershipCacheVersion) {
      _lastMembershipCacheVersion = groupState.membershipCacheVersion;
      // Reload memberships to update which groups the user is a member of
      if (_membershipsLoaded) {
        _refreshMemberships();
      }
    }
  }

  Future<void> _refreshMemberships() async {
    final groupState = context.read<GroupState>();
    if (!groupState.isConnected) return;

    try {
      final memberships = await groupState.getUserGroupMemberships();
      if (mounted) {
        setState(() {
          _memberships = memberships;
        });
      }
    } catch (e) {
      // Silently fail
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchController.text.toLowerCase();

    // Cancel previous debounce timer
    _debounceTimer?.cancel();

    if (query.isEmpty) {
      // If cleared, reload initial 20 groups
      setState(() {
        _searchQuery = '';
        _isSearching = false;
      });
      _loadInitialGroups();
      return;
    }

    // Show searching state immediately
    setState(() {
      _searchQuery = query;
      _isSearching = true;
    });

    // Debounce the actual search (300ms)
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      _performSearch(query);
    });
  }

  Future<void> _loadInitialGroups() async {
    final groupState = context.read<GroupState>();

    setState(() => _isLoadingGroups = true);

    try {
      final groups = await groupState.fetchGroupsFromRelay(
        limit: 20,
        useCache: false,
      );
      if (mounted) {
        setState(() {
          _fetchedGroups = groups;
          _isLoadingGroups = false;
        });
        _loadMemberCounts();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoadingGroups = false);
      }
    }
  }

  Future<void> _loadInitialData() async {
    final groupState = context.read<GroupState>();

    setState(() => _isLoadingGroups = true);

    // Load memberships first
    if (groupState.isConnected) {
      try {
        final memberships = await groupState.getUserGroupMemberships();
        if (mounted) {
          setState(() {
            _memberships = memberships;
            _membershipsLoaded = true;
          });
        }
      } catch (e) {
        if (mounted) {
          setState(() => _membershipsLoaded = true);
        }
      }
    }

    // Fetch latest 20 groups from relay
    await _loadInitialGroups();
  }

  Future<void> _performSearch(String query) async {
    if (!mounted) return;

    final groupState = context.read<GroupState>();

    try {
      // Fetch all groups from relay for search
      final allGroups = await groupState.fetchGroupsFromRelay(
        limit: 1000,
        useCache: false,
      );

      if (mounted && _searchQuery == query) {
        // Filter by search query
        final filteredGroups = allGroups.where((g) {
          final name = g.name?.toLowerCase() ?? '';
          final about = g.about?.toLowerCase() ?? '';
          return name.contains(query) || about.contains(query);
        }).toList();

        setState(() {
          _fetchedGroups = filteredGroups;
          _isSearching = false;
        });
        _loadMemberCounts();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isSearching = false);
      }
    }
  }

  Future<void> _loadMemberCounts() async {
    if (!mounted) return;
    setState(() => _isLoadingMemberCounts = true);

    final groupState = context.read<GroupState>();
    final explorableGroups = _getExplorableGroups();

    for (final announcement in explorableGroups) {
      if (announcement.mlsGroupId != null) {
        try {
          final members = await groupState.getGroupMembers(
            announcement.mlsGroupId!,
          );
          if (mounted) {
            setState(() {
              _memberCounts[announcement.mlsGroupId!] = members.length;
            });
          }
        } catch (e) {
          // Silently fail for individual groups
        }
      }
    }

    if (mounted) {
      setState(() => _isLoadingMemberCounts = false);
    }
  }

  List<GroupAnnouncement> _getExplorableGroups() {
    final explorableGroups = <GroupAnnouncement>[];

    for (final announcement in _fetchedGroups) {
      final groupIdHex = announcement.mlsGroupId;
      if (groupIdHex == null) continue;

      // Skip all personal groups (not just user's own)
      if (announcement.isPersonal) continue;

      // Only show groups user is NOT a member of
      final isMember = _memberships[groupIdHex] ?? false;
      if (isMember) continue;

      explorableGroups.add(announcement);
    }

    // Sort by creation date (newest first)
    explorableGroups.sort((a, b) => b.createdAt.compareTo(a.createdAt));

    return explorableGroups;
  }

  Future<void> _requestToJoin(GroupAnnouncement announcement) async {
    final groupIdHex = announcement.mlsGroupId;
    if (groupIdHex == null) return;

    setState(() {
      _requestingGroups.add(groupIdHex);
    });

    try {
      final groupState = context.read<GroupState>();
      await groupState.requestToJoinGroup(groupIdHex);

      if (mounted) {
        setState(() {
          _requestedGroups.add(groupIdHex);
          _requestingGroups.remove(groupIdHex);
        });
        widget.onJoinRequested();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _requestingGroups.remove(groupIdHex);
        });
      }
    }
  }

  String _getInitials(String name) {
    final words = name.trim().split(RegExp(r'\s+'));
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      return words[0].substring(0, words[0].length.clamp(0, 2)).toUpperCase();
    }
    return '${words[0][0]}${words[1][0]}'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    // Consumer ensures rebuild when GroupState notifies (e.g., membership changes)
    return Consumer<GroupState>(
      builder: (context, groupState, child) {
        // Check for membership updates
        if (_lastMembershipCacheVersion != groupState.membershipCacheVersion) {
          _lastMembershipCacheVersion = groupState.membershipCacheVersion;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _refreshMemberships();
          });
        }

        final explorableGroups = _getExplorableGroups();
        final isLoading = _isLoadingGroups || !_membershipsLoaded;

        return Column(
          children: [
            // Search field
            Padding(
              padding: const EdgeInsets.all(16),
              child: CupertinoSearchTextField(
                controller: _searchController,
                placeholder: 'Search groups on relay...',
              ),
            ),
            // Loading indicator for search
            if (_isSearching)
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: CupertinoActivityIndicator(radius: 10),
              ),
            // Groups list
            Expanded(
              child: isLoading
                  ? const Center(child: CupertinoActivityIndicator())
                  : explorableGroups.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _searchQuery.isNotEmpty
                                ? CupertinoIcons.search
                                : CupertinoIcons.person_3,
                            size: 48,
                            color: CupertinoColors.systemGrey3,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _searchQuery.isNotEmpty
                                ? 'No groups match your search'
                                : 'No groups to explore',
                            style: const TextStyle(
                              color: CupertinoColors.secondaryLabel,
                              fontSize: 16,
                            ),
                          ),
                          if (_searchQuery.isEmpty) ...[
                            const SizedBox(height: 4),
                            const Text(
                              'You\'re already a member of all groups',
                              style: TextStyle(
                                color: CupertinoColors.tertiaryLabel,
                                fontSize: 14,
                              ),
                            ),
                          ],
                        ],
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: explorableGroups.length,
                      itemBuilder: (context, index) {
                        final announcement = explorableGroups[index];
                        final groupIdHex = announcement.mlsGroupId;
                        final isRequesting =
                            groupIdHex != null &&
                            _requestingGroups.contains(groupIdHex);
                        final hasRequested =
                            groupIdHex != null &&
                            _requestedGroups.contains(groupIdHex);
                        final memberCount = groupIdHex != null
                            ? _memberCounts[groupIdHex]
                            : null;

                        return _ExploreGroupListItem(
                          announcement: announcement,
                          initials: _getInitials(
                            announcement.name ?? 'Unknown',
                          ),
                          memberCount: memberCount,
                          isRequesting: isRequesting,
                          hasRequested: hasRequested,
                          onRequestJoin: () => _requestToJoin(announcement),
                        );
                      },
                    ),
            ),
            if (_isLoadingMemberCounts)
              const Padding(
                padding: EdgeInsets.all(8),
                child: CupertinoActivityIndicator(radius: 8),
              ),
          ],
        );
      },
    );
  }
}

/// Individual group item in the explore list
class _ExploreGroupListItem extends StatelessWidget {
  final GroupAnnouncement announcement;
  final String initials;
  final int? memberCount;
  final bool isRequesting;
  final bool hasRequested;
  final VoidCallback onRequestJoin;

  const _ExploreGroupListItem({
    required this.announcement,
    required this.initials,
    required this.memberCount,
    required this.isRequesting,
    required this.hasRequested,
    required this.onRequestJoin,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          // Group avatar
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: CupertinoColors.systemGrey4,
              borderRadius: BorderRadius.circular(24),
              image: announcement.picture != null
                  ? DecorationImage(
                      image: NetworkImage(announcement.picture!),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: announcement.picture == null
                ? Center(
                    child: Text(
                      initials,
                      style: const TextStyle(
                        color: CupertinoColors.systemGrey,
                        fontWeight: FontWeight.w600,
                        fontSize: 16,
                      ),
                    ),
                  )
                : null,
          ),
          const SizedBox(width: 12),
          // Group info
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  announcement.name ?? 'Unnamed Group',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 16,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (announcement.about != null &&
                    announcement.about!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    announcement.about!,
                    style: const TextStyle(
                      color: CupertinoColors.secondaryLabel,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 4),
                Row(
                  children: [
                    const Icon(
                      CupertinoIcons.person_2,
                      size: 14,
                      color: CupertinoColors.tertiaryLabel,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      memberCount != null ? '$memberCount members' : '...',
                      style: const TextStyle(
                        color: CupertinoColors.tertiaryLabel,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Request to join button
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            minSize: 0,
            color: hasRequested
                ? CupertinoColors.systemGrey4
                : CupertinoColors.activeBlue,
            borderRadius: BorderRadius.circular(16),
            onPressed: hasRequested || isRequesting ? null : onRequestJoin,
            child: isRequesting
                ? const CupertinoActivityIndicator(
                    radius: 8,
                    color: CupertinoColors.white,
                  )
                : Text(
                    hasRequested ? 'Requested' : 'Join',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: hasRequested
                          ? CupertinoColors.secondaryLabel
                          : CupertinoColors.white,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// Welcome card shown to new users who haven't joined any groups yet
class _WelcomeCard extends StatelessWidget {
  final VoidCallback onCreateGroup;
  final VoidCallback onExploreGroups;

  const _WelcomeCard({
    required this.onCreateGroup,
    required this.onExploreGroups,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            CupertinoColors.activeBlue.withOpacity(0.1),
            CupertinoColors.systemIndigo.withOpacity(0.1),
          ],
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: CupertinoColors.activeBlue.withOpacity(0.3),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: CupertinoColors.activeBlue.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  CupertinoIcons.sparkles,
                  color: CupertinoColors.activeBlue,
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Welcome to Comunifi!',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Create your first group or explore existing ones to get started. Groups are private spaces where you can share posts with members.',
            style: TextStyle(
              fontSize: 15,
              color: CupertinoColors.secondaryLabel,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  color: CupertinoColors.activeBlue,
                  borderRadius: BorderRadius.circular(10),
                  onPressed: onCreateGroup,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        CupertinoIcons.plus_circle_fill,
                        size: 18,
                        color: CupertinoColors.white,
                      ),
                      SizedBox(width: 6),
                      Text(
                        'Create Group',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: CupertinoColors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  color: CupertinoColors.systemGrey5,
                  borderRadius: BorderRadius.circular(10),
                  onPressed: onExploreGroups,
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        CupertinoIcons.search,
                        size: 18,
                        color: CupertinoColors.activeBlue,
                      ),
                      SizedBox(width: 6),
                      Text(
                        'Explore',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: CupertinoColors.activeBlue,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
