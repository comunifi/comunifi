import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/profile.dart';

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

  Future<void> _loadMembers(GroupState groupState, String groupIdHex) async {
    // Skip if already loading this group
    if (_lastGroupIdHex == groupIdHex && !_isLoadingMembers) {
      return;
    }

    _lastGroupIdHex = groupIdHex;

    if (mounted) {
      setState(() {
        _isLoadingMembers = true;
      });
    }

    try {
      final members = await groupState.getGroupMembers(groupIdHex);
      if (mounted) {
        setState(() {
          _members = members;
          _isLoadingMembers = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoadingMembers = false;
        });
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
          if (currentUserPubkey != null && profile.pubkey == currentUserPubkey) {
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

        // Load members if not already loading
        if (_lastGroupIdHex != groupIdHex) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _loadMembers(groupState, groupIdHex);
          });
        }

        return SafeArea(
          child: Column(
            children: [
              // Header
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
                    Text(
                      'Members${_members.isNotEmpty ? ' (${_members.length})' : ''}',
                      style: const TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
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
                      ..._members.map((member) => _NIP29MemberTile(
                            member: member,
                            isCurrentUser: member.pubkey == _currentUserPubkey,
                            profileState: profileState,
                          )),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildInviteSection() {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6,
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
                    color: CupertinoColors.activeBlue,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Invite Member',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: CupertinoColors.label,
                      ),
                    ),
                  ),
                  Icon(
                    _isExpanded
                        ? CupertinoIcons.chevron_up
                        : CupertinoIcons.chevron_down,
                    color: CupertinoColors.secondaryLabel,
                    size: 16,
                  ),
                ],
              ),
            ),
          ),
          // Expandable invite form
          if (_isExpanded) ...[
            Container(
              height: 0.5,
              color: CupertinoColors.separator,
            ),
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
                      color: CupertinoColors.systemBackground,
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
                              color: CupertinoColors.secondaryLabel,
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
                                : CupertinoColors.systemRed,
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
                                  : CupertinoColors.systemRed,
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
                        color: CupertinoColors.systemRed.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _inviteError!,
                        style: const TextStyle(
                          color: CupertinoColors.systemRed,
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
                        : const Text('Send Invite', style: TextStyle(fontSize: 14)),
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
    required this.member,
    required this.isCurrentUser,
    required this.profileState,
  });

  @override
  State<_NIP29MemberTile> createState() => _NIP29MemberTileState();
}

class _NIP29MemberTileState extends State<_NIP29MemberTile> {
  String? _username;
  String? _profilePicture;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    try {
      final profile = await widget.profileState.getProfile(widget.member.pubkey);
      if (mounted) {
        setState(() {
          _username = profile?.getUsername();
          _profilePicture = profile?.picture;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  String _formatPubkey(String pubkey) {
    if (pubkey.length <= 16) return pubkey;
    return '${pubkey.substring(0, 8)}...';
  }

  @override
  Widget build(BuildContext context) {
    final displayName = _username ?? _formatPubkey(widget.member.pubkey);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: widget.isCurrentUser
            ? CupertinoColors.activeBlue.withOpacity(0.1)
            : CupertinoColors.systemGrey6,
        borderRadius: BorderRadius.circular(10),
        border: widget.isCurrentUser
            ? Border.all(
                color: CupertinoColors.activeBlue.withOpacity(0.3),
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
              color: CupertinoColors.systemGrey4,
              image: _profilePicture != null
                  ? DecorationImage(
                      image: NetworkImage(_profilePicture!),
                      fit: BoxFit.cover,
                    )
                  : null,
            ),
            child: _profilePicture == null
                ? const Icon(
                    CupertinoIcons.person_fill,
                    size: 20,
                    color: CupertinoColors.systemGrey,
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
                            color: CupertinoColors.systemOrange,
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
                            color: CupertinoColors.systemPurple,
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
                            color: CupertinoColors.activeBlue,
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
          // Loading indicator
          if (_isLoading)
            const CupertinoActivityIndicator(radius: 8),
        ],
      ),
    );
  }
}
