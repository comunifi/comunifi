import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/profile.dart';

class InviteUserModal extends StatefulWidget {
  const InviteUserModal({super.key});

  @override
  State<InviteUserModal> createState() => _InviteUserModalState();
}

class _InviteUserModalState extends State<InviteUserModal> {
  final TextEditingController _usernameController = TextEditingController();
  Timer? _debounceTimer;
  bool _isCheckingUser = false;
  bool? _userExists;
  String? _userCheckError;
  bool _isInviting = false;
  String? _inviteError;
  bool _isSelf = false; // Track if the user is trying to invite themselves

  @override
  void initState() {
    super.initState();
    _usernameController.addListener(_onUsernameChanged);
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _usernameController.removeListener(_onUsernameChanged);
    _usernameController.dispose();
    super.dispose();
  }

  void _onUsernameChanged() {
    // Reset state when username changes
    setState(() {
      _userExists = null;
      _userCheckError = null;
      _inviteError = null;
      _isSelf = false;
    });

    // Cancel previous timer
    _debounceTimer?.cancel();

    final username = _usernameController.text.trim();
    if (username.isEmpty) {
      return;
    }

    // Debounce: wait 500ms after user stops typing
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
        // Check if this is the current user
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
          _userCheckError = 'Error checking user: $e';
        });
      }
    }
  }

  Future<void> _inviteUser() async {
    final username = _usernameController.text.trim();
    if (username.isEmpty) {
      return;
    }

    // Prevent inviting yourself
    if (_isSelf) {
      setState(() {
        _inviteError = 'You cannot invite yourself to the group';
      });
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
        Navigator.of(context).pop();
        // Show success message
        showCupertinoDialog(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('Invitation Sent'),
            content: Text('$username has been invited to the group.'),
            actions: [
              CupertinoDialogAction(
                child: const Text('OK'),
                onPressed: () {
                  Navigator.of(context).pop();
                },
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

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        middle: const Text('Invite User'),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: const Icon(CupertinoIcons.xmark),
        ),
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Enter username to invite:',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              CupertinoTextField(
                controller: _usernameController,
                placeholder: 'Username',
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: CupertinoColors.systemGrey6,
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              const SizedBox(height: 8),
              // User existence check status
              if (_isCheckingUser)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8.0),
                  child: Row(
                    children: [
                      CupertinoActivityIndicator(radius: 10),
                      SizedBox(width: 8),
                      Text(
                        'Checking user...',
                        style: TextStyle(
                          color: CupertinoColors.secondaryLabel,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                )
              else if (_userExists != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: Row(
                    children: [
                      Icon(
                        _userExists!
                            ? CupertinoIcons.check_mark_circled_solid
                            : CupertinoIcons.xmark_circle,
                        color: _userExists!
                            ? CupertinoColors.systemGreen
                            : CupertinoColors.systemRed,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _userExists!
                              ? 'User found'
                              : (_userCheckError ?? 'User not found'),
                          style: TextStyle(
                            color: _userExists!
                                ? CupertinoColors.systemGreen
                                : CupertinoColors.systemRed,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (_inviteError != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(top: 8),
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
                          _inviteError!,
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
                            _inviteError = null;
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
              const Spacer(),
              CupertinoButton.filled(
                onPressed: (_userExists == true && !_isInviting && !_isSelf)
                    ? _inviteUser
                    : null,
                child: _isInviting
                    ? const CupertinoActivityIndicator(
                        color: CupertinoColors.white,
                      )
                    : const Text('Invite'),
              ),
              const SizedBox(height: 8),
              CupertinoButton(
                onPressed: _isInviting
                    ? null
                    : () {
                        Navigator.of(context).pop();
                      },
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

