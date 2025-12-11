import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:comunifi/services/recovery/nip44_crypto.dart';
import 'package:comunifi/services/recovery/recovery_service.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/profile.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// Screen for receiving recovery data on a new device
///
/// Displays:
/// - QR code with temporary pubkey for device-to-device transfer
/// - Text field for entering recovery link
/// - Instructions for both methods
class ReceiveRecoveryScreen extends StatefulWidget {
  const ReceiveRecoveryScreen({super.key});

  @override
  State<ReceiveRecoveryScreen> createState() => _ReceiveRecoveryScreenState();
}

class _ReceiveRecoveryScreenState extends State<ReceiveRecoveryScreen> {
  final TextEditingController _linkController = TextEditingController();

  bool _isInitializing = true;
  bool _isWaitingForTransfer = false;
  bool _isRestoring = false;
  String? _error;

  // Temporary keypair for receiving encrypted transfer
  Nip44KeyPair? _tempKeyPair;
  String? _qrData;

  // Subscription for listening to transfer events
  StreamSubscription? _eventSubscription;

  @override
  void initState() {
    super.initState();
    _initializeQrCode();
  }

  @override
  void dispose() {
    _linkController.dispose();
    _eventSubscription?.cancel();
    super.dispose();
  }

  Future<void> _initializeQrCode() async {
    try {
      // Generate ephemeral keypair for this transfer
      _tempKeyPair = await Nip44Crypto.generateKeyPair();

      // Get relay URL from group state
      final groupState = context.read<GroupState>();
      final relayUrl = groupState.relayUrl ?? 'wss://relay.comunifi.io';

      // Create QR data
      final qrData = DeviceTransferQrData(
        tempPubkey: _tempKeyPair!.publicKeyHex,
        relayUrl: relayUrl,
      );
      _qrData = qrData.toJson();

      setState(() {
        _isInitializing = false;
      });

      // Start listening for transfer
      _startListeningForTransfer();
    } catch (e) {
      setState(() {
        _isInitializing = false;
        _error = 'Failed to initialize: $e';
      });
    }
  }

  void _startListeningForTransfer() {
    if (_tempKeyPair == null) return;

    setState(() {
      _isWaitingForTransfer = true;
    });

    final groupState = context.read<GroupState>();

    // Listen for gift-wrapped events to our temp pubkey
    _eventSubscription = groupState.listenForGiftWrappedEvents(
      recipientPubkey: _tempKeyPair!.publicKeyHex,
      onEvent: _handleTransferEvent,
    );
  }

  Future<void> _handleTransferEvent(Map<String, dynamic> event) async {
    try {
      // Get Nostr pubkey of sender (for confirmation)
      final nostrPubkey = event['pubkey'] as String;

      // Get ephemeral sender pubkey from tags (used for NIP-44 decryption)
      final tags = event['tags'] as List<dynamic>?;
      String? ephemeralPubkey;
      if (tags != null) {
        for (final tag in tags) {
          if (tag is List && tag.length >= 2 && tag[0] == 'sender_pubkey') {
            ephemeralPubkey = tag[1] as String;
            break;
          }
        }
      }

      if (ephemeralPubkey == null) {
        throw Exception('Missing sender pubkey in event');
      }

      // Decrypt the content using NIP-44 with the ephemeral sender pubkey
      final encryptedContent = event['content'] as String;
      final decrypted = await Nip44Crypto.decrypt(
        payload: encryptedContent,
        recipientPrivateKey: _tempKeyPair!.privateKey,
        senderPublicKey: _hexToBytes(ephemeralPubkey),
      );

      // Parse the recovery payload
      final payloadJson = utf8.decode(decrypted);
      final payloadData = jsonDecode(payloadJson) as Map<String, dynamic>;

      // Create recovery payload from the data
      final payload = RecoveryPayload(
        groupId: payloadData['groupId'] as String,
        groupName: payloadData['groupName'] as String,
        publicState: base64Decode(payloadData['publicState'] as String),
        identityPrivateKey: base64Decode(
          payloadData['identityPrivateKey'] as String,
        ),
        hpkePrivateKey: base64Decode(payloadData['hpkePrivateKey'] as String),
        epochSecrets: base64Decode(payloadData['epochSecrets'] as String),
      );

      await _restoreFromPayload(payload);

      // Send confirmation back to sender's Nostr pubkey
      await _sendConfirmation(nostrPubkey);
    } catch (e) {
      setState(() {
        _error = 'Failed to process transfer: $e';
        _isWaitingForTransfer = false;
      });
    }
  }

  Future<void> _sendConfirmation(String senderPubkey) async {
    // TODO: Send confirmation event back to sender
    // This would be a gift-wrapped event to the sender's pubkey
    // indicating successful recovery
  }

