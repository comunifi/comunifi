import 'dart:io' show Platform;
import 'package:comunifi/state/group.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

class Titlebar extends StatelessWidget {
  const Titlebar({super.key});

  bool get _isDesktop => Platform.isMacOS || Platform.isWindows;
  bool get _isWindows => Platform.isWindows;

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

        return SafeArea(
          bottom: false,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: _isWindows ? (_) => windowManager.startDragging() : null,
            child: Container(
              width: double.infinity,
              height: 32,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: isOffline
                    ? CupertinoColors.systemRed.withOpacity(0.9)
                    : CupertinoColors.systemBackground,
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
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        if (isOffline) ...[
                          const Icon(
                            CupertinoIcons.wifi_slash,
                            color: CupertinoColors.white,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Offline - Showing cached content',
                            style: TextStyle(
                              color: CupertinoColors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ],
                    ),
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
