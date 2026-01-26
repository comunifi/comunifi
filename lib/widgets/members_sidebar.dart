import 'dart:async';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/profile.dart';
import 'package:comunifi/theme/colors.dart';
import 'package:comunifi/l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

class MembersSidebar extends StatefulWidget {
  final VoidCallback onClose;
  final bool showCloseButton;

  const MembersSidebar({
    super.key,
    required this.onClose,
    this.showCloseButton = true,
  });

  @override
  State<MembersSidebar> createState() => _MembersSidebarState();
}

class _MembersSidebarState extends State<MembersSidebar> {
  // Invite section state
  final TextEditingController _usernameController = TextEditingController();
  Timer? _debounceTimer;
  bool _isCheckingUser = false;
  bool? _userExists;
  String? _userCheckError;
  bool _isInviting = false;
  String? _inviteError;
  bool _isSelf = false;
  bool _isExpanded = false;

  // Current user pubkey
  String? _currentUserPubkey;

  // Members from NIP-29 events
  List<NIP29GroupMember> _members = [];
  bool _isLoadingMembers = true;
  String? _lastGroupIdHex;

  // Join requests section state (admin only)
  bool _isAdmin = false;
  List<JoinRequest> _joinRequests = [];
  bool _isLoadingJoinRequests = false;
  bool _isJoinRequestsExpanded = false;
  Set<String> _approvingPubkeys = {}; // Track which requests are being approved

  // Track membership cache version to detect changes
  int _lastMembershipCacheVersion = -1;

  @override
  void initState() {
    super.initState();
    _usernameController.addListener(_onUsernameChanged);
    _loadCurrentUserPubkey();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _usernameController.removeListener(_onUsernameChanged);
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentUserPubkey() async {
    final groupState = context.read<GroupState>();
    final pubkey = await groupState.getNostrPublicKey();
    if (mounted) {
      setState(() {
        _currentUserPubkey = pubkey;
      });
    }
  }

  Future<void> _loadMembers(
    GroupState groupState,
    String groupIdHex, {
    bool forceRefresh = false,
  }) async {
    // Skip if already loading this group (unless forcing refresh)
    if (_lastGroupIdHex == groupIdHex && !_isLoadingMembers && !forceRefresh) {
      return;
    }

    _lastGroupIdHex = groupIdHex;

    if (mounted) {
      setState(() {
        _isLoadingMembers = true;
      });
    }

    try {
      final members = await groupState.getGroupMembers(
        groupIdHex,
        forceRefresh: forceRefresh,
      );
      final isAdmin = await groupState.isGroupAdmin(groupIdHex);

      if (mounted) {
        setState(() {
          _members = members;
          _isLoadingMembers = false;
          _isAdmin = isAdmin;
        });

        // Load member profiles with cache-first pattern:
        // 1. Load from local cache immediately >> update sidebar
        // 2. Fetch from relay async in background
        // 3. Update sidebar when fresh data arrives
        if (members.isNotEmpty) {
          final profileState = context.read<ProfileState>();
          final pubkeys = members.map((m) => m.pubkey).toList();
          profileState.loadProfilesWithRefresh(pubkeys);
        }

        // Load join requests if user is admin
        if (isAdmin) {
          _loadJoinRequests(groupState, groupIdHex);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingMembers = false;
        });
      }
    }
  }