  Future<void> _restoreFromLink() async {
    final link = _linkController.text.trim();
    if (link.isEmpty) {
      setState(() => _error = 'Please enter a recovery link');
      return;
    }

    final payload = RecoveryPayload.fromRecoveryLink(link);
    if (payload == null) {
      setState(() => _error = 'Invalid recovery link');
      return;
    }

    await _restoreFromPayload(payload);
  }

  Future<void> _restoreFromPayload(RecoveryPayload payload) async {
    setState(() {
      _isRestoring = true;
      _error = null;
    });

    try {
      final groupState = context.read<GroupState>();
      final profileState = context.read<ProfileState>();

      // Restore the personal group
      final success = await groupState.restoreFromRecoveryPayload(payload);
      if (!success) {
        throw Exception('Failed to restore personal group');
      }

      // Wait for connection and identity recovery
      await groupState.waitForConnection();

      // Load profile from relay
      final pubkey = await groupState.getNostrPublicKey();
      if (pubkey != null) {
        await profileState.ensureUserProfile(pubkey: pubkey);
      }

      // Navigate to confirmation screen
      if (mounted) {
        context.go('/recovery/confirm');
      }
    } catch (e) {
      setState(() {
        _isRestoring = false;
        _error = 'Restoration failed: $e';
      });
    }
  }

  Uint8List _hexToBytes(String hex) {
    final result = Uint8List(hex.length ~/ 2);
    for (var i = 0; i < result.length; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => context.go('/'),
          child: const Icon(CupertinoIcons.back),
        ),
        middle: const Text('Recover Account'),
      ),
      child: SafeArea(
        child: _isInitializing
            ? const Center(child: CupertinoActivityIndicator())
            : _isRestoring
            ? Center(child: _buildRestoringView())
            : _buildMainView(),
      ),
    );
  }

  Widget _buildRestoringView() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        const CupertinoActivityIndicator(radius: 20),
        const SizedBox(height: 20),
        const Text(
          'Restoring your account...',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        Text(
          'This may take a moment',
          style: TextStyle(
            fontSize: 14,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
      ],
    );
  }

  Widget _buildMainView() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 500),
            child: Column(
              children: [
        // Error message
        if (_error != null) ...[
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: CupertinoColors.systemRed.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
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
                    _error!,
                    style: const TextStyle(
                      color: CupertinoColors.systemRed,
                      fontSize: 14,
                    ),
                  ),
                ),
                CupertinoButton(
                  padding: EdgeInsets.zero,
                  minSize: 0,
                  onPressed: () => setState(() => _error = null),
                  child: const Icon(
                    CupertinoIcons.xmark_circle_fill,
                    color: CupertinoColors.systemRed,
                    size: 20,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],

        // Option 1: QR Code for device-to-device transfer
        _buildSection(
          title: 'Transfer from another device',
          description:
              'On your other device, go to Settings > Backup & Recovery > Add New Device and scan this code.',
          child: Column(
            children: [
              if (_qrData != null)
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: CupertinoColors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: CupertinoColors.systemGrey4),
                  ),
                  child: QrImageView(
                    data: _qrData!,
                    version: QrVersions.auto,
                    size: 200,
                    backgroundColor: CupertinoColors.white,
                  ),
                ),
              const SizedBox(height: 12),
              if (_isWaitingForTransfer)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const CupertinoActivityIndicator(radius: 10),
                    const SizedBox(width: 8),
                    Text(
                      'Waiting for transfer...',
                      style: TextStyle(
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
            ],
          ),
        ),

        const SizedBox(height: 32),

        // Divider with "or"
        Row(
          children: [
            Expanded(
              child: Container(
                height: 1,
                color: CupertinoColors.separator.resolveFrom(context),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                'or',
                style: TextStyle(
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  fontSize: 14,
                ),
              ),
            ),
            Expanded(
              child: Container(
                height: 1,
                color: CupertinoColors.separator.resolveFrom(context),
              ),
            ),
          ],
        ),

        const SizedBox(height: 32),

        // Option 2: Enter recovery link
        _buildSection(
          title: 'Enter recovery link',
          description:
              'Paste the recovery link you saved when setting up your account.',
          child: Column(
            children: [
              CupertinoTextField(
                controller: _linkController,
                placeholder: 'comunifi://restore?backup=...',
                padding: const EdgeInsets.all(12),
                maxLines: 3,
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: CupertinoButton(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      color: CupertinoColors.activeBlue,
                      borderRadius: BorderRadius.circular(8),
                      onPressed: _restoreFromLink,
                      child: const Text(
                        'Restore',
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: CupertinoColors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null) {
                        _linkController.text = data!.text!;
                      }
                    },
                    child: const Icon(CupertinoIcons.doc_on_clipboard),
                  ),
                ],
              ),
            ],
          ),
        ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSection({
    required String title,
    required String description,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        Text(
          description,
          style: TextStyle(
            fontSize: 14,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
        const SizedBox(height: 16),
        Center(child: child),
      ],
    );
  }
}
