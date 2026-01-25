import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import 'package:comunifi/state/group.dart';
import 'package:comunifi/services/nostr/group_channel.dart';

/// Modal for managing channel pinning and ordering (admin-only).
///
/// Allows admins to:
/// - Pin/unpin channels
/// - Reorder pinned channels
class ChannelManagementModal extends StatefulWidget {
  final GroupAnnouncement announcement;

  const ChannelManagementModal({super.key, required this.announcement});

  @override
  State<ChannelManagementModal> createState() => _ChannelManagementModalState();
}

class _ChannelManagementModalState extends State<ChannelManagementModal> {
  bool _isLoading = false;
  bool _isAdmin = false;
  bool _checkingAdmin = true;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _checkAdminStatus();
  }

  Future<void> _checkAdminStatus() async {
    if (!mounted) return;
    
    final groupState = context.read<GroupState>();
    final groupIdHex = widget.announcement.mlsGroupId;
    if (groupIdHex == null) {
      if (mounted) {
        setState(() {
          _checkingAdmin = false;
          _isAdmin = false;
        });
      }
      return;
    }

    try {
      final admin = await groupState.isGroupAdmin(groupIdHex);
      if (mounted) {
        setState(() {
          _isAdmin = admin;
          _checkingAdmin = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isAdmin = false;
          _checkingAdmin = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: CupertinoColors.systemGrey3.resolveFrom(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Done'),
                  ),
                  const Expanded(
                    child: Text(
                      'Manage Channels',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // Spacer for symmetry
                  const SizedBox(width: 50),
                ],
              ),
            ),

            Container(
              height: 0.5,
              color: CupertinoColors.separator.resolveFrom(context),
            ),

            // Content
            Expanded(
              child: _checkingAdmin
                  ? const Center(child: CupertinoActivityIndicator())
                  : !_isAdmin
                      ? _buildNotAdminView(context)
                      : _buildChannelList(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNotAdminView(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              CupertinoIcons.lock,
              size: 48,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
            const SizedBox(height: 16),
            Text(
              'Admin Only',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: CupertinoColors.label.resolveFrom(context),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Only group admins can manage channel pinning and ordering.',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelList(BuildContext context) {
    final groupState = context.watch<GroupState>();
    final groupIdHex = widget.announcement.mlsGroupId;
    if (groupIdHex == null) {
      return const Center(child: Text('No group selected'));
    }

    final channels = groupState.activeGroupChannels;
    final pinnedChannels = channels
        .where((c) =>
            c.extra?['pinned'] == true &&
            c.name.toLowerCase() != 'general')
        .toList()
      ..sort((a, b) {
        final aOrder = a.extra?['order'] as num? ?? double.infinity;
        final bOrder = b.extra?['order'] as num? ?? double.infinity;
        return aOrder.compareTo(bOrder);
      });
    final unpinnedChannels = channels
        .where((c) =>
            c.extra?['pinned'] != true &&
            c.name.toLowerCase() != 'general')
        .toList();

    if (_errorMessage != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        showCupertinoDialog(
          context: context,
          builder: (dialogContext) => CupertinoAlertDialog(
            title: const Text('Error'),
            content: Text(_errorMessage!),
            actions: [
              CupertinoDialogAction(
                isDefaultAction: true,
                onPressed: () {
                  Navigator.of(dialogContext).pop();
                  setState(() => _errorMessage = null);
                },
                child: const Text('OK'),
              ),
            ],
          ),
        );
      });
    }

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Pinned Channels Section
        if (pinnedChannels.isNotEmpty) ...[
          _buildSectionHeader(context, 'Pinned Channels'),
          const SizedBox(height: 8),
          _buildSettingsCard(
            context,
            children: [
              for (int i = 0; i < pinnedChannels.length; i++)
                _buildPinnedChannelTile(
                  context,
                  pinnedChannels[i],
                  i,
                  pinnedChannels.length,
                  groupIdHex,
                ),
            ],
          ),
          const SizedBox(height: 24),
        ],

        // Unpinned Channels Section
        _buildSectionHeader(context, 'Unpinned Channels'),
        const SizedBox(height: 8),
        _buildSettingsCard(
          context,
          children: [
            for (final channel in unpinnedChannels)
              _buildUnpinnedChannelTile(
                context,
                channel,
                groupIdHex,
              ),
          ],
        ),

        const SizedBox(height: 32),
      ],
    );
  }

  Widget _buildPinnedChannelTile(
    BuildContext context,
    GroupChannelMetadata channel,
    int index,
    int total,
    String groupIdHex,
  ) {
    final isFirst = index == 0;
    final isLast = index == total - 1;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              // Pin icon
              Icon(
                CupertinoIcons.pin_fill,
                size: 16,
                color: CupertinoColors.systemOrange.resolveFrom(context),
              ),
              const SizedBox(width: 12),

              // Channel name
              Expanded(
                child: Text(
                  channel.name,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: CupertinoColors.label.resolveFrom(context),
                  ),
                ),
              ),

              // Up button
              CupertinoButton(
                padding: EdgeInsets.zero,
                minSize: 0,
                onPressed: isFirst || _isLoading
                    ? null
                    : () => _moveChannelUp(groupIdHex, channel, index),
                child: Icon(
                  CupertinoIcons.chevron_up,
                  size: 20,
                  color: isFirst || _isLoading
                      ? CupertinoColors.tertiaryLabel.resolveFrom(context)
                      : CupertinoColors.label.resolveFrom(context),
                ),
              ),

              const SizedBox(width: 8),

              // Down button
              CupertinoButton(
                padding: EdgeInsets.zero,
                minSize: 0,
                onPressed: isLast || _isLoading
                    ? null
                    : () => _moveChannelDown(groupIdHex, channel, index),
                child: Icon(
                  CupertinoIcons.chevron_down,
                  size: 20,
                  color: isLast || _isLoading
                      ? CupertinoColors.tertiaryLabel.resolveFrom(context)
                      : CupertinoColors.label.resolveFrom(context),
                ),
              ),

              const SizedBox(width: 8),

              // Unpin toggle
              CupertinoSwitch(
                value: true,
                onChanged: _isLoading
                    ? null
                    : (value) => _togglePin(groupIdHex, channel, false),
              ),
            ],
          ),
        ),
        if (!isLast) _buildDivider(context),
      ],
    );
  }

  Widget _buildUnpinnedChannelTile(
    BuildContext context,
    GroupChannelMetadata channel,
    String groupIdHex,
  ) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          child: Row(
            children: [
              const SizedBox(width: 28), // Space for pin icon alignment
              // Channel name
              Expanded(
                child: Text(
                  channel.name,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: CupertinoColors.label.resolveFrom(context),
                  ),
                ),
              ),

              // Pin toggle
              CupertinoSwitch(
                value: false,
                onChanged: _isLoading
                    ? null
                    : (value) => _togglePin(groupIdHex, channel, true),
              ),
            ],
          ),
        ),
        _buildDivider(context),
      ],
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: CupertinoColors.secondaryLabel.resolveFrom(context),
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildSettingsCard(
    BuildContext context, {
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(children: children),
    );
  }

  Widget _buildDivider(BuildContext context) {
    return Container(
      height: 0.5,
      margin: const EdgeInsets.only(left: 52),
      color: CupertinoColors.separator.resolveFrom(context),
    );
  }

  Future<void> _togglePin(
    String groupIdHex,
    GroupChannelMetadata channel,
    bool pinned,
  ) async {
    if (channel.id.isEmpty) {
      setState(() {
        _errorMessage = 'Cannot pin/unpin synthetic channels';
      });
      return;
    }

    setState(() => _isLoading = true);

    try {
      final groupState = context.read<GroupState>();
      await groupState.pinChannel(groupIdHex, channel.id, pinned);
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to ${pinned ? 'pin' : 'unpin'} channel: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _moveChannelUp(
    String groupIdHex,
    GroupChannelMetadata channel,
    int currentIndex,
  ) async {
    if (channel.id.isEmpty) return;

    final groupState = context.read<GroupState>();
    final channels = groupState.activeGroupChannels
        .where((c) => c.extra?['pinned'] == true)
        .toList()
      ..sort((a, b) {
        final aOrder = a.extra?['order'] as num? ?? double.infinity;
        final bOrder = b.extra?['order'] as num? ?? double.infinity;
        return aOrder.compareTo(bOrder);
      });

    if (currentIndex == 0) return;

    // Swap with previous channel
    final prevChannel = channels[currentIndex - 1];
    final temp = channels[currentIndex];
    channels[currentIndex] = prevChannel;
    channels[currentIndex - 1] = temp;

    // Update order values
    final channelIds = channels.map((c) => c.id).where((id) => id.isNotEmpty).toList();

    setState(() => _isLoading = true);

    try {
      await groupState.reorderPinnedChannels(groupIdHex, channelIds);
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to reorder channels: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  Future<void> _moveChannelDown(
    String groupIdHex,
    GroupChannelMetadata channel,
    int currentIndex,
  ) async {
    if (channel.id.isEmpty) return;

    final groupState = context.read<GroupState>();
    final channels = groupState.activeGroupChannels
        .where((c) => c.extra?['pinned'] == true)
        .toList()
      ..sort((a, b) {
        final aOrder = a.extra?['order'] as num? ?? double.infinity;
        final bOrder = b.extra?['order'] as num? ?? double.infinity;
        return aOrder.compareTo(bOrder);
      });

    if (currentIndex >= channels.length - 1) return;

    // Swap with next channel
    final nextChannel = channels[currentIndex + 1];
    final temp = channels[currentIndex];
    channels[currentIndex] = nextChannel;
    channels[currentIndex + 1] = temp;

    // Update order values
    final channelIds = channels.map((c) => c.id).where((id) => id.isNotEmpty).toList();

    setState(() => _isLoading = true);

    try {
      await groupState.reorderPinnedChannels(groupIdHex, channelIds);
    } catch (e) {
      setState(() {
        _errorMessage = 'Failed to reorder channels: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }
}

/// Shows the channel management modal as a bottom sheet.
/// Only call this for group admins.
Future<void> showChannelManagementModal(
  BuildContext context,
  GroupAnnouncement announcement,
) {
  return showCupertinoModalPopup<void>(
    context: context,
    builder: (context) => SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: ChannelManagementModal(announcement: announcement),
    ),
  );
}
