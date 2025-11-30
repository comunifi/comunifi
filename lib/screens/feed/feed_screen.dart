import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/feed.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/models/nostr_event.dart';

class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _messageController = TextEditingController();
  bool _isPublishing = false;
  String? _publishError;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  Future<void> _publishMessage() async {
    final content = _messageController.text.trim();
    if (content.isEmpty || _isPublishing) return;

    final groupState = context.read<GroupState>();
    
    // If there's an active group, post to the group
    if (groupState.activeGroup != null) {
      if (!groupState.isConnected) {
        setState(() {
          _publishError = 'Not connected to relay';
        });
        return;
      }

      setState(() {
        _isPublishing = true;
        _publishError = null;
      });

      try {
        await groupState.postMessage(content);
        _messageController.clear();
        setState(() {
          _isPublishing = false;
        });
      } catch (e) {
        setState(() {
          _isPublishing = false;
          _publishError = e.toString();
        });
      }
      return;
    }

    // Otherwise, use regular feed
    final feedState = context.read<FeedState>();
    if (!feedState.isConnected) {
      setState(() {
        _publishError = 'Not connected to relay';
      });
      return;
    }

    setState(() {
      _isPublishing = true;
      _publishError = null;
    });

    try {
      await feedState.publishMessage(content);
      _messageController.clear();
      setState(() {
        _isPublishing = false;
      });
    } catch (e) {
      setState(() {
        _isPublishing = false;
        _publishError = e.toString();
      });
    }
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent * 0.8) {
      // Load more when scrolled 80% down
      final feedState = context.read<FeedState>();
      if (feedState.hasMoreEvents && !feedState.isLoadingMore) {
        feedState.loadMoreEvents();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer2<FeedState, GroupState>(
      builder: (context, feedState, groupState, child) {
        final activeGroup = groupState.activeGroup;
        return CupertinoPageScaffold(
          navigationBar: CupertinoNavigationBar(
            middle: Text(activeGroup?.name ?? 'Feed'),
            trailing: activeGroup != null
                ? CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () {
                      groupState.setActiveGroup(null);
                    },
                    child: const Text('Exit Group'),
                  )
                : null,
          ),
          child: SafeArea(
            child: Builder(
              builder: (context) {
                // If there's an active group, show group messages
            if (groupState.activeGroup != null) {
              if (!groupState.isConnected && groupState.errorMessage != null) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        groupState.errorMessage!,
                        style: const TextStyle(color: CupertinoColors.systemRed),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 16),
                      CupertinoButton(
                        onPressed: groupState.retryConnection,
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                );
              }

              if (groupState.isLoading && groupState.groupMessages.isEmpty) {
                return const Center(
                  child: CupertinoActivityIndicator(),
                );
              }

              return Column(
                children: [
                  Expanded(
                    child: groupState.groupMessages.isEmpty
                        ? const Center(
                            child: Text('No messages in this group yet'),
                          )
                        : CustomScrollView(
                            controller: _scrollController,
                            slivers: [
                              CupertinoSliverRefreshControl(
                                onRefresh: () async {
                                  await groupState.refreshActiveGroupMessages();
                                },
                              ),
                              SliverList(
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) {
                                    if (index < groupState.groupMessages.length) {
                                      return _EventItem(
                                        event: groupState.groupMessages[index],
                                      );
                                    }
                                    return const SizedBox.shrink();
                                  },
                                  childCount: groupState.groupMessages.length,
                                ),
                              ),
                            ],
                          ),
                  ),
                  _ComposeMessageWidget(
                    controller: _messageController,
                    isPublishing: _isPublishing,
                    error: _publishError,
                    onPublish: _publishMessage,
                    placeholder: 'Write a message to ${groupState.activeGroup!.name}...',
                    onErrorDismiss: () {
                      setState(() {
                        _publishError = null;
                      });
                    },
                  ),
                ],
              );
            }

            // Otherwise, show regular feed
            if (!feedState.isConnected && feedState.errorMessage != null) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      feedState.errorMessage!,
                      style: const TextStyle(color: CupertinoColors.systemRed),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 16),
                    CupertinoButton(
                      onPressed: feedState.retryConnection,
                      child: const Text('Retry'),
                    ),
                  ],
                ),
              );
            }

            if (feedState.isLoading && feedState.events.isEmpty) {
              return const Center(
                child: CupertinoActivityIndicator(),
              );
            }

            return Column(
              children: [
                Expanded(
                  child: feedState.events.isEmpty
                      ? const Center(
                          child: Text('No events yet'),
                        )
                      : CustomScrollView(
                          controller: _scrollController,
                          slivers: [
                            CupertinoSliverRefreshControl(
                              onRefresh: () async {
                                await feedState.retryConnection();
                              },
                            ),
                            SliverList(
                              delegate: SliverChildBuilderDelegate(
                                (context, index) {
                                  if (index < feedState.events.length) {
                                    return _EventItem(
                                      event: feedState.events[index],
                                    );
                                  } else if (feedState.isLoadingMore) {
                                    return const Padding(
                                      padding: EdgeInsets.all(16.0),
                                      child: Center(
                                        child: CupertinoActivityIndicator(),
                                      ),
                                    );
                                  } else if (feedState.hasMoreEvents) {
                                    return const SizedBox.shrink();
                                  } else {
                                    return const Padding(
                                      padding: EdgeInsets.all(16.0),
                                      child: Center(
                                        child: Text(
                                          'No more events',
                                          style: TextStyle(
                                            color:
                                                CupertinoColors.secondaryLabel,
                                          ),
                                        ),
                                      ),
                                    );
                                  }
                                },
                                childCount: feedState.events.length +
                                    (feedState.isLoadingMore ? 1 : 0) +
                                    (feedState.hasMoreEvents ? 0 : 1),
                              ),
                            ),
                          ],
                        ),
                ),
                _ComposeMessageWidget(
                  controller: _messageController,
                  isPublishing: _isPublishing,
                  error: _publishError,
                  onPublish: _publishMessage,
                  onErrorDismiss: () {
                    setState(() {
                      _publishError = null;
                    });
                  },
                ),
              ],
            );
              },
            ),
          ),
        );
      },
    );
  }
}

