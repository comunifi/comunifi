import 'dart:convert';
import 'dart:typed_data';

import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/services/recovery/nip44_crypto.dart';
import 'package:comunifi/services/recovery/recovery_service.dart';
import 'package:comunifi/state/group.dart';
import 'package:dart_nostr/dart_nostr.dart';
import 'package:flutter/cupertino.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

/// Screen for sending recovery data to another device
///
/// Uses camera to scan QR code from receiving device, then encrypts
/// and sends the personal MLS group via relay.
class SendRecoveryScreen extends StatefulWidget {
  const SendRecoveryScreen({super.key});

  @override
  State<SendRecoveryScreen> createState() => _SendRecoveryScreenState();
}

class _SendRecoveryScreenState extends State<SendRecoveryScreen> {
  final MobileScannerController _scannerController = MobileScannerController();

  bool _isScanning = true;
  bool _isSending = false;
  bool _isSent = false;
  bool _isWaitingForConfirmation = false;
  String? _error;

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  Future<void> _handleBarcode(BarcodeCapture capture) async {
    if (!_isScanning) return;

    final barcode = capture.barcodes.firstOrNull;
    if (barcode?.rawValue == null) return;

    setState(() {
      _isScanning = false;
    });

    try {
      // Parse QR code data
      final qrData = DeviceTransferQrData.fromJson(barcode!.rawValue!);
      await _sendRecoveryData(qrData);
    } catch (e) {
      setState(() {
        _error = 'Invalid QR code: $e';
        _isScanning = true;
      });
    }
  }

  Future<void> _sendRecoveryData(DeviceTransferQrData qrData) async {
    setState(() {
      _isSending = true;
      _error = null;
    });

    try {
      final groupState = context.read<GroupState>();

      // Generate recovery payload for personal group
      final payload = await groupState.generateRecoveryPayload();
      if (payload == null) {
        throw Exception('Failed to generate recovery payload');
      }

      // Create the payload JSON
      final payloadJson = jsonEncode({
        'groupId': payload.groupId,
        'groupName': payload.groupName,
        'publicState': base64Encode(payload.publicState),
        'identityPrivateKey': base64Encode(payload.identityPrivateKey),
        'hpkePrivateKey': base64Encode(payload.hpkePrivateKey),
        'epochSecrets': base64Encode(payload.epochSecrets),
      });

      // Generate ephemeral keypair for sending
      final senderKeyPair = await Nip44Crypto.generateKeyPair();

      // Encrypt with NIP-44
      final encrypted = await Nip44Crypto.encrypt(
        plaintext: Uint8List.fromList(utf8.encode(payloadJson)),
        senderPrivateKey: senderKeyPair.privateKey,
        recipientPublicKey: _hexToBytes(qrData.tempPubkey),
      );

      // Create gift-wrapped event (kind 1059)
      // Include the ephemeral sender pubkey so receiver can decrypt
      final privateKey = await groupState.getNostrPrivateKey();
      if (privateKey == null) {
        throw Exception('No private key available');
      }

      final keyPairs = NostrKeyPairs(private: privateKey);
      final createdAt = DateTime.now();

      final event = NostrEvent.fromPartialData(
        kind: kindEncryptedEnvelope,
        content: encrypted,
        keyPairs: keyPairs,
        tags: [
          ['p', qrData.tempPubkey],
          // Include ephemeral sender pubkey for decryption
          ['sender_pubkey', senderKeyPair.publicKeyHex],
        ],
        createdAt: createdAt,
      );

      final eventModel = NostrEventModel(
        id: event.id,
        pubkey: event.pubkey,
        kind: event.kind,
        content: event.content,
        tags: event.tags,
        sig: event.sig,
        createdAt: event.createdAt,
      );

      // Publish to relay
      await groupState.publishEvent(eventModel);

      setState(() {
        _isSending = false;
        _isSent = true;
        _isWaitingForConfirmation = true;
      });

      // TODO: Listen for confirmation event from receiver
      // For now, just show success after a delay
      await Future.delayed(const Duration(seconds: 2));

      setState(() {
        _isWaitingForConfirmation = false;
      });
    } catch (e) {
      setState(() {
        _isSending = false;
        _error = 'Failed to send: $e';
        _isScanning = true;
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
          onPressed: () => Navigator.of(context).pop(),
          child: const Icon(CupertinoIcons.back),
        ),
        middle: const Text('Add New Device'),
      ),
      child: SafeArea(
        child: _isSent ? _buildSuccessView() : _buildScannerView(),
      ),
    );
  }

  Widget _buildScannerView() {
    return Column(
      children: [
        // Instructions
        Container(
          padding: const EdgeInsets.all(20),
          child: Column(
            children: [
              const Text(
                'Scan the QR code on your new device',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'On your new device, tap "I have an existing account" to display the QR code.',
                style: TextStyle(
                  fontSize: 14,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),

        // Error message
        if (_error != null)
          Container(
            margin: const EdgeInsets.symmetric(horizontal: 20),
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
              ],
            ),
          ),

        // Camera view
        Expanded(
          child: Container(
            margin: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: CupertinoColors.systemGrey4, width: 2),
            ),
            clipBehavior: Clip.antiAlias,
            child: _isSending
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const CupertinoActivityIndicator(radius: 20),
                        const SizedBox(height: 20),
                        const Text(
                          'Sending recovery data...',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Please wait',
                          style: TextStyle(
                            fontSize: 14,
                            color: CupertinoColors.secondaryLabel.resolveFrom(
                              context,
                            ),
                          ),
                        ),
                      ],
                    ),
                  )
                : MobileScanner(
                    controller: _scannerController,
                    onDetect: _handleBarcode,
                  ),
          ),
        ),

        // Tip
        Padding(
          padding: const EdgeInsets.all(20),
          child: Row(
            children: [
              Icon(
                CupertinoIcons.lightbulb,
                size: 20,
                color: CupertinoColors.systemYellow.resolveFrom(context),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Make sure both devices are connected to the internet.',
                  style: TextStyle(
                    fontSize: 13,
                    color: CupertinoColors.secondaryLabel.resolveFrom(context),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSuccessView() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  color: CupertinoColors.systemGreen.withOpacity(0.15),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _isWaitingForConfirmation
                      ? CupertinoIcons.clock
                      : CupertinoIcons.checkmark_alt,
                  size: 40,
                  color: _isWaitingForConfirmation
                      ? CupertinoColors.systemOrange
                      : CupertinoColors.systemGreen,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                _isWaitingForConfirmation
                    ? 'Recovery data sent!'
                    : 'Device added successfully!',
                style: const TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                _isWaitingForConfirmation
                    ? 'Your new device should now be able to restore your account.'
                    : 'Your new device has been set up with your account.',
                style: TextStyle(
                  fontSize: 16,
                  color: CupertinoColors.secondaryLabel.resolveFrom(context),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 40),
              SizedBox(
                width: double.infinity,
                child: CupertinoButton(
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  color: CupertinoColors.activeBlue,
                  borderRadius: BorderRadius.circular(12),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    'Done',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
