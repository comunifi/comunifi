import 'dart:typed_data';
import 'package:comunifi/state/mls_persistent.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

class MlsPersistentScreen extends StatefulWidget {
  const MlsPersistentScreen({super.key});

  @override
  State<MlsPersistentScreen> createState() => _MlsPersistentScreenState();
}

class _MlsPersistentScreenState extends State<MlsPersistentScreen> {
  late MlsPersistentState mlsState;
  final TextEditingController _groupNameController = TextEditingController();
  final TextEditingController _userIdController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();

  @override
  void initState() {
    super.initState();
    mlsState = context.read<MlsPersistentState>();
    _userIdController.text = 'user1'; // Default user ID
    // Load saved groups on init
    WidgetsBinding.instance.addPostFrameCallback((_) {
      mlsState.refreshSavedGroups();
    });
  }

  @override
  void dispose() {
    _groupNameController.dispose();
    _userIdController.dispose();
    _messageController.dispose();
    super.dispose();
  }

  void _createGroup() async {
    final groupName = _groupNameController.text.trim();
    final userId = _userIdController.text.trim();
    if (groupName.isEmpty || userId.isEmpty) {
      return;
    }
    await mlsState.createGroup(groupName, userId);
    _groupNameController.clear();
  }

  void _sendMessage() async {
    final message = _messageController.text.trim();
    if (message.isEmpty) {
      return;
    }
    await mlsState.sendMessage(message);
    _messageController.clear();
  }

