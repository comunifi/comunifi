import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:comunifi/services/mls/mls.dart';
import 'package:comunifi/services/db/app_db.dart';

class MlsPersistentState with ChangeNotifier {
  // instantiate services here
  late final MlsService _mlsService;
  late final SecurePersistentMlsStorage _mlsStorage;
  late final AppDBService _dbService;
  bool _initialized = false;
  String? _initializationError;

  MlsPersistentState() {
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      _dbService = AppDBService();
      await _dbService.init('mls_debug');
      
      _mlsStorage = await SecurePersistentMlsStorage.fromDatabase(
        database: _dbService.database!,
        cryptoProvider: DefaultMlsCryptoProvider(),
      );
      
      _mlsService = MlsService(
        cryptoProvider: DefaultMlsCryptoProvider(),
        storage: _mlsStorage,
      );
      
      _initialized = true;
      safeNotifyListeners();
    } catch (e) {
      _initializationError = 'Failed to initialize: $e';
      safeNotifyListeners();
    }
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
  bool get initialized => _initialized;
  String? get initializationError => _initializationError;
  MlsGroup? _currentGroup;
  List<MessageEntry> _messages = [];
  String? _errorMessage;
  List<GroupId> _savedGroups = [];
  bool _loadingGroups = false;

  MlsGroup? get currentGroup => _currentGroup;
  List<MessageEntry> get messages => _messages;
  String? get errorMessage => _errorMessage;
  List<GroupId> get savedGroups => _savedGroups;
  bool get loadingGroups => _loadingGroups;

  // state methods here
  Future<void> createGroup(String groupName, String userId) async {
    if (!_initialized) {
      _errorMessage = 'Storage not initialized';
      safeNotifyListeners();
      return;
    }

    try {
      _errorMessage = null;
      final group = await _mlsService.createGroup(
        creatorUserId: userId,
        groupName: groupName,
      );
      _currentGroup = group;
      _messages = [];
      await _loadSavedGroups();
      safeNotifyListeners();
    } catch (e) {
      _errorMessage = 'Failed to create group: $e';
      safeNotifyListeners();
    }
  }

  Future<void> loadGroup(GroupId groupId) async {
    if (!_initialized) {
      _errorMessage = 'Storage not initialized';
      safeNotifyListeners();
      return;
    }

    try {
      _errorMessage = null;
      final group = await _mlsService.loadGroup(groupId);
      if (group != null) {
        _currentGroup = group;
        _messages = [];
        safeNotifyListeners();
      } else {
        _errorMessage = 'Group not found';
        safeNotifyListeners();
      }
    } catch (e) {
      _errorMessage = 'Failed to load group: $e';
      safeNotifyListeners();
    }
  }

  Future<void> _loadSavedGroups() async {
    if (!_initialized) return;
    
    try {
      _loadingGroups = true;
      safeNotifyListeners();
      
      // Get all group IDs from storage
      final mlsTable = MlsGroupTable(_dbService.database!);
      _savedGroups = await mlsTable.listGroupIds();
      
      _loadingGroups = false;
      safeNotifyListeners();
    } catch (e) {
      _loadingGroups = false;
      _errorMessage = 'Failed to load groups: $e';
      safeNotifyListeners();
    }
  }

  Future<void> refreshSavedGroups() async {
    await _loadSavedGroups();
  }

  Future<void> sendMessage(String plaintext) async {
    if (!_initialized) {
      _errorMessage = 'Storage not initialized';
      safeNotifyListeners();
      return;
    }

    if (_currentGroup == null) {
      _errorMessage = 'No group loaded';
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

  Future<void> deleteGroup(GroupId groupId) async {
    if (!_initialized) return;
    
    try {
      final mlsTable = MlsGroupTable(_dbService.database!);
      await mlsTable.deleteGroup(groupId);
      await _loadSavedGroups();
      if (_currentGroup?.id.bytes.toString() == groupId.bytes.toString()) {
        clearGroup();
      }
      safeNotifyListeners();
    } catch (e) {
      _errorMessage = 'Failed to delete group: $e';
      safeNotifyListeners();
    }
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

