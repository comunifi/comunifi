import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';

class CommentBubble extends StatelessWidget {
  final String eventId;
  final int commentCount;
  final bool isLoadingCount;

  const CommentBubble({
    super.key,
    required this.eventId,
    required this.commentCount,
    required this.isLoadingCount,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minSize: 0,
      onPressed: () {
        context.push('/post/$eventId');
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.chat_bubble,
            size: 20,
            color: CupertinoColors.systemBlue,
          ),
          if (isLoadingCount)
            const SizedBox(
              width: 16,
              height: 16,
              child: CupertinoActivityIndicator(radius: 8),
            )
          else if (commentCount > 0) ...[
            const SizedBox(width: 4),
            Text(
              commentCount.toString(),
              style: const TextStyle(
                fontSize: 14,
                color: CupertinoColors.systemBlue,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

