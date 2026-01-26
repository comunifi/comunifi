import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:comunifi/theme/colors.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/services/mls/mls_group.dart';
import 'package:comunifi/screens/feed/create_group_modal.dart';
import 'package:comunifi/screens/feed/pending_invitations_modal.dart';
import 'package:comunifi/l10n/app_localizations.dart';

/// Helper class to combine discovered and local groups
class _GroupItem {
  final GroupAnnouncement? announcement;
  final MlsGroup? mlsGroup;
  final bool isMyGroup;

  _GroupItem({this.announcement, this.mlsGroup, required this.isMyGroup});
}

class GroupsSidebar extends StatefulWidget {
  final VoidCallback onClose;
  final bool showCloseButton;

  const GroupsSidebar({
    super.key,
    required this.onClose,
    this.showCloseButton = true,
  });

  @override
  State<GroupsSidebar> createState() => _GroupsSidebarState();
}

class _GroupsSidebarState extends State<GroupsSidebar> {
  bool _isFetchingGroups = false;
  String? _userNostrPubkey;
  bool _hasFetchedOnConnect = false;
  Map<String, bool> _memberships = {};
  bool _membershipsLoaded = false;
  int _lastMembershipVersion = 0;

  @override
  void initState() {
    super.initState();
    _loadUserPubkey();
    _loadFromCache(); // Load from cache first for instant display
    // Don't fetch from network here - let build() method handle it when connected
    // This prevents unnecessary reloads when widget is preserved with stable key
  }

  Future<void> _loadUserPubkey() async {
    final groupState = context.read<GroupState>();

    String? pubkey;
    for (int attempt = 0; attempt < 5; attempt++) {
      pubkey = await groupState.getNostrPublicKey();
      if (pubkey != null) break;
      if (attempt < 4) {
        await Future.delayed(Duration(milliseconds: 200 * (1 << attempt)));
      }
    }

    if (mounted) {
      setState(() {
        _userNostrPubkey = pubkey;
      });
    }
  }

  /// Load memberships and group announcements from cache first (instant display)
  Future<void> _loadFromCache() async {
    final groupState = context.read<GroupState>();

    try {
      // Load memberships from cache (will load from cache first, then network in background)
      final memberships = await groupState.getUserGroupMemberships();
      if (mounted) {
        setState(() {
          _memberships = memberships;
          _membershipsLoaded = true;
        });
      }

      // Load group announcements from cache
      final cachedAnnouncements =
          await groupState.loadGroupAnnouncementsFromCache();
      if (mounted && cachedAnnouncements.isNotEmpty) {
        // Update discovered groups with cached announcements
        // This will show groups instantly from cache
        groupState.setDiscoveredGroupsFromCache(cachedAnnouncements);
      }
    } catch (e) {
      debugPrint('Failed to load from cache: $e');
      // Silently fail - will fall back to network fetch
    }
  }

  Future<void> _loadMemberships() async {
    final groupState = context.read<GroupState>();

    try {
      // This will use cache if available, then fetch from network in background
      final memberships = await groupState.getUserGroupMemberships();
      if (mounted) {
        setState(() {
          _memberships = memberships;
          _membershipsLoaded = true;
        });
      }
    } catch (e) {
      // Silently fail - will fall back to showing all local groups
    }
  }

  Future<void> _fetchGroupsFromRelay() async {
    final groupState = context.read<GroupState>();
    if (!groupState.isConnected || _isFetchingGroups) return;

    // Don't fetch if we already have groups loaded (prevents clearing cache unnecessarily)
    // Only fetch if we don't have groups or if explicitly needed (cache invalidation)
    if (groupState.discoveredGroups.isNotEmpty && _membershipsLoaded) {
      // We already have groups and memberships - skip fetch to preserve cache
      return;
    }

    setState(() => _isFetchingGroups = true);

    try {
      // Fetch from network in background (cache already displayed)
      // refreshDiscoveredGroups now preserves existing data, so this is safe
      await groupState.refreshDiscoveredGroups(limit: 1000);
      // Also refresh memberships when fetching groups
      await _loadMemberships();
    } catch (e) {
      // Silently fail - cache is already displayed
      debugPrint('Failed to fetch groups from relay: $e');
    } finally {
      if (mounted) setState(() => _isFetchingGroups = false);
    }
  }

