import 'package:comunifi/theme/colors.dart';
import 'package:flutter/cupertino.dart';

class HeartButton extends StatelessWidget {
  final String eventId;
  final int reactionCount;
  final bool isLoadingCount;
  final bool isReacted;
  final VoidCallback onPressed;

  const HeartButton({
    super.key,
    required this.eventId,
    required this.reactionCount,
    required this.isLoadingCount,
    required this.isReacted,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minSize: 0,
      onPressed: onPressed,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            isReacted ? CupertinoIcons.heart_fill : CupertinoIcons.heart,
            size: 20,
            color: isReacted
                ? AppColors.accent
                : AppColors.primary,
          ),
          if (isLoadingCount)
            const SizedBox(
              width: 16,
              height: 16,
              child: CupertinoActivityIndicator(radius: 8),
            )
          else ...[
            const SizedBox(width: 4),
            Text(
              reactionCount.toString(),
              style: TextStyle(
                fontSize: 14,
                color: isReacted
                    ? AppColors.accent
                    : AppColors.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

