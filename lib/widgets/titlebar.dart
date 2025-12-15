import 'dart:io' show Platform;
import 'package:comunifi/state/app.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/profile.dart';
import 'package:comunifi/services/profile/profile.dart' show ProfileData;
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

class Titlebar extends StatefulWidget {
  const Titlebar({super.key});

  @override
  State<Titlebar> createState() => _TitlebarState();
}

class _TitlebarState extends State<Titlebar> {
  bool get _isDesktop => Platform.isMacOS || Platform.isWindows;
  bool get _isWindows => Platform.isWindows;

  String? _userPubkey;

  @override
  void initState() {
    super.initState();
    _loadUserPubkey();
  }

  Future<void> _loadUserPubkey() async {
    final groupState = context.read<GroupState>();
    final pubkey = await groupState.getNostrPublicKey();
    if (mounted && pubkey != null) {
      setState(() {
        _userPubkey = pubkey;
      });
      // Ensure profile is loaded
      context.read<ProfileState>().getProfile(pubkey);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<GroupState>(
      builder: (context, groupState, child) {
        // State logic runs everywhere
        // final isOffline = !groupState.isConnected;
        final isOffline = groupState.isConnected;

        // UI only on macOS + Windows
        if (!_isDesktop) {
          return const SizedBox.shrink();
        }

        // Get profile for avatar and username
        final profile = _userPubkey != null
            ? context.select<ProfileState, ProfileData?>(
                (state) => state.profiles[_userPubkey],
              )
            : null;
        final profilePicture = profile?.picture;
        final username =
            profile?.getUsername() ??
            (_userPubkey != null && _userPubkey!.length > 12
                ? '${_userPubkey!.substring(0, 6)}...${_userPubkey!.substring(_userPubkey!.length - 6)}'
                : _userPubkey);

        return SafeArea(
          bottom: false,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: _isWindows
                ? (_) => windowManager.startDragging()
                : null,
            child: Container(
              width: double.infinity,
              height: 36,
              padding: const EdgeInsets.symmetric(horizontal: 0),
              decoration: BoxDecoration(
                color: CupertinoColors.systemBackground,
                border: const Border(
                  bottom: BorderSide(
                    color: CupertinoColors.separator,
                    width: 0.5,
                  ),
                ),
              ),
              child: Row(
                children: [
                  // Center content (offline indicator)
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (isOffline)
                          const Icon(
                            CupertinoIcons.wifi_slash,
                            color: CupertinoColors.systemGrey,
                            size: 16,
                          ),
                        const SizedBox(width: 8),
                      ],
                    ),
                  ),
                  // Profile avatar button (before window controls on Windows)
                  _ProfileAvatarButton(
                    profilePicture: profilePicture,
                    username: username,
                  ),
                  // Window controls (Windows only)
                  if (_isWindows) const _WindowControls(),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Profile avatar button in the titlebar
class _ProfileAvatarButton extends StatefulWidget {
  final String? profilePicture;
  final String? username;

  const _ProfileAvatarButton({
    required this.profilePicture,
    required this.username,
  });

  @override
  State<_ProfileAvatarButton> createState() => _ProfileAvatarButtonState();
}

class _ProfileAvatarButtonState extends State<_ProfileAvatarButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    const avatarSize = 24.0;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: () {
          // Signal to FeedScreen to open the profile sidebar
          context.read<AppState>().onProfileTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: _isHovered
                ? CupertinoColors.systemGrey5
                : CupertinoColors.transparent,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Username
              if (widget.username != null) ...[
                Text(
                  widget.username!,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: CupertinoColors.label,
                  ),
                ),
                const SizedBox(width: 6),
              ],
              // Avatar
              Container(
                width: avatarSize,
                height: avatarSize,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: CupertinoColors.systemGrey4,
                ),
                clipBehavior: Clip.antiAlias,
                child: widget.profilePicture != null
                    ? Image.network(
                        widget.profilePicture!,
                        width: avatarSize,
                        height: avatarSize,
                        fit: BoxFit.cover,
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return Icon(
                            CupertinoIcons.person_fill,
                            size: avatarSize * 0.6,
                            color: CupertinoColors.systemGrey,
                          );
                        },
                        errorBuilder: (context, error, stackTrace) {
                          return Icon(
                            CupertinoIcons.person_fill,
                            size: avatarSize * 0.6,
                            color: CupertinoColors.systemGrey,
                          );
                        },
                      )
                    : Icon(
                        CupertinoIcons.person_fill,
                        size: avatarSize * 0.6,
                        color: CupertinoColors.systemGrey,
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WindowControls extends StatefulWidget {
  const _WindowControls();

  @override
  State<_WindowControls> createState() => _WindowControlsState();
}

class _WindowControlsState extends State<_WindowControls> {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    _checkMaximized();
  }

  Future<void> _checkMaximized() async {
    final isMaximized = await windowManager.isMaximized();
    if (mounted) {
      setState(() => _isMaximized = isMaximized);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WindowButton(
          icon: CupertinoIcons.minus,
          onPressed: () => windowManager.minimize(),
        ),
        _WindowButton(
          icon: _isMaximized
              ? CupertinoIcons.square_on_square
              : CupertinoIcons.square,
          onPressed: () async {
            if (_isMaximized) {
              await windowManager.unmaximize();
            } else {
              await windowManager.maximize();
            }
            await _checkMaximized();
          },
        ),
        _WindowButton(
          icon: CupertinoIcons.xmark,
          onPressed: () => windowManager.close(),
          isClose: true,
        ),
      ],
    );
  }
}

class _WindowButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onPressed;
  final bool isClose;

  const _WindowButton({
    required this.icon,
    required this.onPressed,
    this.isClose = false,
  });

  @override
  State<_WindowButton> createState() => _WindowButtonState();
}

class _WindowButtonState extends State<_WindowButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: _isHovered
                ? (widget.isClose
                      ? CupertinoColors.systemRed
                      : CupertinoColors.systemGrey5)
                : CupertinoColors.transparent,
          ),
          child: Icon(
            widget.icon,
            size: 14,
            color: _isHovered && widget.isClose
                ? CupertinoColors.white
                : CupertinoColors.label,
          ),
        ),
      ),
    );
  }
}
