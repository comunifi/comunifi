import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
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
  final TextEditingController _groupNameController = TextEditingController();
  final TextEditingController _groupAboutController = TextEditingController();
  bool _isCreatingGroup = false;
  String? _createGroupError;
  bool _isFetchingGroups = false;
  String? _fetchGroupsError;
  String? _userNostrPubkey;
  bool _hasFetchedOnConnect = false;

  // Group photo state
  Uint8List? _selectedPhotoBytes;
  bool _isUploadingPhoto = false;
  final ImagePicker _imagePicker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadUserPubkey();
    _fetchGroupsFromRelay();
  }

  @override
  void dispose() {
    _groupNameController.dispose();
    _groupAboutController.dispose();
    super.dispose();
  }

  Future<void> _loadUserPubkey() async {
    final groupState = context.read<GroupState>();

    // Retry mechanism: try up to 5 times with increasing delays
    String? pubkey;
    for (int attempt = 0; attempt < 5; attempt++) {
      pubkey = await groupState.getNostrPublicKey();
      if (pubkey != null) {
        break;
      }

      // Wait before retrying (exponential backoff: 200ms, 400ms, 800ms, 1600ms, 3200ms)
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

  Future<void> _fetchGroupsFromRelay() async {
    final groupState = context.read<GroupState>();
    if (!groupState.isConnected) {
      return;
    }

    // Skip if already fetching
    if (_isFetchingGroups) {
      return;
    }

    setState(() {
      _isFetchingGroups = true;
      _fetchGroupsError = null;
    });

    try {
      // Load all groups (large limit to get all available)
      // Always disable cache to get fresh data from relay
      await groupState.refreshDiscoveredGroups(limit: 1000);
    } catch (e) {
      setState(() {
        _fetchGroupsError = 'Failed to fetch groups: $e';
      });
    } finally {
      setState(() {
        _isFetchingGroups = false;
      });
    }
  }

  Future<void> _pickGroupPhoto() async {
    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 400,
        maxHeight: 400,
        imageQuality: 85,
      );

      if (pickedFile == null) return;

      final bytes = await pickedFile.readAsBytes();
      setState(() {
        _selectedPhotoBytes = bytes;
      });
    } catch (e) {
      setState(() {
        _createGroupError = 'Failed to pick image: $e';
      });
    }
  }

  Future<void> _createGroup() async {
    final groupName = _groupNameController.text.trim();
    if (groupName.isEmpty) {
      setState(() {
        _createGroupError = 'Group name cannot be empty';
      });
      return;
    }

    final groupState = context.read<GroupState>();
    if (!groupState.isConnected) {
      setState(() {
        _createGroupError = 'Not connected to relay';
      });
      return;
    }

    setState(() {
      _isCreatingGroup = true;
      _createGroupError = null;
    });

    try {
      String? pictureUrl;

      // Upload photo if selected
      if (_selectedPhotoBytes != null) {
        setState(() {
          _isUploadingPhoto = true;
        });
        pictureUrl = await groupState.uploadMediaToOwnGroup(
          _selectedPhotoBytes!,
          'image/jpeg',
        );
        setState(() {
          _isUploadingPhoto = false;
        });
      }

      final about = _groupAboutController.text.trim();
      await groupState.createGroup(
        groupName,
        about: about.isEmpty ? null : about,
        picture: pictureUrl,
      );
      _groupNameController.clear();
      _groupAboutController.clear();
      setState(() {
        _isCreatingGroup = false;
        _selectedPhotoBytes = null;
      });
      // Refresh discovered groups to show the newly created group
      await _fetchGroupsFromRelay();
    } catch (e) {
      setState(() {
        _isCreatingGroup = false;
        _isUploadingPhoto = false;
        _createGroupError = e.toString();
      });
    }
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

  void _toggleGroup(MlsGroup group, VoidCallback onClose) {
    final groupState = context.read<GroupState>();
    if (groupState.activeGroup?.id.bytes.toString() ==
        group.id.bytes.toString()) {
      // Deselect if already active
      groupState.setActiveGroup(null);
    } else {
      // Select this group
      groupState.setActiveGroup(group);
    }
    // Close sidebar
    onClose();
  }

  String _groupIdToHex(MlsGroup group) {
    return group.id.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<GroupState>(
      builder: (context, groupState, child) {
        // Automatically fetch groups when connection is established
        if (groupState.isConnected && !_hasFetchedOnConnect) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _hasFetchedOnConnect = true;
            _fetchGroupsFromRelay();
          });
        } else if (!groupState.isConnected) {
          // Reset flag when disconnected so we fetch again on reconnect
          _hasFetchedOnConnect = false;
        }

        return SafeArea(
          child: Column(
            children: [
              // Header with close button
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: CupertinoColors.separator,
                      width: 0.5,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    const Text(
                      'Groups',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (widget.showCloseButton) ...[
                      const Spacer(),
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        minSize: 0,
                        onPressed: widget.onClose,
                        child: const Icon(CupertinoIcons.xmark),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                // Group creation section
                Container(
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemGrey6,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Create Group',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_createGroupError != null)
                        Container(
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: CupertinoColors.systemRed.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: CupertinoColors.systemRed,
                            ),
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
                                  _createGroupError!,
                                  style: const TextStyle(
                                    color: CupertinoColors.systemRed,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              CupertinoButton(
                                padding: EdgeInsets.zero,
                                minSize: 0,
                                onPressed: () {
                                  setState(() {
                                    _createGroupError = null;
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
                      // Group photo picker
                      Center(
                        child: GestureDetector(
                          onTap: _isCreatingGroup ? null : _pickGroupPhoto,
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
                          _selectedPhotoBytes != null
                              ? 'Tap to change'
                              : 'Add photo (optional)',
                          style: const TextStyle(
                            color: CupertinoColors.secondaryLabel,
                            fontSize: 12,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      CupertinoTextField(
                        controller: _groupNameController,
                        placeholder: 'Group Name',
                        padding: const EdgeInsets.all(12),
                      ),
                      const SizedBox(height: 8),
                      CupertinoTextField(
                        controller: _groupAboutController,
                        placeholder: 'About (optional)',
                        padding: const EdgeInsets.all(12),
                        maxLines: 2,
                      ),
                      const SizedBox(height: 12),
                      CupertinoButton.filled(
                        onPressed: _isCreatingGroup ? null : _createGroup,
                        child: _isCreatingGroup
                            ? Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const CupertinoActivityIndicator(
                                    color: CupertinoColors.white,
                                  ),
                                  if (_isUploadingPhoto) ...[
                                    const SizedBox(width: 8),
                                    const Text(
                                      'Uploading...',
                                      style: TextStyle(color: CupertinoColors.white),
                                    ),
                                  ],
                                ],
                              )
                            : const Text('Create Group'),
                      ),
                    ],
                  ),
                ),

                // Combined groups section (discovered + local)
                Container(
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemGrey6,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Groups',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Row(
                            children: [
                              if (_isFetchingGroups ||
                                  groupState.isLoadingGroups ||
                                  groupState.isLoading)
                                const Padding(
                                  padding: EdgeInsets.only(right: 8),
                                  child: CupertinoActivityIndicator(),
                                ),
                              CupertinoButton(
                                padding: EdgeInsets.zero,
                                minSize: 0,
                                onPressed: _isFetchingGroups
                                    ? null
                                    : _fetchGroupsFromRelay,
                                child: const Icon(
                                  CupertinoIcons.arrow_clockwise,
                                  size: 20,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_fetchGroupsError != null)
                        Container(
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: CupertinoColors.systemRed.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: CupertinoColors.systemRed,
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                CupertinoIcons.exclamationmark_triangle,
                                color: CupertinoColors.systemRed,
                                size: 16,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _fetchGroupsError!,
                                  style: const TextStyle(
                                    color: CupertinoColors.systemRed,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      Builder(
                        builder: (context) {
                          // Combine discovered groups and local groups
                          final allGroups = <_GroupItem>[];

                          // Add discovered groups
                          for (final announcement
                              in groupState.discoveredGroups) {
                            // Try to find matching local group
                            MlsGroup? matchingGroup;
                            try {
                              matchingGroup = groupState.groups.firstWhere((g) {
                                final groupIdHex = g.id.bytes
                                    .map(
                                      (b) =>
                                          b.toRadixString(16).padLeft(2, '0'),
                                    )
                                    .join();
                                return announcement.mlsGroupId == groupIdHex;
                              });
                            } catch (e) {
                              matchingGroup = null;
                            }

                            final isMyGroup =
                                _userNostrPubkey != null &&
                                announcement.pubkey == _userNostrPubkey;

                            allGroups.add(
                              _GroupItem(
                                announcement: announcement,
                                mlsGroup: matchingGroup,
                                isMyGroup: isMyGroup,
                              ),
                            );
                          }

                          // Add local groups that aren't in discovered groups
                          for (final group in groupState.groups) {
                            final groupIdHex = group.id.bytes
                                .map((b) => b.toRadixString(16).padLeft(2, '0'))
                                .join();

                            final alreadyIncluded = allGroups.any(
                              (item) =>
                                  item.announcement?.mlsGroupId == groupIdHex ||
                                  item.mlsGroup?.id.bytes.toString() ==
                                      group.id.bytes.toString(),
                            );

                            if (!alreadyIncluded) {
                              allGroups.add(
                                _GroupItem(
                                  announcement: null,
                                  mlsGroup: group,
                                  isMyGroup:
                                      true, // Local groups are always mine
                                ),
                              );
                            }
                          }

                          // Sort by creation date (newest first)
                          allGroups.sort((a, b) {
                            final aDate =
                                a.announcement?.createdAt ??
                                DateTime.fromMillisecondsSinceEpoch(0);
                            final bDate =
                                b.announcement?.createdAt ??
                                DateTime.fromMillisecondsSinceEpoch(0);
                            return bDate.compareTo(aDate);
                          });

                          if (allGroups.isEmpty &&
                              !_isFetchingGroups &&
                              !groupState.isLoadingGroups &&
                              !groupState.isLoading)
                            return const Padding(
                              padding: EdgeInsets.all(16),
                              child: Text(
                                'No groups found. Create one above!',
                                style: TextStyle(
                                  color: CupertinoColors.secondaryLabel,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            );

                          return Column(
                            children: [
                              ...allGroups.map((item) {
                                final announcement = item.announcement;
                                final mlsGroup = item.mlsGroup;
                                final isMyGroup = item.isMyGroup;
                                final isLocalGroup = mlsGroup != null;

                                // Skip if no group data at all
                                if (mlsGroup == null && announcement == null) {
                                  return const SizedBox.shrink();
                                }

                                final activeGroupId = groupState
                                    .activeGroup
                                    ?.id
                                    .bytes
                                    .toString();
                                final groupId = mlsGroup?.id.bytes.toString();
                                final isActive =
                                    isLocalGroup &&
                                    activeGroupId != null &&
                                    groupId != null &&
                                    activeGroupId == groupId;

                                // Prefer announcement name (from relay) over MlsGroup name
                                final groupName =
                                    announcement?.name ??
                                    mlsGroup?.name ??
                                    'Unnamed Group';
                                final groupAbout = announcement?.about;
                                final groupIdHex = mlsGroup != null
                                    ? _groupIdToHex(mlsGroup)
                                    : announcement?.mlsGroupId ?? 'No group ID';

                                return Container(
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: isActive
                                        ? CupertinoColors.systemBlue
                                              .withOpacity(0.1)
                                        : isLocalGroup
                                        ? CupertinoColors.systemGreen
                                              .withOpacity(0.1)
                                        : CupertinoColors.systemGrey5,
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color: isActive
                                          ? CupertinoColors.systemBlue
                                          : isLocalGroup
                                          ? CupertinoColors.systemGreen
                                          : CupertinoColors.systemGrey4,
                                      width: isActive ? 2 : 1,
                                    ),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          // Group photo
                                          Container(
                                            width: 40,
                                            height: 40,
                                            margin: const EdgeInsets.only(right: 12),
                                            decoration: BoxDecoration(
                                              color: CupertinoColors.systemGrey4,
                                              shape: BoxShape.circle,
                                              image: announcement?.picture != null
                                                  ? DecorationImage(
                                                      image: NetworkImage(
                                                        announcement!.picture!,
                                                      ),
                                                      fit: BoxFit.cover,
                                                    )
                                                  : null,
                                            ),
                                            child: announcement?.picture == null
                                                ? const Icon(
                                                    CupertinoIcons.person_2_fill,
                                                    size: 20,
                                                    color: CupertinoColors.systemGrey,
                                                  )
                                                : null,
                                          ),
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: Text(
                                                        groupName,
                                                        style: TextStyle(
                                                          fontWeight:
                                                              FontWeight.bold,
                                                          fontSize: 16,
                                                          color: isActive
                                                              ? CupertinoColors
                                                                    .systemBlue
                                                              : null,
                                                        ),
                                                        overflow: TextOverflow.ellipsis,
                                                      ),
                                                    ),
                                                    if (isMyGroup)
                                                      const Padding(
                                                        padding:
                                                            EdgeInsets.only(
                                                              left: 8,
                                                            ),
                                                        child: Icon(
                                                          CupertinoIcons
                                                              .person_fill,
                                                          color: CupertinoColors
                                                              .systemBlue,
                                                          size: 16,
                                                        ),
                                                      ),
                                                    if (isLocalGroup &&
                                                        !isMyGroup)
                                                      const Padding(
                                                        padding:
                                                            EdgeInsets.only(
                                                              left: 8,
                                                            ),
                                                        child: Icon(
                                                          CupertinoIcons
                                                              .check_mark_circled,
                                                          color: CupertinoColors
                                                              .systemGreen,
                                                          size: 16,
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                                if (groupAbout != null) ...[
                                                  const SizedBox(height: 4),
                                                  Text(
                                                    groupAbout,
                                                    style: const TextStyle(
                                                      fontSize: 12,
                                                      color: CupertinoColors
                                                          .secondaryLabel,
                                                    ),
                                                    maxLines: 2,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                  ),
                                                ],
                                                const SizedBox(height: 4),
                                                Text(
                                                  'ID: ${groupIdHex.length > 12 ? "${groupIdHex.substring(0, 6)}...${groupIdHex.substring(groupIdHex.length - 6)}" : groupIdHex}',
                                                  style: const TextStyle(
                                                    fontSize: 11,
                                                    color: CupertinoColors
                                                        .secondaryLabel,
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                          if (isActive)
                                            const Icon(
                                              CupertinoIcons
                                                  .check_mark_circled_solid,
                                              color: CupertinoColors.systemBlue,
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      if (isLocalGroup)
                                        Builder(
                                          builder: (_) {
                                            // mlsGroup is non-null when isLocalGroup is true
                                            // Extract to local variable for type narrowing
                                            final group = mlsGroup;
                                            // Check if this is the Personal group (not editable)
                                            final isPersonalGroup =
                                                groupName.toLowerCase() == 'personal';
                                            return Row(
                                              children: [
                                                CupertinoButton(
                                                  padding: EdgeInsets.zero,
                                                  minSize: 0,
                                                  onPressed: () =>
                                                      _toggleGroup(group, widget.onClose),
                                                  child: Text(
                                                    isActive
                                                        ? 'Deselect'
                                                        : 'Select',
                                                    style: const TextStyle(
                                                      color: CupertinoColors
                                                          .systemBlue,
                                                    ),
                                                  ),
                                                ),
                                                // Edit button for admin groups (not Personal group)
                                                if (!isPersonalGroup && announcement != null)
                                                  _GroupEditButton(
                                                    groupIdHex: groupIdHex,
                                                    announcement: announcement,
                                                    onEdit: () =>
                                                        _showEditGroupModal(announcement),
                                                  ),
                                              ],
                                            );
                                          },
                                        )
                                      else
                                        const Text(
                                          'Join to access this group',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color:
                                                CupertinoColors.secondaryLabel,
                                          ),
                                        ),
                                    ],
                                  ),
                                );
                              }),
                            ],
                          );
                        },
                      ),
                    ],
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

/// Edit button that checks admin status before showing
class _GroupEditButton extends StatefulWidget {
  final String groupIdHex;
  final GroupAnnouncement announcement;
  final VoidCallback onEdit;

  const _GroupEditButton({
    required this.groupIdHex,
    required this.announcement,
    required this.onEdit,
  });

  @override
  State<_GroupEditButton> createState() => _GroupEditButtonState();
}

class _GroupEditButtonState extends State<_GroupEditButton> {
  bool _isAdmin = false;
  bool _isChecking = true;

  @override
  void initState() {
    super.initState();
    _checkAdminStatus();
  }

  Future<void> _checkAdminStatus() async {
    try {
      final groupState = context.read<GroupState>();
      final isAdmin = await groupState.isGroupAdmin(widget.groupIdHex);
      if (mounted) {
        setState(() {
          _isAdmin = isAdmin;
          _isChecking = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isChecking = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Don't show anything while checking or if not admin
    if (_isChecking || !_isAdmin) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.only(left: 16),
      child: CupertinoButton(
        padding: EdgeInsets.zero,
        minSize: 0,
        onPressed: widget.onEdit,
        child: const Text(
          'Edit',
          style: TextStyle(
            color: CupertinoColors.systemOrange,
          ),
        ),
      ),
    );
  }
}

/// Modal for editing group metadata
class _EditGroupModal extends StatefulWidget {
  final GroupAnnouncement announcement;
  final VoidCallback onSaved;

  const _EditGroupModal({
    required this.announcement,
    required this.onSaved,
  });

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
    _nameController = TextEditingController(text: widget.announcement.name ?? '');
    _aboutController = TextEditingController(text: widget.announcement.about ?? '');
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
      setState(() {
        _selectedPhotoBytes = bytes;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to pick image: $e';
      });
    }
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() {
        _error = 'Group name cannot be empty';
      });
      return;
    }

    final groupIdHex = widget.announcement.mlsGroupId;
    if (groupIdHex == null) {
      setState(() {
        _error = 'Invalid group ID';
      });
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      final groupState = context.read<GroupState>();
      String? newPictureUrl = _pictureUrl;

      // Upload new photo if selected
      if (_selectedPhotoBytes != null) {
        setState(() {
          _isUploadingPhoto = true;
        });
        newPictureUrl = await groupState.uploadMediaToOwnGroup(
          _selectedPhotoBytes!,
          'image/jpeg',
        );
        setState(() {
          _isUploadingPhoto = false;
        });
      }

      final about = _aboutController.text.trim();
      await groupState.updateGroupMetadata(
        groupIdHex: groupIdHex,
        name: name,
        about: about.isEmpty ? null : about,
        picture: newPictureUrl,
      );

      widget.onSaved();
      if (mounted) {
        Navigator.of(context).pop();
      }
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
      height: MediaQuery.of(context).size.height * 0.7,
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
                    'Edit Group',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
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
                Container(
                  height: 0.5,
                  color: CupertinoColors.separator,
                ),
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
                      onTap: _isSaving ? null : _pickPhoto,
                      child: Stack(
                        children: [
                          Container(
                            width: 100,
                            height: 100,
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
                            child: (_selectedPhotoBytes == null && _pictureUrl == null)
                                ? const Icon(
                                    CupertinoIcons.person_2_fill,
                                    size: 40,
                                    color: CupertinoColors.systemGrey,
                                  )
                                : null,
                          ),
                          if (_isUploadingPhoto)
                            Container(
                              width: 100,
                              height: 100,
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
                                width: 32,
                                height: 32,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: CupertinoColors.activeBlue,
                                ),
                                child: const Icon(
                                  CupertinoIcons.camera_fill,
                                  size: 16,
                                  color: CupertinoColors.white,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      _isUploadingPhoto ? 'Uploading...' : 'Tap to change photo',
                      style: const TextStyle(
                        color: CupertinoColors.secondaryLabel,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  // Name field
                  const Text(
                    'Group Name',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  CupertinoTextField(
                    controller: _nameController,
                    placeholder: 'Enter group name',
                    padding: const EdgeInsets.all(12),
                    enabled: !_isSaving,
                  ),
                  const SizedBox(height: 16),
                  // About field
                  const Text(
                    'About',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 8),
                  CupertinoTextField(
                    controller: _aboutController,
                    placeholder: 'Describe your group (optional)',
                    padding: const EdgeInsets.all(12),
                    maxLines: 3,
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

