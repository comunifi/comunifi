import 'dart:typed_data';
import 'package:comunifi/state/mls.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

class MlsScreen extends StatefulWidget {
  const MlsScreen({super.key});

  @override
  State<MlsScreen> createState() => _MlsScreenState();
}

class _MlsScreenState extends State<MlsScreen> {
  late MlsState mlsState;
  final TextEditingController _groupNameController = TextEditingController();
  final TextEditingController _userIdController = TextEditingController();
  final TextEditingController _messageController = TextEditingController();

  @override
  void initState() {
    super.initState();
    mlsState = context.read<MlsState>();
    _userIdController.text = 'user1'; // Default user ID
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

  @override
  Widget build(BuildContext context) {
    final mlsState = context.watch<MlsState>();
    final currentGroup = mlsState.currentGroup;
    final messages = mlsState.messages;
    final errorMessage = mlsState.errorMessage;

    return CupertinoPageScaffold(
      navigationBar: const CupertinoNavigationBar(
        middle: Text('MLS Debug Screen'),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // Error display
            if (errorMessage != null)
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

            // Group creation section
            Container(
              padding: const EdgeInsets.all(16),
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
            if (currentGroup != null)
              Container(
                padding: const EdgeInsets.all(16),
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
                  ],
                ),
              ),

            const SizedBox(height: 16),

            // Message sending section
            if (currentGroup != null)
              Container(
                padding: const EdgeInsets.all(16),
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
            if (messages.isNotEmpty)
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
            if (currentGroup == null && messages.isEmpty)
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
