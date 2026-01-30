import 'package:comunifi/state/group.dart';
import 'package:comunifi/services/mls/mls_group.dart';
import 'package:comunifi/services/nostr/group_channel.dart';
import 'package:comunifi/theme/colors.dart';
import 'package:comunifi/l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

class ChannelsSidebar extends StatefulWidget {
  final VoidCallback onClose;
  final bool showCloseButton;

  const ChannelsSidebar({
    super.key,
    required this.onClose,
    this.showCloseButton = true,
  });

  @override
  State<ChannelsSidebar> createState() => _ChannelsSidebarState();
}

class _ChannelsSidebarState extends State<ChannelsSidebar> {
  bool _isAdmin = false;
  Set<String> _pinningChannels = {};
  String? _lastGroupIdHex;
  final TextEditingController _searchController = TextEditingController();

  String _groupIdToHex(MlsGroup group) {
    return group.id.bytes
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  @override
  void initState() {
    super.initState();
    _checkAdminStatus();
    _searchController.addListener(() {
      setState(() {});
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _checkAdminStatus() async {
    final groupState = context.read<GroupState>();
    final activeGroup = groupState.activeGroup;
    if (activeGroup == null) {
      if (mounted) {
        setState(() {
          _isAdmin = false;
        });
      }
      return;
    }

    final groupIdHex = _groupIdToHex(activeGroup);
    _lastGroupIdHex = groupIdHex;

    try {
      final isAdmin = await groupState.isGroupAdmin(groupIdHex);
      if (mounted && _lastGroupIdHex == groupIdHex) {
        setState(() {
          _isAdmin = isAdmin;
        });
      }
    } catch (e) {
      if (mounted && _lastGroupIdHex == groupIdHex) {
        setState(() {
          _isAdmin = false;
        });
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final groupState = context.watch<GroupState>();
    final activeGroup = groupState.activeGroup;
    final currentGroupIdHex = activeGroup != null
        ? _groupIdToHex(activeGroup)
        : null;
    if (currentGroupIdHex != _lastGroupIdHex) {
      _lastGroupIdHex = currentGroupIdHex;
      _checkAdminStatus();
    }
  }

  Future<void> _togglePin(
    String groupIdHex,
    GroupChannelMetadata channel,
    bool pinned,
  ) async {
    if (channel.id.isEmpty) {
      return;
    }

    setState(() {
      _pinningChannels.add(channel.id);
    });

    try {
      final groupState = context.read<GroupState>();
      await groupState.pinChannel(groupIdHex, channel.id, pinned);
    } catch (e) {
      if (mounted) {
        showCupertinoDialog(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: const Text('Error'),
            content: Text('Failed to ${pinned ? 'pin' : 'unpin'} channel: $e'),
            actions: [
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _pinningChannels.remove(channel.id);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<GroupState>(
      builder: (context, groupState, child) {
        final activeGroup = groupState.activeGroup;
        if (activeGroup == null) {
          return const SizedBox.shrink();
        }

        final groupIdHex = _groupIdToHex(activeGroup);
        final allChannels = groupState.activeGroupChannels;
        final activeChannelName = groupState.activeChannelName;

        // Filter channels based on search query
        final searchQuery = _searchController.text.toLowerCase();
        final channels = searchQuery.isEmpty
            ? allChannels
            : allChannels.where((channel) {
                return channel.name.toLowerCase().contains(searchQuery);
              }).toList();

        if (channels.isEmpty) {
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Text(
                  'No discussions',
                  style: TextStyle(
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ),
            ),
          );
        }

        return SafeArea(
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                decoration: const BoxDecoration(
                  color: CupertinoColors.white,
                  border: Border(
                    bottom: BorderSide(color: AppColors.separator, width: 0.5),
                  ),
                ),
                child: Row(
                  children: [
                    Builder(
                      builder: (context) {
                        final localizations = AppLocalizations.of(context);
                        final totalUnread = groupState
                            .getTotalUnreadCountForGroup(groupIdHex);
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              localizations?.discussions ?? 'Discussions',
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (totalUnread > 0) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: CupertinoColors.systemRed,
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Text(
                                  totalUnread > 99
                                      ? '99+'
                                      : totalUnread.toString(),
                                  style: const TextStyle(
                                    color: CupertinoColors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        );
                      },
                    ),
                    if (widget.showCloseButton) ...[
                      const Spacer(),
                      CupertinoButton(
                        padding: EdgeInsets.zero,
                        minSize: 0,
                        onPressed: widget.onClose,
                        child: const Icon(CupertinoIcons.xmark),
                      ),
                    ],
                  ],
                ),
              ),

              // Search field
              Padding(
                padding: const EdgeInsets.all(16),
                child: Builder(
                  builder: (context) {
                    final localizations = AppLocalizations.of(context);
                    return CupertinoSearchTextField(
                      controller: _searchController,
                      placeholder:
                          localizations?.searchDiscussions ??
                          'Search discussions...',
                    );
                  },
                ),
              ),

              // Channels list
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: channels.length,
                  itemBuilder: (context, index) {
                    final channel = channels[index];
                    final isActive =
                        channel.name.toLowerCase() == activeChannelName;
                    final isPinned = channel.extra?['pinned'] == true;
                    final isPinning = _pinningChannels.contains(channel.id);
                    final isGeneral = channel.name.toLowerCase() == 'general';
                    final showPinButton = _isAdmin && !isGeneral;

                    final unreadCount = groupState.getUnreadCountForChannel(
                      groupIdHex,
                      channel.name,
                    );

                    return Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      child: _ChannelTile(
                        channel: channel,
                        isActive: isActive,
                        isPinned: isPinned,
                        isPinning: isPinning,
                        showPinButton: showPinButton,
                        groupIdHex: groupIdHex,
                        unreadCount: unreadCount,
                        onTap: () {
                          groupState.setActiveChannel(channel.name);
                        },
                        onPinToggle: showPinButton
                            ? () {
                                _togglePin(groupIdHex, channel, !isPinned);
                              }
                            : null,
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ChannelTile extends StatelessWidget {
  final GroupChannelMetadata channel;
  final bool isActive;
  final bool isPinned;
  final bool isPinning;
  final bool showPinButton;
  final String groupIdHex;
  final int unreadCount;
  final VoidCallback onTap;
  final VoidCallback? onPinToggle;

  const _ChannelTile({
    required this.channel,
    required this.isActive,
    required this.isPinned,
    required this.isPinning,
    required this.showPinButton,
    required this.groupIdHex,
    required this.unreadCount,
    required this.onTap,
    this.onPinToggle,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      onPressed: onTap,
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isActive
              ? AppColors.primary.withOpacity(0.12)
              : AppColors.surface,
          borderRadius: BorderRadius.circular(10),
          border: isActive
              ? Border.all(color: AppColors.primary.withOpacity(0.4), width: 1)
              : null,
        ),
        child: Row(
          children: [
            // Pin indicator (if pinned and no pin button shown)
            if (isPinned && !showPinButton)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Icon(
                  CupertinoIcons.pin_fill,
                  size: 12,
                  color: CupertinoColors.systemOrange.resolveFrom(context),
                ),
              ),

            // Channel name
            Expanded(
              child: Text(
                channel.name,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                  color: isActive
                      ? CupertinoColors.activeBlue
                      : CupertinoColors.label.resolveFrom(context),
                ),
              ),
            ),

            // Unread badge
            if (unreadCount > 0) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: CupertinoColors.systemRed,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  unreadCount > 99 ? '99+' : unreadCount.toString(),
                  style: const TextStyle(
                    color: CupertinoColors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],

            // Pin button (admin-only)
            if (showPinButton) ...[
              GestureDetector(
                onTap: isPinning ? null : onPinToggle,
                behavior: HitTestBehavior.opaque,
                child: isPinning
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CupertinoActivityIndicator(
                          radius: 8,
                          color: CupertinoColors.tertiaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      )
                    : Icon(
                        isPinned ? CupertinoIcons.pin_fill : CupertinoIcons.pin,
                        size: 14,
                        color: isPinned
                            ? CupertinoColors.systemOrange.resolveFrom(context)
                            : CupertinoColors.tertiaryLabel.resolveFrom(
                                context,
                              ),
                      ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
