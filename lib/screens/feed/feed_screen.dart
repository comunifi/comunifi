import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/feed.dart';
import 'package:comunifi/models/nostr_event.dart';

class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
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
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(
        middle: Text('Feed'),
      ),
      child: SafeArea(
        child: Consumer<FeedState>(
          builder: (context, feedState, child) {
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

            if (feedState.events.isEmpty) {
              return const Center(
                child: Text('No events yet'),
              );
            }

            return CustomScrollView(
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
                        return _EventItem(event: feedState.events[index]);
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
                                color: CupertinoColors.secondaryLabel,
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
            );
          },
        ),
      ),
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