  Future<void> _loadJoinRequests(
    GroupState groupState,
    String groupIdHex,
  ) async {
    if (!_isAdmin) return;

    if (mounted) {
      setState(() {
        _isLoadingJoinRequests = true;
      });
    }

    try {
      final requests = await groupState.getJoinRequests(groupIdHex);
      if (mounted) {
        setState(() {
          _joinRequests = requests;
          _isLoadingJoinRequests = false;
        });

        // Load requester profiles with cache-first pattern
        if (requests.isNotEmpty) {
          final profileState = context.read<ProfileState>();
          final pubkeys = requests.map((r) => r.pubkey).toList();
          profileState.loadProfilesWithRefresh(pubkeys);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingJoinRequests = false;
        });
      }
    }
  }

  Future<void> _approveJoinRequest(String pubkey) async {
    if (_approvingPubkeys.contains(pubkey)) return;

    setState(() {
      _approvingPubkeys.add(pubkey);
    });

    try {
      final groupState = context.read<GroupState>();
      await groupState.approveJoinRequest(pubkey);

      if (mounted) {
        setState(() {
          _approvingPubkeys.remove(pubkey);
          // Remove from requests list
          _joinRequests.removeWhere((r) => r.pubkey == pubkey);
        });

        // Reload members to show the new member
        if (_lastGroupIdHex != null) {
          _loadMembers(groupState, _lastGroupIdHex!);
        }

        // Show success message
        showCupertinoDialog(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('Request Approved'),
            content: const Text('The user has been added to the group.'),
            actions: [
              CupertinoDialogAction(
                child: const Text('OK'),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _approvingPubkeys.remove(pubkey);
        });

        // Show error message
        showCupertinoDialog(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('Error'),
            content: Text('Failed to approve request: $e'),
            actions: [
              CupertinoDialogAction(
                child: const Text('OK'),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        );
      }
    }
  }

  void _onUsernameChanged() {
    setState(() {
      _userExists = null;
      _userCheckError = null;
      _inviteError = null;
      _isSelf = false;
    });

    _debounceTimer?.cancel();

    final username = _usernameController.text.trim();
    if (username.isEmpty) {
      return;
    }

    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _checkUserExists(username);
    });
  }

  Future<void> _checkUserExists(String username) async {
    if (username.isEmpty) {
      setState(() {
        _userExists = null;
        _isCheckingUser = false;
      });
      return;
    }

    setState(() {
      _isCheckingUser = true;
      _userCheckError = null;
    });

    try {
      final profileState = context.read<ProfileState>();
      final groupState = context.read<GroupState>();
      final profile = await profileState.searchByUsername(username);

      if (mounted) {
        bool isSelf = false;
        if (profile != null) {
          final currentUserPubkey = await groupState.getNostrPublicKey();
          if (currentUserPubkey != null &&
              profile.pubkey == currentUserPubkey) {
            isSelf = true;
          }
        }

        setState(() {
          _isCheckingUser = false;
          _userExists = profile != null && !isSelf;
          _isSelf = isSelf;
          if (profile == null) {
            _userCheckError = 'User not found';
          } else if (isSelf) {
            _userCheckError = 'You cannot invite yourself';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCheckingUser = false;
          _userExists = false;
          _userCheckError = 'Error: $e';
        });
      }
    }
  }

  Future<void> _inviteUser() async {
    final username = _usernameController.text.trim();
    if (username.isEmpty || _isSelf) {
      return;
    }

    setState(() {
      _isInviting = true;
      _inviteError = null;
    });

    try {
      final groupState = context.read<GroupState>();
      await groupState.inviteMemberByUsername(username);

      if (mounted) {
        setState(() {
          _isInviting = false;
          _usernameController.clear();
          _userExists = null;
          _isExpanded = false;
        });

        // Reload members after inviting
        if (_lastGroupIdHex != null) {
          _loadMembers(groupState, _lastGroupIdHex!);
        }

        // Show success toast
        showCupertinoDialog(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('Invitation Sent'),
            content: Text('$username has been invited to the group.'),
            actions: [
              CupertinoDialogAction(
                child: const Text('OK'),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isInviting = false;
          _inviteError = e.toString();
        });
      }
    }
  }

  String _groupIdToHex(dynamic groupId) {
    return groupId.bytes
        .map((b) => (b as int).toRadixString(16).padLeft(2, '0'))
        .join();
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<GroupState, ProfileState>(
      builder: (context, groupState, profileState, child) {
        final activeGroup = groupState.activeGroup;

        if (activeGroup == null) {
          return const SizedBox.shrink();
        }

        // Get group ID hex
        final groupIdHex = _groupIdToHex(activeGroup.id);

        // Check if membership cache was invalidated (e.g., new member joined)
        final currentCacheVersion = groupState.membershipCacheVersion;
        final shouldReloadForCacheChange =
            _lastMembershipCacheVersion != currentCacheVersion &&
            _lastMembershipCacheVersion != -1 &&
            _lastGroupIdHex == groupIdHex;

        if (shouldReloadForCacheChange) {
          _lastMembershipCacheVersion = currentCacheVersion;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            // Force reload members by resetting the loading state
            setState(() {
              _isLoadingMembers = true;
            });
            _loadMembers(groupState, groupIdHex, forceRefresh: true);
          });
        }

        // Load members if group changed - always force refresh for fresh data
        if (_lastGroupIdHex != groupIdHex) {
          _lastMembershipCacheVersion = currentCacheVersion;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _loadMembers(groupState, groupIdHex, forceRefresh: true);
          });
        }

        return SafeArea(
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: const BoxDecoration(
                  color: CupertinoColors.white,
                  border: Border(
                    bottom: BorderSide(
                      color: AppColors.separator,
                      width: 0.5,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Builder(
                      builder: (context) {
                        final localizations = AppLocalizations.of(context);
                        return Text(
                          '${localizations?.members ?? 'Members'}${_members.isNotEmpty ? ' (${_members.length})' : ''}',
                          style: const TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        );
                      },
                    ),
                    if (_isLoadingMembers) ...[
                      const SizedBox(width: 8),
                      const CupertinoActivityIndicator(radius: 8),
                    ],
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
                    // Join requests section (admin only)
                    if (_isAdmin) ...[
                      _buildJoinRequestsSection(groupState, profileState),
                      const SizedBox(height: 12),
                    ],
                    // Invite section
                    _buildInviteSection(),
                    const SizedBox(height: 16),
                    // Members list from NIP-29 events
                    if (_members.isEmpty && !_isLoadingMembers)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'No members found',
                          style: TextStyle(
                            color: CupertinoColors.secondaryLabel,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      )
                    else
                      ..._members.map(
                        (member) => _NIP29MemberTile(
                          key: ValueKey(member.pubkey),
                          member: member,
                          isCurrentUser: member.pubkey == _currentUserPubkey,
                          profileState: profileState,
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

  Widget _buildJoinRequestsSection(
    GroupState groupState,
    ProfileState profileState,
  ) {
    final hasRequests = _joinRequests.isNotEmpty;

    return Container(
      decoration: BoxDecoration(
        color: hasRequests
            ? AppColors.primarySoft.withOpacity(0.25)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: hasRequests
            ? Border.all(
                color: AppColors.primarySoft.withOpacity(0.6),
                width: 1,
              )
            : null,
      ),
      child: Column(
        children: [
          // Header - tappable to expand/collapse
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () {
              setState(() {
                _isJoinRequestsExpanded = !_isJoinRequestsExpanded;
              });
            },
            child: Container(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Icon(
                    CupertinoIcons.person_badge_plus,
                    color: hasRequests
                        ? AppColors.warning
                        : AppColors.secondaryLabel,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Join Requests${_joinRequests.isNotEmpty ? ' (${_joinRequests.length})' : ''}',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: hasRequests
                            ? AppColors.label
                            : AppColors.secondaryLabel,
                      ),
                    ),
                  ),
                  if (_isLoadingJoinRequests)
                    const CupertinoActivityIndicator(radius: 8)
                  else
                    Icon(
                      _isJoinRequestsExpanded
                          ? CupertinoIcons.chevron_up
                          : CupertinoIcons.chevron_down,
                      color: AppColors.secondaryLabel,
                      size: 16,
                    ),
                ],
              ),
            ),
          ),
          // Expandable content
          if (_isJoinRequestsExpanded) ...[
            Container(height: 0.5, color: AppColors.separator),
            if (_joinRequests.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'No pending requests',
                  style: TextStyle(
                    color: CupertinoColors.secondaryLabel,
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),
              )
            else
              Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  children: _joinRequests
                      .map(
                        (request) => _JoinRequestTile(
                          key: ValueKey(request.pubkey),
                          request: request,
                          profileState: profileState,
                          isApproving: _approvingPubkeys.contains(
                            request.pubkey,
                          ),
                          onApprove: () => _approveJoinRequest(request.pubkey),
                        ),
                      )
                      .toList(),
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildInviteSection() {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          // Header - tappable to expand/collapse
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () {
              setState(() {
                _isExpanded = !_isExpanded;
              });
            },
            child: Container(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
              const Icon(
                CupertinoIcons.person_add,
                color: AppColors.primary,
                size: 20,
              ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Invite Member',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: AppColors.label,
                      ),
                    ),
                  ),
                  Icon(
                    _isExpanded
                        ? CupertinoIcons.chevron_up
                        : CupertinoIcons.chevron_down,
                    color: AppColors.secondaryLabel,
                    size: 16,
                  ),
                ],
              ),
            ),
          ),
          // Expandable invite form
          if (_isExpanded) ...[
            Container(height: 0.5, color: CupertinoColors.separator),
              Padding(
                padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  CupertinoTextField(
                    controller: _usernameController,
                    placeholder: 'Enter username',
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.surface,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Status indicator
                  if (_isCheckingUser)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          CupertinoActivityIndicator(radius: 8),
                          SizedBox(width: 8),
                          Text(
                            'Checking...',
                            style: TextStyle(
                              color: AppColors.secondaryLabel,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (_userExists != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            _userExists!
                                ? CupertinoIcons.check_mark_circled_solid
                                : CupertinoIcons.xmark_circle,
                            color: _userExists!
                                ? CupertinoColors.systemGreen
                                : AppColors.error,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _userExists!
                                ? 'User found'
                                : (_userCheckError ?? 'Not found'),
                            style: TextStyle(
                              color: _userExists!
                                  ? CupertinoColors.systemGreen
                                  : AppColors.error,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_inviteError != null)
                    Container(
                      padding: const EdgeInsets.all(8),
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: AppColors.errorBackground,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _inviteError!,
                        style: const TextStyle(
                          color: AppColors.error,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  const SizedBox(height: 4),
                  CupertinoButton.filled(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    onPressed: (_userExists == true && !_isInviting && !_isSelf)
                        ? _inviteUser
                        : null,
                    child: _isInviting
                        ? const CupertinoActivityIndicator(
                            color: CupertinoColors.white,
                          )
                        : const Text(
                            'Send Invite',
                            style: TextStyle(fontSize: 14),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Member tile that displays NIP-29 member info with role badge
class _NIP29MemberTile extends StatefulWidget {
  final NIP29GroupMember member;
  final bool isCurrentUser;
  final ProfileState profileState;

  const _NIP29MemberTile({
    super.key,
    required this.member,
    required this.isCurrentUser,
    required this.profileState,
  });

  @override
  State<_NIP29MemberTile> createState() => _NIP29MemberTileState();
}

class _NIP29MemberTileState extends State<_NIP29MemberTile> {
  // Profile loading is now handled at sidebar level via loadProfilesWithRefresh()
  // which loads from cache first, then refreshes from relay in background

  String _formatPubkey(String pubkey) {
    if (pubkey.length <= 16) return pubkey;
    return '${pubkey.substring(0, 8)}...';
  }

  @override
  Widget build(BuildContext context) {
    // Read profile from ProfileState cache directly so updates are reflected immediately
    final cachedProfile = widget.profileState.profiles[widget.member.pubkey];
    final displayName =
        cachedProfile?.getUsername() ?? _formatPubkey(widget.member.pubkey);
    final profilePicture = cachedProfile?.picture;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: widget.isCurrentUser
            ? AppColors.primary.withOpacity(0.12)
            : AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: widget.isCurrentUser
            ? Border.all(
                color: AppColors.primary.withOpacity(0.4),
                width: 1,
              )
            : null,
      ),
      child: Row(
        children: [
          // Avatar
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.surfaceElevated,
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
                    size: 20,
                    color: AppColors.secondaryLabel,
                  )
                : null,
          ),
          const SizedBox(width: 12),
          // Name and badges
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Line 1: Username
                Text(
                  displayName,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                // Line 2: Badges
                if (widget.member.isAdmin ||
                    widget.member.isModerator ||
                    widget.isCurrentUser) ...[
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      // Role badge (admin/moderator)
                      if (widget.member.isAdmin)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.warning,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'Admin',
                            style: TextStyle(
                              color: CupertinoColors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        )
                      else if (widget.member.isModerator)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.accent,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'Mod',
                            style: TextStyle(
                              color: CupertinoColors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      // "You" badge
                      if (widget.isCurrentUser) ...[
                        if (widget.member.isAdmin || widget.member.isModerator)
                          const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            'You',
                            style: TextStyle(
                              color: CupertinoColors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Tile that displays a join request with approve button
class _JoinRequestTile extends StatefulWidget {
  final JoinRequest request;
  final ProfileState profileState;
  final bool isApproving;
  final VoidCallback onApprove;

  const _JoinRequestTile({
    super.key,
    required this.request,
    required this.profileState,
    required this.isApproving,
    required this.onApprove,
  });

  @override
  State<_JoinRequestTile> createState() => _JoinRequestTileState();
}

class _JoinRequestTileState extends State<_JoinRequestTile> {
  // Profile loading is now handled at sidebar level via loadProfilesWithRefresh()
  // which loads from cache first, then refreshes from relay in background

  String _formatPubkey(String pubkey) {
    if (pubkey.length <= 16) return pubkey;
    return '${pubkey.substring(0, 8)}...';
  }

  String _formatTimeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

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
    // Read profile from ProfileState cache directly so updates are reflected immediately
    final cachedProfile = widget.profileState.profiles[widget.request.pubkey];
    final displayName =
        cachedProfile?.getUsername() ?? _formatPubkey(widget.request.pubkey);
    final profilePicture = cachedProfile?.picture;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.separator, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Avatar
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: AppColors.surfaceElevated,
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
                        size: 18,
                        color: AppColors.secondaryLabel,
                      )
                    : null,
              ),
              const SizedBox(width: 10),
              // Name and time
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            displayName,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                    Text(
                      _formatTimeAgo(widget.request.createdAt),
                      style: const TextStyle(
                        fontSize: 12,
                        color: CupertinoColors.secondaryLabel,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          // Reason (if any)
          if (widget.request.reason != null &&
              widget.request.reason!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: AppColors.surface,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                widget.request.reason!,
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.secondaryLabel,
                  fontStyle: FontStyle.italic,
                ),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          // Approve button
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: CupertinoButton(
              padding: const EdgeInsets.symmetric(vertical: 8),
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(8),
              minSize: 0,
              onPressed: widget.isApproving ? null : widget.onApprove,
              child: widget.isApproving
                  ? const CupertinoActivityIndicator(
                      color: CupertinoColors.white,
                      radius: 10,
                    )
                  : const Text(
                      'Approve',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: CupertinoColors.white,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }
}
