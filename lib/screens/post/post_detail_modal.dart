import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/post_detail.dart';
import 'package:comunifi/screens/post/post_detail_screen.dart';

/// Modal for viewing post details and comments
/// Shows as a bottom sheet on desktop (wide screens)
class PostDetailModal extends StatelessWidget {
  final String postId;

  const PostDetailModal({super.key, required this.postId});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => PostDetailState(postId),
      child: Container(
        height: MediaQuery.of(context).size.height * 0.85,
        decoration: const BoxDecoration(
          color: CupertinoColors.systemBackground,
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.only(top: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: CupertinoColors.systemGrey4,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Header
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Post',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      minSize: 0,
                      onPressed: () => Navigator.of(context).pop(),
                      child: const Icon(
                        CupertinoIcons.xmark,
                        size: 24,
                      ),
                    ),
                  ],
                ),
              ),
              Container(height: 0.5, color: CupertinoColors.separator),
              // Post detail content
              Expanded(
                child: PostDetailContent(postId: postId),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
