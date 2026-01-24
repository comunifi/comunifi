import 'package:comunifi/state/group.dart';
import 'package:comunifi/theme/colors.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

/// Widget that displays an offline indicator banner at the top of the screen
/// when the app is not connected to the relay
class OfflineIndicator extends StatelessWidget {
  const OfflineIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return Consumer<GroupState>(
      builder: (context, groupState, child) {
        // Only show when offline
        if (groupState.isConnected) {
          return const SizedBox.shrink();
        }

        return SafeArea(
          bottom: false,
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: AppColors.error.withOpacity(0.9),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
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
            ),
          ),
        );
      },
    );
  }
}

