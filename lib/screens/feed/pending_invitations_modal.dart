import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/profile.dart';
import 'package:comunifi/services/db/pending_invitation.dart';
import 'package:comunifi/theme/colors.dart';

class PendingInvitationsModal extends StatefulWidget {
  const PendingInvitationsModal({super.key});

  @override
  State<PendingInvitationsModal> createState() =>
      _PendingInvitationsModalState();
}

class _PendingInvitationsModalState extends State<PendingInvitationsModal> {
  final Map<String, bool> _processingInvitations = {};

  @override
  void initState() {
    super.initState();
    // Ensure pending invitations are loaded
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final groupState = context.read<GroupState>();
      groupState.loadPendingInvitations();
    });
  }

  String _getTimeAgo(DateTime dateTime) {
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays > 0) {
      return '${difference.inDays} day${difference.inDays == 1 ? '' : 's'} ago';
    } else if (difference.inHours > 0) {
      return '${difference.inHours} hour${difference.inHours == 1 ? '' : 's'} ago';
    } else if (difference.inMinutes > 0) {
      return '${difference.inMinutes} minute${difference.inMinutes == 1 ? '' : 's'} ago';
    } else {
      return 'Just now';
    }
  }

  String _getGroupName(PendingInvitation invitation, GroupState groupState) {
    if (invitation.groupIdHex != null) {
      final announcement = groupState.getGroupAnnouncementByHexId(
        invitation.groupIdHex!,
      );
      if (announcement?.name != null) {
        return announcement!.name!;
      }
    }
    return 'Unknown Group';
  }

  String? _getGroupPicture(PendingInvitation invitation, GroupState groupState) {
    if (invitation.groupIdHex != null) {
      final announcement = groupState.getGroupAnnouncementByHexId(
        invitation.groupIdHex!,
      );
      return announcement?.picture;
    }
    return null;
  }

  String _getInitials(String? name) {
    if (name == null || name.isEmpty) return '?';
    final words = name.trim().split(RegExp(r'\s+'));
    if (words.isEmpty) return '?';
    if (words.length == 1) {
      return words[0].substring(0, words[0].length.clamp(0, 2)).toUpperCase();
    }
    return '${words[0][0]}${words[1][0]}'.toUpperCase();
  }

  Future<void> _acceptInvitation(PendingInvitation invitation) async {
    if (_processingInvitations[invitation.id] == true) return;

    setState(() {
      _processingInvitations[invitation.id] = true;
    });

    try {
      final groupState = context.read<GroupState>();
      await groupState.acceptInvitation(invitation);

      if (mounted) {
        // Show success message
        showCupertinoDialog(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('Invitation Accepted'),
            content: const Text('You have joined the group.'),
            actions: [
              CupertinoDialogAction(
                child: const Text('OK'),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        showCupertinoDialog(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('Error'),
            content: Text('Failed to accept invitation: $e'),
            actions: [
              CupertinoDialogAction(
                child: const Text('OK'),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _processingInvitations[invitation.id] = false;
        });
      }
    }
  }

  Future<void> _rejectInvitation(PendingInvitation invitation) async {
    if (_processingInvitations[invitation.id] == true) return;

    setState(() {
      _processingInvitations[invitation.id] = true;
    });

    try {
      final groupState = context.read<GroupState>();
      await groupState.rejectInvitation(invitation);
    } catch (e) {
      if (mounted) {
        showCupertinoDialog(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('Error'),
            content: Text('Failed to reject invitation: $e'),
            actions: [
              CupertinoDialogAction(
                child: const Text('OK'),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _processingInvitations[invitation.id] = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppColors.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 0,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Close'),
                  ),
                  const Text(
                    'Group Invitations',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 60), // Balance the close button
                ],
              ),
            ),
            Container(height: 0.5, color: AppColors.separator),
            Expanded(
              child: Consumer<GroupState>(
                builder: (context, groupState, child) {
                  final invitations = groupState.pendingInvitations;

                  if (invitations.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            CupertinoIcons.mail,
                            size: 48,
                            color: AppColors.secondaryLabel,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'No pending invitations',
                            style: TextStyle(
                              fontSize: 16,
                              color: AppColors.secondaryLabel,
                            ),
                          ),
                        ],
                      ),
                    );
                  }

                  return ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: invitations.length,
                    itemBuilder: (context, index) {
                      final invitation = invitations[index];
                      final isProcessing =
                          _processingInvitations[invitation.id] == true;
                      final groupName =
                          _getGroupName(invitation, groupState);
                      final groupPicture =
                          _getGroupPicture(invitation, groupState);

                      return Container(
                        margin: const EdgeInsets.only(bottom: 12),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceElevated,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppColors.separator,
                            width: 0.5,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                // Group avatar
                                Container(
                                  width: 48,
                                  height: 48,
                                  decoration: BoxDecoration(
                                    color: AppColors.primary,
                                    borderRadius: BorderRadius.circular(24),
                                    image: groupPicture != null
                                        ? DecorationImage(
                                            image: NetworkImage(groupPicture),
                                            fit: BoxFit.cover,
                                          )
                                        : null,
                                  ),
                                  child: groupPicture == null
                                      ? Center(
                                          child: Text(
                                            _getInitials(groupName),
                                            style: const TextStyle(
                                              color: CupertinoColors.white,
                                              fontWeight: FontWeight.w600,
                                              fontSize: 18,
                                            ),
                                          ),
                                        )
                                      : null,
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        groupName,
                                        style: const TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                      FutureBuilder(
                                        future: invitation.inviterPubkey != null
                                            ? context
                                                .read<ProfileState>()
                                                .getProfile(
                                                  invitation.inviterPubkey!,
                                                )
                                            : Future.value(null),
                                        builder: (context, snapshot) {
                                          final profile = snapshot.data;
                                          final inviterName = profile != null
                                              ? profile.getUsername()
                                              : invitation.inviterPubkey != null
                                                  ? invitation.inviterPubkey!
                                                      .substring(0, 8)
                                                  : 'Unknown';
                                          return Text(
                                            'Invited by $inviterName',
                                            style: TextStyle(
                                              fontSize: 13,
                                              color: AppColors.secondaryLabel,
                                            ),
                                          );
                                        },
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        _getTimeAgo(invitation.receivedAt),
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: AppColors.tertiaryLabel,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Expanded(
                                  child: CupertinoButton(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                    ),
                                    color: AppColors.primary,
                                    onPressed: isProcessing
                                        ? null
                                        : () => _acceptInvitation(invitation),
                                    child: isProcessing
                                        ? const CupertinoActivityIndicator(
                                            color: CupertinoColors.white,
                                          )
                                        : const Text(
                                            'Accept',
                                            style: TextStyle(
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: CupertinoButton(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                    ),
                                    color: AppColors.surface,
                                    onPressed: isProcessing
                                        ? null
                                        : () => _rejectInvitation(invitation),
                                    child: Text(
                                      'Reject',
                                      style: TextStyle(
                                        color: AppColors.label,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
