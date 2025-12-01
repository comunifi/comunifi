import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
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

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final TextEditingController _groupNameController = TextEditingController();
  final TextEditingController _groupAboutController = TextEditingController();
  bool _isCreatingGroup = false;
  String? _createGroupError;
  bool _isFetchingGroups = false;
  String? _fetchGroupsError;
  String? _userNostrPubkey;
  bool _hasFetchedOnConnect = false;

  @override
  void initState() {
    super.initState();
    // Fetch groups from relay when screen loads
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadUserPubkey();
      _fetchGroupsFromRelay();
    });
  }

  Future<void> _loadUserPubkey() async {
    final groupState = context.read<GroupState>();
    final pubkey = await groupState.getNostrPublicKey();
    setState(() {
      _userNostrPubkey = pubkey;
    });
  }

  @override
  void dispose() {
    _groupNameController.dispose();
    _groupAboutController.dispose();
    super.dispose();
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
      final about = _groupAboutController.text.trim();
      await groupState.createGroup(
        groupName,
        about: about.isEmpty ? null : about,
      );
      _groupNameController.clear();
      _groupAboutController.clear();
      setState(() {
        _isCreatingGroup = false;
      });
      // Refresh discovered groups to show the newly created group
      await _fetchGroupsFromRelay();
    } catch (e) {
      setState(() {
        _isCreatingGroup = false;
        _createGroupError = e.toString();
      });
    }
  }

  void _toggleGroup(MlsGroup group) {
    final groupState = context.read<GroupState>();
    if (groupState.activeGroup?.id.bytes.toString() ==
        group.id.bytes.toString()) {
      // Deselect if already active
      groupState.setActiveGroup(null);
    } else {
      // Select this group and navigate to feed
      groupState.setActiveGroup(group);
      final navigate = GoRouter.of(context);
      navigate.push('/feed');
    }
  }

  String _groupIdToHex(MlsGroup group) {
    return group.id.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Onboarding')),
      child: SafeArea(
        child: Consumer<GroupState>(
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

            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Connection status
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: groupState.isConnected
                        ? CupertinoColors.systemGreen.withOpacity(0.1)
                        : CupertinoColors.systemRed.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: groupState.isConnected
                          ? CupertinoColors.systemGreen
                          : CupertinoColors.systemRed,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        groupState.isConnected
                            ? CupertinoIcons.check_mark_circled
                            : CupertinoIcons.xmark_circle,
                        color: groupState.isConnected
                            ? CupertinoColors.systemGreen
                            : CupertinoColors.systemRed,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          groupState.isConnected
                              ? 'Connected to relay'
                              : groupState.errorMessage ?? 'Not connected',
                          style: TextStyle(
                            color: groupState.isConnected
                                ? CupertinoColors.systemGreen
                                : CupertinoColors.systemRed,
                          ),
                        ),
                      ),
                      if (!groupState.isConnected)
                        CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: groupState.retryConnection,
                          child: const Text('Retry'),
                        ),
                    ],
                  ),
                ),

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
                            ? const CupertinoActivityIndicator(
                                color: CupertinoColors.white,
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

                                final groupName =
                                    mlsGroup?.name ??
                                    announcement?.name ??
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
                                          Expanded(
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Text(
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
                                            return CupertinoButton(
                                              padding: EdgeInsets.zero,
                                              minSize: 0,
                                              onPressed: () =>
                                                  _toggleGroup(group),
                                              child: Text(
                                                isActive
                                                    ? 'Deselect'
                                                    : 'Select',
                                                style: const TextStyle(
                                                  color: CupertinoColors
                                                      .systemBlue,
                                                ),
                                              ),
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

                // Active group info
                if (groupState.activeGroup != null)
                  Container(
                    padding: const EdgeInsets.all(16),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: CupertinoColors.systemBlue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: CupertinoColors.systemBlue),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Active Group',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: CupertinoColors.systemBlue,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          groupState.activeGroup!.name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Messages: ${groupState.groupMessages.length}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: CupertinoColors.secondaryLabel,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}
