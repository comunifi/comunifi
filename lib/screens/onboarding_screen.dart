import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/group.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final TextEditingController _groupNameController = TextEditingController();
  final TextEditingController _groupAboutController = TextEditingController();
  bool _isCreatingGroup = false;
  String? _createGroupError;

  @override
  void dispose() {
    _groupNameController.dispose();
    _groupAboutController.dispose();
    super.dispose();
  }

  void handleLogin() {
    final navigate = GoRouter.of(context);
    navigate.push('/feed');
  }

  void handleMls() {
    final navigate = GoRouter.of(context);
    navigate.push('/mls');
  }

  void handleMlsPersistent() {
    final navigate = GoRouter.of(context);
    navigate.push('/mls-persistent');
  }

  Future<void> _createGroup() async {
    final groupName = _groupNameController.text.trim();
    if (groupName.isEmpty) {
      setState(() {
        _createGroupError = 'Group name cannot be empty';
      });
      return;
    }

    final groupState = context.read<GroupState>();
    if (!groupState.isConnected) {
      setState(() {
        _createGroupError = 'Not connected to relay';
      });
      return;
    }

    setState(() {
      _isCreatingGroup = true;
      _createGroupError = null;
    });

    try {
      final about = _groupAboutController.text.trim();
      await groupState.createGroup(
        groupName,
        about: about.isEmpty ? null : about,
      );
      _groupNameController.clear();
      _groupAboutController.clear();
      setState(() {
        _isCreatingGroup = false;
      });
    } catch (e) {
      setState(() {
        _isCreatingGroup = false;
        _createGroupError = e.toString();
      });
    }
  }

  void _toggleGroup(NostrGroup group) {
    final groupState = context.read<GroupState>();
    if (groupState.activeGroup?.id == group.id) {
      // Deselect if already active
      groupState.setActiveGroup(null);
    } else {
      // Select this group and navigate to feed
      groupState.setActiveGroup(group);
      final navigate = GoRouter.of(context);
      navigate.push('/feed');
    }
  }

  String _truncateId(String id) {
    if (id.length <= 12) return id;
    return '${id.substring(0, 6)}...${id.substring(id.length - 6)}';
  }

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

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(middle: Text('Onboarding')),
      child: SafeArea(
        child: Consumer<GroupState>(
          builder: (context, groupState, child) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Navigation buttons
                Container(
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemGrey6,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Navigation',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      CupertinoButton.filled(
                        onPressed: handleLogin,
                        child: const Text('Feed'),
                      ),
                      const SizedBox(height: 8),
                      CupertinoButton.filled(
                        onPressed: handleMls,
                        child: const Text('MLS'),
                      ),
                      const SizedBox(height: 8),
                      CupertinoButton.filled(
                        onPressed: handleMlsPersistent,
                        child: const Text('MLS Persistent'),
                      ),
                    ],
                  ),
                ),

                // Connection status
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: groupState.isConnected
                        ? CupertinoColors.systemGreen.withOpacity(0.1)
                        : CupertinoColors.systemRed.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: groupState.isConnected
                          ? CupertinoColors.systemGreen
                          : CupertinoColors.systemRed,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        groupState.isConnected
                            ? CupertinoIcons.check_mark_circled
                            : CupertinoIcons.xmark_circle,
                        color: groupState.isConnected
                            ? CupertinoColors.systemGreen
                            : CupertinoColors.systemRed,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          groupState.isConnected
                              ? 'Connected to relay'
                              : groupState.errorMessage ?? 'Not connected',
                          style: TextStyle(
                            color: groupState.isConnected
                                ? CupertinoColors.systemGreen
                                : CupertinoColors.systemRed,
                          ),
                        ),
                      ),
                      if (!groupState.isConnected)
                        CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: groupState.retryConnection,
                          child: const Text('Retry'),
                        ),
                    ],
                  ),
                ),

                // Group creation section
                Container(
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemGrey6,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Create Group',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (_createGroupError != null)
                        Container(
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: CupertinoColors.systemRed.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: CupertinoColors.systemRed,
                            ),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                CupertinoIcons.exclamationmark_triangle,
                                color: CupertinoColors.systemRed,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _createGroupError!,
                                  style: const TextStyle(
                                    color: CupertinoColors.systemRed,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              CupertinoButton(
                                padding: EdgeInsets.zero,
                                minSize: 0,
                                onPressed: () {
                                  setState(() {
                                    _createGroupError = null;
                                  });
                                },
                                child: const Icon(
                                  CupertinoIcons.xmark_circle_fill,
                                  color: CupertinoColors.systemRed,
                                  size: 20,
                                ),
                              ),
                            ],
                          ),
                        ),
                      CupertinoTextField(
                        controller: _groupNameController,
                        placeholder: 'Group Name',
                        padding: const EdgeInsets.all(12),
                      ),
                      const SizedBox(height: 8),
                      CupertinoTextField(
                        controller: _groupAboutController,
                        placeholder: 'About (optional)',
                        padding: const EdgeInsets.all(12),
                        maxLines: 2,
                      ),
                      const SizedBox(height: 12),
                      CupertinoButton.filled(
                        onPressed: _isCreatingGroup ? null : _createGroup,
                        child: _isCreatingGroup
                            ? const CupertinoActivityIndicator(
                                color: CupertinoColors.white,
                              )
                            : const Text('Create Group'),
                      ),
                    ],
                  ),
                ),

                // Groups list section
                Container(
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemGrey6,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          const Text(
                            'Groups',
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          if (groupState.isLoading)
                            const CupertinoActivityIndicator(),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (groupState.groups.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(16),
                          child: Text(
                            'No groups yet. Create one above!',
                            style: TextStyle(
                              color: CupertinoColors.secondaryLabel,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        )
                      else
                        ...groupState.groups.map((group) {
                          final isActive =
                              groupState.activeGroup?.id == group.id;
                          return Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: isActive
                                  ? CupertinoColors.systemBlue.withOpacity(0.1)
                                  : CupertinoColors.systemGrey5,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: isActive
                                    ? CupertinoColors.systemBlue
                                    : CupertinoColors.systemGrey4,
                                width: isActive ? 2 : 1,
                              ),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            group.name,
                                            style: TextStyle(
                                              fontWeight: FontWeight.bold,
                                              fontSize: 16,
                                              color: isActive
                                                  ? CupertinoColors.systemBlue
                                                  : null,
                                            ),
                                          ),
                                          if (group.about != null)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 4,
                                              ),
                                              child: Text(
                                                group.about!,
                                                style: const TextStyle(
                                                  fontSize: 12,
                                                  color: CupertinoColors
                                                      .secondaryLabel,
                                                ),
                                              ),
                                            ),
                                          const SizedBox(height: 4),
                                          Text(
                                            'ID: ${_truncateId(group.id)} • ${_formatDate(group.createdAt)}',
                                            style: const TextStyle(
                                              fontSize: 11,
                                              color: CupertinoColors
                                                  .secondaryLabel,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (isActive)
                                      const Icon(
                                        CupertinoIcons.check_mark_circled_solid,
                                        color: CupertinoColors.systemBlue,
                                      ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                CupertinoButton(
                                  padding: EdgeInsets.zero,
                                  minSize: 0,
                                  onPressed: () => _toggleGroup(group),
                                  child: Text(
                                    isActive ? 'Deselect' : 'Select',
                                    style: TextStyle(
                                      color: isActive
                                          ? CupertinoColors.systemBlue
                                          : CupertinoColors.systemBlue,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          );
                        }),
                    ],
                  ),
                ),

                // Active group info
                if (groupState.activeGroup != null)
                  Container(
                    padding: const EdgeInsets.all(16),
                    margin: const EdgeInsets.only(bottom: 16),
                    decoration: BoxDecoration(
                      color: CupertinoColors.systemBlue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: CupertinoColors.systemBlue),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Active Group',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: CupertinoColors.systemBlue,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          groupState.activeGroup!.name,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (groupState.activeGroup!.about != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              groupState.activeGroup!.about!,
                              style: const TextStyle(
                                fontSize: 14,
                                color: CupertinoColors.secondaryLabel,
                              ),
                            ),
                          ),
                        const SizedBox(height: 8),
                        Text(
                          'Messages: ${groupState.groupMessages.length}',
                          style: const TextStyle(
                            fontSize: 12,
                            color: CupertinoColors.secondaryLabel,
                          ),
                        ),
                      ],
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
