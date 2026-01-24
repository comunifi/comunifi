import 'package:comunifi/screens/post/post_detail_modal.dart';
import 'package:comunifi/theme/colors.dart';
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
        final screenWidth = MediaQuery.of(context).size.width;
        final isWideScreen = screenWidth > 1000;
        
        if (isWideScreen) {
          // Desktop: show as modal
          showCupertinoModalPopup(
            context: context,
            builder: (modalContext) => PostDetailModal(postId: eventId),
          );
        } else {
          // Mobile: navigate to screen
          context.push('/post/$eventId');
        }
      },
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            CupertinoIcons.chat_bubble,
            size: 20,
            color: AppColors.primary,
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
                color: AppColors.primary,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