class _EventItem extends StatelessWidget {
  final NostrEventModel event;

  const _EventItem({required this.event});

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays > 0) {
      return '${difference.inDays}d ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours}h ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes}m ago';
    } else {
      return 'Just now';
    }
  }

  String _truncatePubkey(String pubkey) {
    if (pubkey.length <= 12) return pubkey;
    return '${pubkey.substring(0, 6)}...${pubkey.substring(pubkey.length - 6)}';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: CupertinoColors.separator,
            width: 0.5,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                _truncatePubkey(event.pubkey),
                style: const TextStyle(
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _formatDate(event.createdAt),
                style: const TextStyle(
                  color: CupertinoColors.secondaryLabel,
                  fontSize: 12,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            event.content,
            style: const TextStyle(fontSize: 15),
          ),
        ],
      ),
    );
  }
}

class _ComposeMessageWidget extends StatelessWidget {
  final TextEditingController controller;
  final bool isPublishing;
  final String? error;
  final VoidCallback onPublish;
  final VoidCallback onErrorDismiss;
  final String? placeholder;

  const _ComposeMessageWidget({
    required this.controller,
    required this.isPublishing,
    this.error,
    required this.onPublish,
    required this.onErrorDismiss,
    this.placeholder,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground,
        border: Border(
          top: BorderSide(
            color: CupertinoColors.separator,
            width: 0.5,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (error != null)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 8.0,
                ),
                color: CupertinoColors.systemRed.withOpacity(0.1),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        error!,
                        style: const TextStyle(
                          color: CupertinoColors.systemRed,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      minSize: 0,
                      onPressed: onErrorDismiss,
                      child: const Icon(
                        CupertinoIcons.xmark_circle_fill,
                        color: CupertinoColors.systemRed,
                        size: 20,
                      ),
                    ),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: CupertinoTextField(
                      controller: controller,
                      placeholder: placeholder ?? 'Write a message...',
                      maxLines: null,
                      minLines: 1,
                      textInputAction: TextInputAction.newline,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12.0,
                        vertical: 8.0,
                      ),
                      decoration: BoxDecoration(
                        color: CupertinoColors.systemGrey6,
                        borderRadius: BorderRadius.circular(20.0),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 0,
                    onPressed: isPublishing ? null : onPublish,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: isPublishing
                            ? CupertinoColors.systemGrey
                            : CupertinoColors.systemBlue,
                        shape: BoxShape.circle,
                      ),
                      child: isPublishing
                          ? const CupertinoActivityIndicator(
                              color: CupertinoColors.white,
                            )
                          : const Icon(
                              CupertinoIcons.arrow_up,
                              color: CupertinoColors.white,
                              size: 20,
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
