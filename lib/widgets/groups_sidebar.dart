import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/services/mls/mls_group.dart';

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
    _fetchGroupsFromRelay();
    _loadMemberships();
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

  Future<void> _loadMemberships() async {
    final groupState = context.read<GroupState>();
    if (!groupState.isConnected) return;

    try {
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

    setState(() => _isFetchingGroups = true);

    try {
      await groupState.refreshDiscoveredGroups(limit: 1000);
      // Also refresh memberships when fetching groups
      await _loadMemberships();
    } catch (e) {
      // Silently fail
    } finally {
      if (mounted) setState(() => _isFetchingGroups = false);
    }
  }

  void _showCreateGroupModal() {
    showCupertinoModalPopup(
      context: context,
      builder: (context) => _CreateGroupModal(
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

    // Filter groups based on NIP-29 membership (kind 9000/9001 events)
    // Exclude personal groups
    for (final announcement in groupState.discoveredGroups) {
      final groupIdHex = announcement.mlsGroupId;
      if (groupIdHex == null) continue;

      // Skip personal groups (identified by the 'personal' tag in group announcement)
      final isPersonalGroup =
          announcement.isPersonal &&
          announcement.personalPubkey == _userNostrPubkey;

      if (isPersonalGroup) {
        continue;
      }

      // Check NIP-29 membership: user is member if latest kind 9000 (put-user)
      // is after latest kind 9001 (remove-user), or no 9001 exists
      final isMember = _memberships[groupIdHex] ?? false;

      // Skip groups user is not a member of
      if (!isMember) {
        continue;
      }

      // Find matching local MLS group if available
      MlsGroup? matchingGroup;
      try {
        matchingGroup = groupState.groups.firstWhere((g) {
          final gIdHex = g.id.bytes
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
          return gIdHex == groupIdHex;
        });
      } catch (e) {
        matchingGroup = null;
      }

      allGroups.add(
        _GroupItem(
          announcement: announcement,
          mlsGroup: matchingGroup,
          isMyGroup: false,
        ),
      );
    }

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

        // Reload memberships when cache is invalidated (e.g., after joining a group)
        if (groupState.membershipCacheVersion != _lastMembershipVersion) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _lastMembershipVersion = groupState.membershipCacheVersion;
            _membershipsLoaded = false;
            _loadMemberships();
          });
        }

        final allGroups = _buildGroupList(groupState);
        final isGlobalFeed = groupState.activeGroup == null;

        // Extra top padding for macOS to account for hidden title bar
        final isMacOS = !kIsWeb && Platform.isMacOS;
        final topPadding = isMacOS ? 36.0 : 8.0;

        return SafeArea(
          child: Container(
            width: 108,
            color: CupertinoColors.systemBackground,
            child: Column(
              children: [
                SizedBox(height: topPadding),
                // Create group button
                Center(
                  child: GestureDetector(
                    onTap: _showCreateGroupModal,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: CupertinoColors.systemGrey5,
                            borderRadius: BorderRadius.circular(28),
                          ),
                          child: const Icon(
                            CupertinoIcons.plus,
                            color: CupertinoColors.systemGreen,
                            size: 28,
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'New',
                          style: TextStyle(
                            fontSize: 10,
                            color: CupertinoColors.secondaryLabel,
                          ),
                        ),
                      ],
                    ),
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
                    color: CupertinoColors.separator,
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
                      final mlsGroup = item.mlsGroup;
                      final isLocalGroup = mlsGroup != null;

                      if (mlsGroup == null && announcement == null) {
                        return const SizedBox.shrink();
                      }

                      final activeGroupId = groupState.activeGroup?.id.bytes
                          .toString();
                      final groupId = mlsGroup?.id.bytes.toString();
                      final isActive =
                          isLocalGroup &&
                          activeGroupId != null &&
                          groupId != null &&
                          activeGroupId == groupId;

                      final groupName =
                          announcement?.name ??
                          mlsGroup?.name ??
                          'Unnamed Group';
                      final pictureUrl = announcement?.picture;

                      return _GroupIconButton(
                        onTap: isLocalGroup
                            ? () => _selectGroup(mlsGroup)
                            : null,
                        onLongPress: isLocalGroup && announcement != null
                            ? () => _showEditGroupModal(announcement)
                            : null,
                        isActive: isActive,
                        child: _GroupAvatar(
                          name: groupName,
                          pictureUrl: pictureUrl,
                          isActive: isActive,
                          isMember: isLocalGroup,
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
                ? CupertinoColors.activeBlue
                : CupertinoColors.systemGrey5,
            borderRadius: BorderRadius.circular(isActive ? 16 : 28),
            boxShadow: isActive
                ? [
                    BoxShadow(
                      color: CupertinoColors.activeBlue.withOpacity(0.4),
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
                : CupertinoColors.systemGrey,
            size: 28,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          'Feed',
          style: TextStyle(
            fontSize: 10,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
            color: isActive
                ? CupertinoColors.label
                : CupertinoColors.secondaryLabel,
          ),
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
                  ? CupertinoColors.activeBlue
                  : CupertinoColors.separator,
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
  final String name;
  final String? pictureUrl;
  final bool isActive;
  final bool isMember;
  final bool showLabel;

  const _GroupAvatar({
    required this.name,
    this.pictureUrl,
    required this.isActive,
    required this.isMember,
    this.showLabel = true,
  });

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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 56,
          height: 56,
          decoration: BoxDecoration(
            color: isMember
                ? CupertinoColors.systemIndigo
                : CupertinoColors.systemGrey4,
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
                      color: CupertinoColors.systemIndigo.withOpacity(0.5),
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
                      color: isMember
                          ? CupertinoColors.white
                          : CupertinoColors.systemGrey,
                      fontWeight: FontWeight.w600,
                      fontSize: 18,
                    ),
                  ),
                )
              : null,
        ),
        if (showLabel) ...[
          const SizedBox(height: 2),
          SizedBox(
            width: 72,
            child: Text(
              name,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                color: isActive
                    ? CupertinoColors.label
                    : CupertinoColors.secondaryLabel,
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

/// Modal for creating a new group
class _CreateGroupModal extends StatefulWidget {
  final VoidCallback onCreated;

  const _CreateGroupModal({required this.onCreated});

  @override
  State<_CreateGroupModal> createState() => _CreateGroupModalState();
}

class _CreateGroupModalState extends State<_CreateGroupModal> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _aboutController = TextEditingController();
  Uint8List? _selectedPhotoBytes;
  bool _isCreating = false;
  bool _isUploadingPhoto = false;
  String? _error;
  final ImagePicker _imagePicker = ImagePicker();

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

  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Group name is required');
      return;
    }

    final groupState = context.read<GroupState>();
    if (!groupState.isConnected) {
      setState(() => _error = 'Not connected to relay');
      return;
    }

    setState(() {
      _isCreating = true;
      _error = null;
    });

    try {
      String? pictureUrl;
      if (_selectedPhotoBytes != null) {
        setState(() => _isUploadingPhoto = true);
        pictureUrl = await groupState.uploadMediaToOwnGroup(
          _selectedPhotoBytes!,
          'image/jpeg',
        );
        setState(() => _isUploadingPhoto = false);
      }

      final about = _aboutController.text.trim();
      await groupState.createGroup(
        name,
        about: about.isEmpty ? null : about,
        picture: pictureUrl,
      );

      widget.onCreated();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _isCreating = false;
        _isUploadingPhoto = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.6,
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
                    'Create Group',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 0,
                    onPressed: _isCreating ? null : _create,
                    child: _isCreating
                        ? const CupertinoActivityIndicator()
                        : const Text(
                            'Create',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                  ),
                ],
              ),
            ),
            Container(height: 0.5, color: CupertinoColors.separator),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null)
                    Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: CupertinoColors.systemRed.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            CupertinoIcons.exclamationmark_triangle,
                            color: CupertinoColors.systemRed,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: const TextStyle(
                                color: CupertinoColors.systemRed,
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
                              color: CupertinoColors.systemRed,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Photo picker
                  Center(
                    child: GestureDetector(
                      onTap: _isCreating ? null : _pickPhoto,
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          color: CupertinoColors.systemGrey4,
                          shape: BoxShape.circle,
                          image: _selectedPhotoBytes != null
                              ? DecorationImage(
                                  image: MemoryImage(_selectedPhotoBytes!),
                                  fit: BoxFit.cover,
                                )
                              : null,
                        ),
                        child: _selectedPhotoBytes == null
                            ? const Icon(
                                CupertinoIcons.camera_fill,
                                size: 32,
                                color: CupertinoColors.systemGrey,
                              )
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Text(
                      _isUploadingPhoto
                          ? 'Uploading...'
                          : _selectedPhotoBytes != null
                          ? 'Tap to change'
                          : 'Add photo (optional)',
                      style: const TextStyle(
                        color: CupertinoColors.secondaryLabel,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  CupertinoTextField(
                    controller: _nameController,
                    placeholder: 'Group name',
                    padding: const EdgeInsets.all(12),
                    enabled: !_isCreating,
                  ),
                  const SizedBox(height: 12),
                  CupertinoTextField(
                    controller: _aboutController,
                    placeholder: 'About (optional)',
                    padding: const EdgeInsets.all(12),
                    maxLines: 2,
                    enabled: !_isCreating,
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
      height: MediaQuery.of(context).size.height * 0.6,
      decoration: const BoxDecoration(
        color: CupertinoColors.systemBackground,
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
                color: CupertinoColors.systemGrey4,
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
                  const Text(
                    'Edit Group',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 0,
                    onPressed: _isSaving ? null : _save,
                    child: _isSaving
                        ? const CupertinoActivityIndicator()
                        : const Text(
                            'Save',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                  ),
                ],
              ),
            ),
            Container(height: 0.5, color: CupertinoColors.separator),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null)
                    Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: CupertinoColors.systemRed.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            CupertinoIcons.exclamationmark_triangle,
                            color: CupertinoColors.systemRed,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: const TextStyle(
                                color: CupertinoColors.systemRed,
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
                              color: CupertinoColors.systemRed,
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
                              color: CupertinoColors.systemGrey4,
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
                                    color: CupertinoColors.systemGrey,
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
                                  color: CupertinoColors.activeBlue,
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
                  Center(
                    child: Text(
                      _isUploadingPhoto
                          ? 'Uploading...'
                          : 'Tap to change photo',
                      style: const TextStyle(
                        color: CupertinoColors.secondaryLabel,
                        fontSize: 12,
                      ),
                    ),
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