  void _showCreateGroupModal() {
    showCupertinoModalPopup(
      context: context,
      builder: (context) => CreateGroupModal(
        onCreated: () {
          // Invalidate membership cache since we just created a group
          final groupState = context.read<GroupState>();
          groupState.invalidateMembershipCache();
          _membershipsLoaded = false;
          _fetchGroupsFromRelay();
        },
      ),
    );
  }

  void _showPendingInvitationsModal() {
    showCupertinoModalPopup(
      context: context,
      builder: (context) => const PendingInvitationsModal(),
    );
  }

  void _showEditGroupModal(GroupAnnouncement announcement) {
    showCupertinoModalPopup(
      context: context,
      builder: (context) => _EditGroupModal(
        announcement: announcement,
        onSaved: () {
          _fetchGroupsFromRelay();
        },
      ),
    );
  }

  void _toggleExploreMode() {
    final groupState = context.read<GroupState>();
    groupState.setExploreMode(!groupState.isExploreMode);
  }

  void _selectGroup(MlsGroup? group) {
    final groupState = context.read<GroupState>();
    if (group == null) {
      // Global feed selected - always deselect active group
      groupState.setActiveGroup(null);
    } else if (groupState.activeGroup?.id.bytes.toString() ==
        group.id.bytes.toString()) {
      // Already selected - deselect to global
      groupState.setActiveGroup(null);
    } else {
      groupState.setActiveGroup(group);
    }
    // Only close sidebar when selecting a specific group, not global feed
    if (group != null) {
      widget.onClose();
    }
  }

  List<_GroupItem> _buildGroupList(GroupState groupState) {
    final allGroups = <_GroupItem>[];
    final addedGroupIds = <String>{};

    // HYBRID APPROACH:
    // 1. PRIMARY: Use local MLS groups (if you have the MLS group, you're a member via Welcome)
    // 2. SECONDARY: Also check NIP-29 memberships (for groups where Welcome hasn't been processed yet)

    // Step 1: Add all local MLS groups (excluding personal groups)
    for (final mlsGroup in groupState.groups) {
      final groupIdHex = mlsGroup.id.bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join()
          .toLowerCase();

      // Get announcement for metadata (name, picture, etc.)
      final announcement = groupState.getGroupAnnouncementByHexId(groupIdHex);

      // Skip ALL personal groups (not just user's own)
      if (announcement != null && announcement.isPersonal) {
        continue;
      }
      // No announcement - skip if it looks like a personal group by name
      if (announcement == null &&
          _userNostrPubkey != null &&
          mlsGroup.name.toLowerCase().contains(_userNostrPubkey!.substring(0, 8).toLowerCase())) {
        continue;
      }

      final isCreator = announcement?.pubkey == _userNostrPubkey;
      addedGroupIds.add(groupIdHex);

      allGroups.add(
        _GroupItem(
          announcement: announcement,
          mlsGroup: mlsGroup,
          isMyGroup: isCreator,
        ),
      );
    }

    // Step 2: Also add groups from NIP-29 memberships (in case MLS group not loaded yet)
    for (final announcement in groupState.discoveredGroups) {
      final groupIdHex = announcement.mlsGroupId;
      if (groupIdHex == null) continue;

      final normalizedGroupId = groupIdHex.toLowerCase();

      // Skip if already added from MLS groups
      if (addedGroupIds.contains(normalizedGroupId)) {
        continue;
      }

      // Skip ALL personal groups (not just user's own)
      if (announcement.isPersonal) {
        continue;
      }

      // Check NIP-29 membership
      final isMember =
          _memberships[groupIdHex] ?? _memberships[normalizedGroupId] ?? false;
      if (!isMember) {
        continue;
      }

      // This group has NIP-29 membership but no MLS group yet (Welcome pending)
      final isCreator = announcement.pubkey == _userNostrPubkey;

      allGroups.add(
        _GroupItem(
          announcement: announcement,
          mlsGroup: null, // No MLS group yet
          isMyGroup: isCreator,
        ),
      );
    }

    debugPrint(
      'GroupsSidebar._buildGroupList: ${groupState.groups.length} MLS groups, ${_memberships.length} memberships, showing ${allGroups.length}',
    );

    // Sort by creation date (newest first)
    allGroups.sort((a, b) {
      final aDate =
          a.announcement?.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      final bDate =
          b.announcement?.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
      return bDate.compareTo(aDate);
    });

    return allGroups;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<GroupState>(
      builder: (context, groupState, child) {
        // Auto-fetch on connect
        if (groupState.isConnected && !_hasFetchedOnConnect) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _hasFetchedOnConnect = true;
            _fetchGroupsFromRelay();
          });
        } else if (!groupState.isConnected) {
          _hasFetchedOnConnect = false;
          _membershipsLoaded = false;
        }

