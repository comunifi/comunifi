import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/services/mls/mls_group.dart';

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

  @override
  void initState() {
    super.initState();
    // Fetch groups from relay when screen loads
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _fetchGroupsFromRelay();
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

    setState(() {
      _isFetchingGroups = true;
      _fetchGroupsError = null;
    });

    try {
      await groupState.refreshDiscoveredGroups(limit: 50);
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

  Future<void> _loadMoreGroups() async {
    final groupState = context.read<GroupState>();
    if (!groupState.isConnected || _isFetchingGroups) {
      return;
    }

    setState(() {
      _isFetchingGroups = true;
      _fetchGroupsError = null;
    });

    try {
      await groupState.loadMoreGroups();
    } catch (e) {
      setState(() {
        _fetchGroupsError = 'Failed to load all groups: $e';
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

  String _truncateGroupId(MlsGroup group) {
    final groupIdHex = group.id.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    if (groupIdHex.length <= 12) return groupIdHex;
    return '${groupIdHex.substring(0, 6)}...${groupIdHex.substring(groupIdHex.length - 6)}';
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Onboarding')),
      child: SafeArea(
        child: Consumer<GroupState>(
          builder: (context, groupState, child) {
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

                // Discovered groups from relay section
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
                            'Available Groups',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          Row(
                            children: [
                              if (_isFetchingGroups ||
                                  groupState.isLoadingGroups)
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
                      if (groupState.discoveredGroups.isEmpty &&
                          !_isFetchingGroups &&
                          !groupState.isLoadingGroups)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'No groups found on relay. Create one above!',
                            style: TextStyle(
                              color: CupertinoColors.secondaryLabel,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        )
                      else
                        ...groupState.discoveredGroups.map((announcement) {
                          // Try to find matching local group
                          MlsGroup? matchingGroup;
                          try {
                            matchingGroup = groupState.groups.firstWhere((g) {
                              final groupIdHex = g.id.bytes
                                  .map(
                                    (b) => b.toRadixString(16).padLeft(2, '0'),
                                  )
                                  .join();
                              return announcement.mlsGroupId == groupIdHex;
                            });
                          } catch (e) {
                            matchingGroup = null;
                          }

                          final isLocalGroup = matchingGroup != null;
                          final activeGroupId = groupState.activeGroup?.id.bytes
                              .toString();
                          final matchingGroupId = matchingGroup?.id.bytes
                              .toString();
                          final isActive =
                              isLocalGroup &&
                              activeGroupId != null &&
                              matchingGroupId != null &&
                              activeGroupId == matchingGroupId;

                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? CupertinoColors.systemBlue.withOpacity(0.1)
                                  : isLocalGroup
                                  ? CupertinoColors.systemGreen.withOpacity(0.1)
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
                              crossAxisAlignment: CrossAxisAlignment.start,
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
                                                announcement.name ??
                                                    'Unnamed Group',
                                                style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 16,
                                                  color: isActive
                                                      ? CupertinoColors
                                                            .systemBlue
                                                      : null,
                                                ),
                                              ),
                                              if (isLocalGroup)
                                                const Padding(
                                                  padding: EdgeInsets.only(
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
                                          if (announcement.about != null) ...[
                                            const SizedBox(height: 4),
                                            Text(
                                              announcement.about!,
                                              style: const TextStyle(
                                                fontSize: 12,
                                                color: CupertinoColors
                                                    .secondaryLabel,
                                              ),
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ],
                                          const SizedBox(height: 4),
                                          Text(
                                            announcement.mlsGroupId != null
                                                ? 'ID: ${announcement.mlsGroupId!.length > 12 ? "${announcement.mlsGroupId!.substring(0, 6)}...${announcement.mlsGroupId!.substring(announcement.mlsGroupId!.length - 6)}" : announcement.mlsGroupId}'
                                                : 'No group ID',
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
                                        CupertinoIcons.check_mark_circled_solid,
                                        color: CupertinoColors.systemBlue,
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                if (isLocalGroup)
                                  CupertinoButton(
                                    padding: EdgeInsets.zero,
                                    minSize: 0,
                                    onPressed: () =>
                                        _toggleGroup(matchingGroup!),
                                    child: Text(
                                      isActive ? 'Deselect' : 'Select',
                                      style: const TextStyle(
                                        color: CupertinoColors.systemBlue,
                                      ),
                                    ),
                                  )
                                else
                                  const Text(
                                    'Join to access this group',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: CupertinoColors.secondaryLabel,
                                    ),
                                  ),
                              ],
                            ),
                          );
                        }),
                      if (!_isFetchingGroups && !groupState.isLoadingGroups)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: CupertinoButton(
                            onPressed: _loadMoreGroups,
                            child: const Text('Load All Groups'),
                          ),
                        ),
                    ],
                  ),
                ),

                // Local groups section
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
                            'My Groups',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (groupState.isLoading)
                            const CupertinoActivityIndicator(),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (groupState.groups.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'No groups yet. Create one above!',
                            style: TextStyle(
                              color: CupertinoColors.secondaryLabel,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        )
                      else
                        ...groupState.groups.map((group) {
                          final isActive =
                              groupState.activeGroup?.id.bytes.toString() ==
                              group.id.bytes.toString();
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? CupertinoColors.systemBlue.withOpacity(0.1)
                                  : CupertinoColors.systemGrey5,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isActive
                                    ? CupertinoColors.systemBlue
                                    : CupertinoColors.systemGrey4,
                                width: isActive ? 2 : 1,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            group.name,
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                              color: isActive
                                                  ? CupertinoColors.systemBlue
                                                  : null,
                                            ),
                                          ),
                                          const SizedBox(height: 4),
                                          Text(
                                            'ID: ${_truncateGroupId(group)}',
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
                                        CupertinoIcons.check_mark_circled_solid,
                                        color: CupertinoColors.systemBlue,
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                CupertinoButton(
                                  padding: EdgeInsets.zero,
                                  minSize: 0,
                                  onPressed: () => _toggleGroup(group),
                                  child: Text(
                                    isActive ? 'Deselect' : 'Select',
                                    style: TextStyle(
                                      color: isActive
                                          ? CupertinoColors.systemBlue
                                          : CupertinoColors.systemBlue,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
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
