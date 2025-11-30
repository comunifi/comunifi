import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:comunifi/services/mls/mls.dart';

class MlsState with ChangeNotifier {
  // instantiate services here
  late final MlsService _mlsService;
  late final InMemoryMlsStorage _mlsStorage;

  MlsState() {
    _mlsStorage = InMemoryMlsStorage();
    _mlsService = MlsService(
      cryptoProvider: DefaultMlsCryptoProvider(),
      storage: _mlsStorage,
    );
  }

  // private variables here
  bool _mounted = true;
  void safeNotifyListeners() {
    if (_mounted) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _mounted = false;
    super.dispose();
  }

  // state variables here
  MlsGroup? _currentGroup;
  List<MessageEntry> _messages = [];
  String? _errorMessage;

  MlsGroup? get currentGroup => _currentGroup;
  List<MessageEntry> get messages => _messages;
  String? get errorMessage => _errorMessage;

  // state methods here
  Future<void> createGroup(String groupName, String userId) async {
    try {
      _errorMessage = null;
      final group = await _mlsService.createGroup(
        creatorUserId: userId,
        groupName: groupName,
      );
      _currentGroup = group;
      _messages = [];
      safeNotifyListeners();
    } catch (e) {
      _errorMessage = 'Failed to create group: $e';
      safeNotifyListeners();
    }
  }

  Future<void> sendMessage(String plaintext) async {
    if (_currentGroup == null) {
      _errorMessage = 'No group created';
      safeNotifyListeners();
      return;
    }

    try {
      _errorMessage = null;
      final plaintextBytes = Uint8List.fromList(plaintext.codeUnits);
      final ciphertext = await _currentGroup!.encryptApplicationMessage(
        plaintextBytes,
      );

      // Decrypt to verify it works
      final decrypted = await _currentGroup!.decryptApplicationMessage(
        ciphertext,
      );
      final decryptedText = String.fromCharCodes(decrypted);

      _messages.add(
        MessageEntry(
          plaintext: plaintext,
          ciphertext: ciphertext,
          decrypted: decryptedText,
          epoch: ciphertext.epoch,
        ),
      );
      safeNotifyListeners();
    } catch (e) {
      _errorMessage = 'Failed to send message: $e';
      safeNotifyListeners();
    }
  }

  void clearMessages() {
    _messages = [];
    safeNotifyListeners();
  }

  void clearGroup() {
    _currentGroup = null;
    _messages = [];
    _errorMessage = null;
    safeNotifyListeners();
  }
}

class MessageEntry {
  final String plaintext;
  final MlsCiphertext ciphertext;
  final String decrypted;
  final int epoch;

  MessageEntry({
    required this.plaintext,
    required this.ciphertext,
    required this.decrypted,
    required this.epoch,
  });
}

