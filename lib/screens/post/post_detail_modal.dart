import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/post_detail.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/screens/post/post_detail_screen.dart';

/// Modal for viewing post details and comments
/// Shows as a bottom sheet on desktop (wide screens)
class PostDetailModal extends StatefulWidget {
  final String postId;

  const PostDetailModal({super.key, required this.postId});

  @override
  State<PostDetailModal> createState() => _PostDetailModalState();
}

class _PostDetailModalState extends State<PostDetailModal> {
  late final PostDetailState _postDetailState;
  GroupState? _groupState;
  StreamSubscription<NostrEventModel>? _commentSubscription;

  @override
  void initState() {
    super.initState();
    _postDetailState = PostDetailState(widget.postId);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Try to get GroupState from the parent context (if available)
    // This enables encrypted comment publishing and receiving for group posts
    try {
      _groupState = context.read<GroupState>();
      _postDetailState.onPublishGroupComment = _groupState!.publishGroupComment;

      // Subscribe to decrypted comments for live updates
      _commentSubscription?.cancel();
      _commentSubscription = _groupState!.decryptedCommentUpdates.listen((
        comment,
      ) {
        // Forward the comment to PostDetailState
        // It will filter for comments relevant to this post
        _postDetailState.addDecryptedComment(comment);
      });
    } catch (e) {
      // GroupState not available in this context - comments will only work for non-group posts
    }
  }

  @override
  void dispose() {
    _commentSubscription?.cancel();
    _postDetailState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _postDetailState,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Container(
          width: double.infinity,
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
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        CupertinoButton(
                          padding: EdgeInsets.zero,
                          minSize: 0,
                          onPressed: () => Navigator.of(context).pop(),
                          child: const Icon(CupertinoIcons.xmark, size: 24),
                        ),
                      ],
                    ),
                  ),
                  Container(height: 0.5, color: CupertinoColors.separator),
                  // Post detail content
                  Expanded(child: PostDetailContent(postId: widget.postId)),
                ],
              ),
            ),
          ),
        ),
      );
  }
}
