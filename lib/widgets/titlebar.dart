import 'dart:io' show Platform;
import 'package:comunifi/state/group.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

class Titlebar extends StatelessWidget {
  const Titlebar({super.key});

  bool get _isDesktop =>
      Platform.isMacOS || Platform.isWindows;

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
        );
      },
    );
  }
}