        // Reload memberships and groups when cache is invalidated (e.g., after joining a group)
        if (groupState.membershipCacheVersion != _lastMembershipVersion) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _lastMembershipVersion = groupState.membershipCacheVersion;
            _membershipsLoaded = false;
            // Refresh both memberships and discovered groups to show newly joined groups
            _fetchGroupsFromRelay();
          });
        }

        final allGroups = _buildGroupList(groupState);
        final isGlobalFeed =
            groupState.activeGroup == null && !groupState.isExploreMode;
        final isExploreMode = groupState.isExploreMode;

        // Extra top padding for macOS to account for hidden title bar
        final isMacOS = !kIsWeb && Platform.isMacOS;
        final topPadding = isMacOS ? 36.0 : 8.0;

        return SafeArea(
          child: Container(
            width: 108,
            decoration: BoxDecoration(
              color: AppColors.surface,
              border: Border(
                right: BorderSide(color: AppColors.separator, width: 0.5),
              ),
            ),
            child: Column(
              children: [
                SizedBox(height: topPadding),
                // Create group button with pending invitations badge
                Center(
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      GestureDetector(
                        onTap: _showCreateGroupModal,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 56,
                              height: 56,
                              decoration: BoxDecoration(
                                color: AppColors.chipBackground,
                                borderRadius: BorderRadius.circular(28),
                              ),
                              child: const Icon(
                                CupertinoIcons.plus,
                                color: AppColors.primary,
                                size: 28,
                              ),
                            ),
                            const SizedBox(height: 2),
                            const Text(
                              'New',
                              style: TextStyle(
                                fontSize: 10,
                                color: AppColors.secondaryLabel,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Pending invitations badge
                      if (groupState.pendingInvitationCount > 0)
                        Positioned(
                          top: -4,
                          right: -4,
                          child: GestureDetector(
                            onTap: _showPendingInvitationsModal,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.primary,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: AppColors.surface,
                                  width: 2,
                                ),
                              ),
                              constraints: const BoxConstraints(
                                minWidth: 20,
                                minHeight: 20,
                              ),
                              child: Center(
                                child: Text(
                                  groupState.pendingInvitationCount > 99
                                      ? '99+'
                                      : '${groupState.pendingInvitationCount}',
                                  style: const TextStyle(
                                    color: CupertinoColors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // Explore button
                Center(
                  child: GestureDetector(
                    onTap: _toggleExploreMode,
                    child: _ExploreIcon(isActive: isExploreMode),
                  ),
                ),
                const SizedBox(height: 8),
                // Global feed button
                Center(
                  child: GestureDetector(
                    onTap: () => _selectGroup(null),
                    child: _GlobalFeedIcon(isActive: isGlobalFeed),
                  ),
                ),
                const SizedBox(height: 4),
                // Divider
                Container(
                  width: 40,
                  height: 2,
                  decoration: BoxDecoration(
                    color: AppColors.separator,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
                const SizedBox(height: 4),
                // Groups list
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    itemCount: allGroups.length,
                    itemBuilder: (context, index) {
                      final item = allGroups[index];
                      final announcement = item.announcement;
                      final mlsGroup = item
                          .mlsGroup; // May be null for groups needing recovery

                      final activeGroupId = groupState.activeGroup?.id.bytes
                          .toString();
                      final groupId = mlsGroup?.id.bytes.toString();
                      final isActive =
                          activeGroupId != null &&
                          groupId != null &&
                          activeGroupId == groupId;

                      final groupName = announcement?.name ?? mlsGroup?.name;
                      final pictureUrl = announcement?.picture;
                      final needsRecovery = mlsGroup == null;

                      return _GroupIconButton(
                        onTap: mlsGroup != null
                            ? () => _selectGroup(mlsGroup)
                            : () {
                                // Group is a member but no MLS state yet
                                // This can happen if Welcome message hasn't been received
                                debugPrint(
                                  'Group ${announcement?.name} is a member but MLS state not available yet',
                                );
                                // Could show a message or try to recover
                              },
                        onLongPress: announcement != null
                            ? () => _showEditGroupModal(announcement)
                            : null,
                        isActive: isActive,
                        child: _GroupAvatar(
                          name: groupName,
                          pictureUrl: pictureUrl,
                          isActive: isActive,
                          isMember: true,
                          needsRecovery: needsRecovery,
                        ),
                      );
                    },
                  ),
                ),
                // Loading indicator
                if (_isFetchingGroups ||
                    groupState.isLoadingGroups ||
                    groupState.isLoading ||
                    (groupState.isConnected && !_membershipsLoaded))
                  const Padding(
                    padding: EdgeInsets.all(8),
                    child: CupertinoActivityIndicator(radius: 8),
                  ),
                const SizedBox(height: 4),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Explore icon (search) with label
class _ExploreIcon extends StatelessWidget {
  final bool isActive;

  const _ExploreIcon({required this.isActive});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: isActive
                ? AppColors.primary
                : AppColors.chipBackground,
            borderRadius: BorderRadius.circular(isActive ? 16 : 28),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: AppColors.primary.withOpacity(0.4),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Icon(
            CupertinoIcons.search,
            color: isActive
                ? CupertinoColors.white
                : AppColors.primary,
            size: 28,
          ),
        ),
        const SizedBox(height: 2),
        Builder(
          builder: (context) {
            final localizations = AppLocalizations.of(context);
            return Text(
              localizations?.explore ?? 'Explore',
              style: TextStyle(
                fontSize: 10,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                color: isActive
                    ? AppColors.label
                    : AppColors.secondaryLabel,
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Global feed icon (globe) with label
class _GlobalFeedIcon extends StatelessWidget {
  final bool isActive;

  const _GlobalFeedIcon({required this.isActive});

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: isActive
                ? AppColors.primary
                : AppColors.chipBackground,
            borderRadius: BorderRadius.circular(isActive ? 16 : 28),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: AppColors.primary.withOpacity(0.4),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Icon(
            CupertinoIcons.globe,
            color: isActive
                ? CupertinoColors.white
                : AppColors.primary,
            size: 28,
          ),
        ),
        const SizedBox(height: 2),
        Builder(
          builder: (context) {
            final localizations = AppLocalizations.of(context);
            return Text(
              localizations?.feed ?? 'Feed',
              style: TextStyle(
                fontSize: 10,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                color: isActive
                    ? AppColors.label
                    : AppColors.secondaryLabel,
              ),
            );
          },
        ),
      ],
    );
  }
}

/// Compact group icon button with active indicator
class _GroupIconButton extends StatelessWidget {
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool isActive;
  final Widget child;

  const _GroupIconButton({
    required this.onTap,
    this.onLongPress,
    required this.isActive,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Active indicator pill
          AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: 3,
            height: isActive ? 32 : 8,
            margin: const EdgeInsets.only(right: 4),
            decoration: BoxDecoration(
              color: isActive
                  ? AppColors.primary
                  : AppColors.separator,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // Button with constrained tap area
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            onLongPress: onLongPress,
            child: child,
          ),
        ],
      ),
    );
  }
}

/// Circular group avatar with name label
class _GroupAvatar extends StatelessWidget {
  final String? name;
  final String? pictureUrl;
  final bool isActive;
  final bool isMember;
  final bool showLabel;
  final bool needsRecovery;

  const _GroupAvatar({
    this.name,
    this.pictureUrl,
    required this.isActive,
    required this.isMember,
    this.showLabel = true,
    this.needsRecovery = false,
  });

  String _getInitials(String? name) {
    if (name == null || name.isEmpty) return '?';
    final words = name.trim().split(RegExp(r'\s+'));
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      return words[0].substring(0, words[0].length.clamp(0, 2)).toUpperCase();
    }
    return '${words[0][0]}${words[1][0]}'.toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    // Use orange color for groups needing recovery
    final avatarColor = needsRecovery
        ? AppColors.warning
        : (isMember ? AppColors.primary : AppColors.surfaceElevated);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Stack(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: avatarColor,
                borderRadius: BorderRadius.circular(isActive ? 16 : 28),
                image: pictureUrl != null
                    ? DecorationImage(
                        image: NetworkImage(pictureUrl!),
                        fit: BoxFit.cover,
                      )
                    : null,
                boxShadow: isActive
                    ? [
                        BoxShadow(
                          color: avatarColor.withOpacity(0.5),
                          blurRadius: 8,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: pictureUrl == null
                  ? Center(
                      child: Text(
                        _getInitials(name),
                        style: TextStyle(
                          color: isMember || needsRecovery
                              ? CupertinoColors.white
                              : AppColors.secondaryLabel,
                          fontWeight: FontWeight.w600,
                          fontSize: 18,
                        ),
                      ),
                    )
                  : null,
            ),
            // Warning badge for groups needing recovery
            if (needsRecovery)
              Positioned(
                right: 0,
                bottom: 0,
                child: Container(
                  width: 18,
                  height: 18,
                  decoration: BoxDecoration(
                    color: AppColors.warning,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: AppColors.background,
                      width: 2,
                    ),
                  ),
                  child: const Icon(
                    CupertinoIcons.exclamationmark,
                    size: 12,
                    color: CupertinoColors.white,
                  ),
                ),
              ),
          ],
        ),
        if (showLabel) ...[
          const SizedBox(height: 2),
          SizedBox(
            width: 72,
            child: Text(
              name ?? 'Unknown',
              style: TextStyle(
                fontSize: 10,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                color: isActive
                    ? AppColors.label
                    : AppColors.secondaryLabel,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ],
    );
  }
}

/// Modal for editing group metadata
class _EditGroupModal extends StatefulWidget {
  final GroupAnnouncement announcement;
  final VoidCallback onSaved;

  const _EditGroupModal({required this.announcement, required this.onSaved});

  @override
  State<_EditGroupModal> createState() => _EditGroupModalState();
}

class _EditGroupModalState extends State<_EditGroupModal> {
  late TextEditingController _nameController;
  late TextEditingController _aboutController;
  String? _pictureUrl;
  Uint8List? _selectedPhotoBytes;
  bool _isSaving = false;
  bool _isUploadingPhoto = false;
  String? _error;
  final ImagePicker _imagePicker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.announcement.name ?? '',
    );
    _aboutController = TextEditingController(
      text: widget.announcement.about ?? '',
    );
    _pictureUrl = widget.announcement.picture;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _aboutController.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 400,
        maxHeight: 400,
        imageQuality: 85,
      );
      if (pickedFile == null) return;
      final bytes = await pickedFile.readAsBytes();
      setState(() => _selectedPhotoBytes = bytes);
    } catch (e) {
      setState(() => _error = 'Failed to pick image: $e');
    }
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Group name cannot be empty');
      return;
    }

    final groupIdHex = widget.announcement.mlsGroupId;
    if (groupIdHex == null) {
      setState(() => _error = 'Invalid group ID');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      final groupState = context.read<GroupState>();
      String? newPictureUrl = _pictureUrl;

      if (_selectedPhotoBytes != null) {
        setState(() => _isUploadingPhoto = true);
        newPictureUrl = await groupState.uploadMediaToOwnGroup(
          _selectedPhotoBytes!,
          'image/jpeg',
        );
        setState(() => _isUploadingPhoto = false);
      }

      final about = _aboutController.text.trim();
      await groupState.updateGroupMetadata(
        groupIdHex: groupIdHex,
        name: name,
        about: about.isEmpty ? null : about,
        picture: newPictureUrl,
      );

      widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _isSaving = false;
        _isUploadingPhoto = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.5,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
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
                  Builder(
                    builder: (context) {
                      final localizations = AppLocalizations.of(context);
                      return Text(
                        localizations?.editGroup ?? 'Edit Group',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      );
                    },
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 0,
                    onPressed: _isSaving ? null : _save,
                    child: _isSaving
                        ? const CupertinoActivityIndicator()
                        : Builder(
                            builder: (context) {
                              final localizations = AppLocalizations.of(context);
                              return Text(
                                localizations?.save ?? 'Save',
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            Container(height: 0.5, color: AppColors.separator),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null)
                    Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: AppColors.errorBackground,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            CupertinoIcons.exclamationmark_triangle,
                            color: AppColors.error,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: const TextStyle(
                                color: AppColors.error,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            minSize: 0,
                            onPressed: () => setState(() => _error = null),
                            child: const Icon(
                              CupertinoIcons.xmark_circle_fill,
                              color: AppColors.error,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                    ),
                  Center(
                    child: GestureDetector(
                      onTap: _isSaving ? null : _pickPhoto,
                      child: Stack(
                        children: [
                          Container(
                            width: 80,
                            height: 80,
                            decoration: BoxDecoration(
                              color: AppColors.surfaceElevated,
                              shape: BoxShape.circle,
                              image: _selectedPhotoBytes != null
                                  ? DecorationImage(
                                      image: MemoryImage(_selectedPhotoBytes!),
                                      fit: BoxFit.cover,
                                    )
                                  : _pictureUrl != null
                                  ? DecorationImage(
                                      image: NetworkImage(_pictureUrl!),
                                      fit: BoxFit.cover,
                                    )
                                  : null,
                            ),
                            child:
                                (_selectedPhotoBytes == null &&
                                    _pictureUrl == null)
                                ? const Icon(
                                    CupertinoIcons.person_2_fill,
                                    size: 32,
                                    color: AppColors.secondaryLabel,
                                  )
                                : null,
                          ),
                          if (_isUploadingPhoto)
                            Container(
                              width: 80,
                              height: 80,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: CupertinoColors.black.withOpacity(0.5),
                              ),
                              child: const CupertinoActivityIndicator(
                                color: CupertinoColors.white,
                              ),
                            ),
                          if (!_isSaving)
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: AppColors.primary,
                                ),
                                child: const Icon(
                                  CupertinoIcons.camera_fill,
                                  size: 14,
                                  color: CupertinoColors.white,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Builder(
                    builder: (context) {
                      final localizations = AppLocalizations.of(context);
                      return Center(
                        child: Text(
                          _isUploadingPhoto
                              ? (localizations?.uploading ?? 'Uploading...')
                              : (localizations?.tapToChangePhoto ?? 'Tap to change photo'),
                          style: const TextStyle(
                            color: AppColors.secondaryLabel,
                            fontSize: 12,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                  CupertinoTextField(
                    controller: _nameController,
                    placeholder: 'Group name',
                    padding: const EdgeInsets.all(12),
                    enabled: !_isSaving,
                  ),
                  const SizedBox(height: 12),
                  CupertinoTextField(
                    controller: _aboutController,
                    placeholder: 'About (optional)',
                    padding: const EdgeInsets.all(12),
                    maxLines: 2,
                    enabled: !_isSaving,
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
