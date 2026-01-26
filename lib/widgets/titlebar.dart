import 'dart:io' show Platform;
import 'package:comunifi/state/app.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/profile.dart';
import 'package:comunifi/services/profile/profile.dart' show ProfileData;
import 'package:comunifi/theme/colors.dart';
import 'package:comunifi/screens/feed/feed_screen.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

class Titlebar extends StatefulWidget {
  final GlobalKey<NavigatorState>? rootNavigatorKey;

  const Titlebar({super.key, this.rootNavigatorKey});

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
        final isOffline = !groupState.isConnected;

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
                color: AppColors.background,
                border: const Border(
                  bottom: BorderSide(
                    color: AppColors.separator,
                    width: 0.5,
                  ),
                ),
              ),
              child: Row(
                children: [
                  // Left side: offline indicator
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        if (isOffline)
                          const Icon(
                            CupertinoIcons.wifi_slash,
                            color: AppColors.warning,
                            size: 16,
                          ),
                        const SizedBox(width: 8),
                      ],
                    ),
                  ),
                  // Center: logo and "Comunifi" text
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Image.asset(
                          'assets/logo.png',
                          width: 20,
                          height: 20,
                          fit: BoxFit.contain,
                        ),
                        const SizedBox(width: 6),
                        const Text(
                          'Comunifi',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: AppColors.label,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Right side: Profile avatar button and settings icon (before window controls on Windows)
                  Expanded(
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.end,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _ProfileAvatarButton(
                          profilePicture: profilePicture,
                          username: username,
                        ),
                        const SizedBox(width: 4),
                        _SettingsButton(),
                        // Padding on right side
                        const SizedBox(width: 8),
                        // Window controls (Windows only)
                        if (_isWindows) const _WindowControls(),
                      ],
                    ),
                  ),
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
    final appState = context.read<AppState>();

    return ValueListenableBuilder<RightSidebarType?>(
      valueListenable: appState.rightSidebarType,
      builder: (context, rightSidebarType, child) {
        final isActive = rightSidebarType == RightSidebarType.profile;

        return MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: GestureDetector(
            onTap: () {
              // Trigger profile sidebar via AppState
              appState.onProfileTap();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                color: isActive
                    ? CupertinoColors.activeBlue.withOpacity(0.1)
                    : (_isHovered
                        ? AppColors.chipBackground
                        : CupertinoColors.transparent),
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
                        color: isActive
                            ? CupertinoColors.activeBlue
                            : AppColors.label,
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
                      color: AppColors.surfaceElevated,
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: widget.profilePicture != null
                        ? Image.network(
                            widget.profilePicture!,
                            width: avatarSize,
                            height: avatarSize,
                            cacheWidth: avatarSize.toInt(),
                            cacheHeight: avatarSize.toInt(),
                            fit: BoxFit.cover,
                            loadingBuilder: (context, child, loadingProgress) {
                              if (loadingProgress == null) return child;
                              return Icon(
                                CupertinoIcons.person_fill,
                                size: avatarSize * 0.6,
                                color: AppColors.secondaryLabel,
                              );
                            },
                            errorBuilder: (context, error, stackTrace) {
                              return Icon(
                                CupertinoIcons.person_fill,
                                size: avatarSize * 0.6,
                                color: AppColors.secondaryLabel,
                              );
                            },
                          )
                        : Icon(
                            CupertinoIcons.person_fill,
                            size: avatarSize * 0.6,
                            color: AppColors.secondaryLabel,
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Settings icon button in the titlebar
class _SettingsButton extends StatefulWidget {
  const _SettingsButton();

  @override
  State<_SettingsButton> createState() => _SettingsButtonState();
}

class _SettingsButtonState extends State<_SettingsButton> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final appState = context.read<AppState>();

    return ValueListenableBuilder<RightSidebarType?>(
      valueListenable: appState.rightSidebarType,
      builder: (context, rightSidebarType, child) {
        final isActive = rightSidebarType == RightSidebarType.settings;

        return MouseRegion(
          onEnter: (_) => setState(() => _isHovered = true),
          onExit: (_) => setState(() => _isHovered = false),
          child: GestureDetector(
            onTap: () {
              // Trigger settings sidebar via AppState
              appState.onSettingsTap();
            },
            child: Container(
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: isActive
                    ? CupertinoColors.activeBlue.withOpacity(0.1)
                    : (_isHovered
                        ? AppColors.chipBackground
                        : CupertinoColors.transparent),
              ),
              child: Icon(
                CupertinoIcons.settings,
                size: 16,
                color: isActive
                    ? CupertinoColors.activeBlue
                    : AppColors.label,
              ),
            ),
          ),
        );
      },
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
