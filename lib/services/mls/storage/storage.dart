import '../group_state/group_state.dart';

/// Abstract storage interface for MLS group state
abstract class MlsStorage {
  Future<void> saveGroupState(GroupState state);
  Future<GroupState?> loadGroupState(GroupId groupId);
  
  /// Save group name
  Future<void> saveGroupName(GroupId groupId, String name);
  
  /// Load group name
  Future<String?> loadGroupName(GroupId groupId);
}

/// In-memory storage implementation for testing
class InMemoryMlsStorage implements MlsStorage {
  final Map<String, GroupState> _storage = {};
  final Map<String, String> _groupNames = {};

  @override
  Future<void> saveGroupState(GroupState state) async {
    final key = _groupKey(state.context.groupId);
    _storage[key] = state;
  }

  @override
  Future<GroupState?> loadGroupState(GroupId groupId) async {
    final key = _groupKey(groupId);
    return _storage[key];
  }

  @override
  Future<void> saveGroupName(GroupId groupId, String name) async {
    final key = _groupKey(groupId);
    _groupNames[key] = name;
  }

  @override
  Future<String?> loadGroupName(GroupId groupId) async {
    final key = _groupKey(groupId);
    return _groupNames[key];
  }

  String _groupKey(GroupId groupId) {
    return groupId.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