  String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  }

  String _groupIdToShortString(Uint8List bytes) {
    if (bytes.isEmpty) return 'N/A';
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join('');
    return '${hex.substring(0, 8)}...${hex.substring(hex.length - 8)}';
  }

  @override
  Widget build(BuildContext context) {
    final mlsState = context.watch<MlsPersistentState>();
    final currentGroup = mlsState.currentGroup;
    final messages = mlsState.messages;
    final errorMessage = mlsState.errorMessage;
    final savedGroups = mlsState.savedGroups;
    final loadingGroups = mlsState.loadingGroups;

    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(
        middle: Text('MLS Persistent Debug'),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Initialization status
            if (!mlsState.initialized)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: mlsState.initializationError != null
                      ? CupertinoColors.systemRed.withOpacity(0.1)
                      : CupertinoColors.systemOrange.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: mlsState.initializationError != null
                        ? CupertinoColors.systemRed
                        : CupertinoColors.systemOrange,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      mlsState.initializationError != null
                          ? CupertinoIcons.exclamationmark_triangle
                          : CupertinoIcons.hourglass,
                      color: mlsState.initializationError != null
                          ? CupertinoColors.systemRed
                          : CupertinoColors.systemOrange,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        mlsState.initializationError ?? 'Initializing storage...',
                        style: TextStyle(
                          color: mlsState.initializationError != null
                              ? CupertinoColors.systemRed
                              : CupertinoColors.systemOrange,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Error display
            if (errorMessage != null && mlsState.initialized)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: CupertinoColors.systemRed.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: CupertinoColors.systemRed),
                ),
                child: Row(
                  children: [
                    const Icon(
                      CupertinoIcons.exclamationmark_triangle,
                      color: CupertinoColors.systemRed,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        errorMessage,
                        style: const TextStyle(
                          color: CupertinoColors.systemRed,
                        ),
                      ),
                    ),
                  ],
                ),
              ),

            // Storage info
            if (mlsState.initialized)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: CupertinoColors.systemGreen.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: CupertinoColors.systemGreen),
                ),
                child: Row(
                  children: [
                    const Icon(
                      CupertinoIcons.check_mark_circled,
                      color: CupertinoColors.systemGreen,
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Secure Persistent Storage Active',
                        style: TextStyle(
                          color: CupertinoColors.systemGreen,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    CupertinoButton(
                      padding: EdgeInsets.zero,
                      onPressed: () => mlsState.refreshSavedGroups(),
                      child: const Text('Refresh'),
                    ),
                  ],
                ),
              ),

            // Saved groups section
            if (mlsState.initialized)
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
                          'Saved Groups',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (loadingGroups)
                          const CupertinoActivityIndicator(),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (savedGroups.isEmpty)
                      const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          'No saved groups',
                          style: TextStyle(
                            color: CupertinoColors.systemGrey,
                          ),
                        ),
                      )
                    else
                      ...savedGroups.map((groupId) {
                        final isCurrentGroup = currentGroup != null &&
                            currentGroup.id.bytes.toString() ==
                                groupId.bytes.toString();
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: isCurrentGroup
                                ? CupertinoColors.systemBlue.withOpacity(0.1)
                                : CupertinoColors.systemGrey5,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: isCurrentGroup
                                  ? CupertinoColors.systemBlue
                                  : CupertinoColors.systemGrey4,
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      _groupIdToShortString(groupId.bytes),
                                      style: TextStyle(
                                        fontWeight: isCurrentGroup
                                            ? FontWeight.bold
                                            : FontWeight.normal,
                                      ),
                                    ),
                                    if (isCurrentGroup)
                                      const Text(
                                        '(Currently Loaded)',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: CupertinoColors.systemBlue,
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              if (!isCurrentGroup)
                                CupertinoButton(
                                  padding: EdgeInsets.zero,
                                  onPressed: () => mlsState.loadGroup(groupId),
                                  child: const Text('Load'),
                                ),
                              CupertinoButton(
                                padding: EdgeInsets.zero,
                                onPressed: () => mlsState.deleteGroup(groupId),
                                child: const Text(
                                  'Delete',
                                  style: TextStyle(
                                    color: CupertinoColors.systemRed,
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

            // Group creation section
            if (mlsState.initialized)
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
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    CupertinoTextField(
                      controller: _groupNameController,
                      placeholder: 'Group Name',
                      padding: const EdgeInsets.all(12),
                    ),
                    const SizedBox(height: 8),
                    CupertinoTextField(
                      controller: _userIdController,
                      placeholder: 'User ID',
                      padding: const EdgeInsets.all(12),
                    ),
                    const SizedBox(height: 12),
                    CupertinoButton.filled(
                      onPressed: _createGroup,
                      child: const Text('Create Group'),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 16),

            // Group info section
            if (currentGroup != null && mlsState.initialized)
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
                          'Group Info',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        CupertinoButton(
                          padding: EdgeInsets.zero,
                          onPressed: () => mlsState.clearGroup(),
                          child: const Text(
                            'Clear',
                            style: TextStyle(color: CupertinoColors.systemRed),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text('Name: ${currentGroup.name}'),
                    Text('Epoch: ${currentGroup.epoch}'),
                    Text('Members: ${currentGroup.memberCount}'),
                    Text(
                      'Group ID: ${_bytesToHex(currentGroup.id.bytes).substring(0, 40)}...',
                      style: const TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: CupertinoColors.systemGrey5,
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        '💾 This group is persisted to secure storage',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 16),

            // Message sending section
            if (currentGroup != null && mlsState.initialized)
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
                          'Send Message',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (messages.isNotEmpty)
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            onPressed: () => mlsState.clearMessages(),
                            child: const Text(
                              'Clear',
                              style: TextStyle(
                                color: CupertinoColors.systemRed,
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    CupertinoTextField(
                      controller: _messageController,
                      placeholder: 'Enter message...',
                      padding: const EdgeInsets.all(12),
                      maxLines: 3,
                    ),
                    const SizedBox(height: 12),
                    CupertinoButton.filled(
                      onPressed: _sendMessage,
                      child: const Text('Send Message'),
                    ),
                  ],
                ),
              ),

            const SizedBox(height: 16),

            // Messages display
            if (messages.isNotEmpty && mlsState.initialized)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Messages (Encrypted)',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  ...messages.asMap().entries.map((entry) {
                    final index = entry.key;
                    final message = entry.value;
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: CupertinoColors.systemGrey6,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: CupertinoColors.systemGrey4),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                'Message #${index + 1}',
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              Text(
                                'Epoch: ${message.epoch}',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          _buildMessageSection(
                            'Plaintext',
                            message.plaintext,
                            CupertinoColors.systemBlue,
                          ),
                          const SizedBox(height: 8),
                          _buildMessageSection(
                            'Ciphertext (Encrypted)',
                            _bytesToHex(message.ciphertext.ciphertext),
                            CupertinoColors.systemRed,
                          ),
                          const SizedBox(height: 8),
                          _buildMessageSection(
                            'Decrypted (Verified)',
                            message.decrypted,
                            CupertinoColors.systemGreen,
                          ),
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: CupertinoColors.systemGrey5,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'Metadata',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  'Nonce: ${_bytesToHex(message.ciphertext.nonce)}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                Text(
                                  'Sender Index: ${message.ciphertext.senderIndex}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                Text(
                                  'Content Type: ${message.ciphertext.contentType.name}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),

            // Empty state
            if (currentGroup == null &&
                messages.isEmpty &&
                mlsState.initialized)
              Container(
                padding: const EdgeInsets.all(32),
                child: const Column(
                  children: [
                    Icon(
                      CupertinoIcons.lock_shield,
                      size: 64,
                      color: CupertinoColors.systemGrey,
                    ),
                    SizedBox(height: 16),
                    Text(
                      'Create a group to start',
                      style: TextStyle(
                        fontSize: 18,
                        color: CupertinoColors.systemGrey,
                      ),
                    ),
                    SizedBox(height: 8),
                    Text(
                      'Groups are persisted to secure storage',
                      style: TextStyle(
                        fontSize: 14,
                        color: CupertinoColors.systemGrey2,
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

  Widget _buildMessageSection(String title, String content, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
          const SizedBox(height: 6),
          Text(content, style: const TextStyle(fontSize: 13)),
        ],
      ),
    );
  }
}

