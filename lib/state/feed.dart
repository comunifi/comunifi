import 'dart:async';
import 'package:flutter/cupertino.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/services/nostr/nostr.dart';

class FeedState with ChangeNotifier {
  // instantiate services here
  NostrService? _nostrService;
  StreamSubscription<NostrEventModel>? _eventSubscription;

  FeedState() {
    _initialize();
  }

  Future<void> _initialize() async {
    try {
      // Load environment variables
      try {
        await dotenv.load(fileName: '.env');
      } catch (e) {
        // .env file might not exist, try to continue with environment variables
        debugPrint('Could not load .env file: $e');
      }
      
      final relayUrl = dotenv.env['RELAY_URL'];
      
      if (relayUrl == null || relayUrl.isEmpty) {
        _errorMessage = 'RELAY_URL environment variable is not set. Please create a .env file with RELAY_URL=wss://your-relay-url';
        safeNotifyListeners();
        return;
      }

      _nostrService = NostrService(relayUrl, useTor: false);
      
      // Connect to relay
      await _nostrService!.connect((connected) {
        if (connected) {
          _isConnected = true;
          _errorMessage = null;
          safeNotifyListeners();
          _loadInitialEvents();
          _startListeningForNewEvents();
        } else {
          _isConnected = false;
          _errorMessage = 'Failed to connect to relay';
          safeNotifyListeners();
        }
      });
    } catch (e) {
      _errorMessage = 'Failed to initialize: $e';
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
    _eventSubscription?.cancel();
    _nostrService?.disconnect();
    super.dispose();
  }

  // state variables here
  bool _isConnected = false;
  bool _isLoading = false;
  bool _isLoadingMore = false;
  String? _errorMessage;
  List<NostrEventModel> _events = [];
  DateTime? _oldestEventTime;
  static const int _pageSize = 20;

  bool get isConnected => _isConnected;
  bool get isLoading => _isLoading;
  bool get isLoadingMore => _isLoadingMore;
  String? get errorMessage => _errorMessage;
  List<NostrEventModel> get events => _events;
  bool get hasMoreEvents => _oldestEventTime != null;

  // state methods here
  Future<void> _loadInitialEvents() async {
    if (_nostrService == null || !_isConnected) return;

    try {
      _isLoading = true;
      safeNotifyListeners();

      // Request initial batch of events (kind 1 = text notes)
      final pastEvents = await _nostrService!.requestPastEvents(
        kind: 1,
        limit: _pageSize,
      );

      _events = pastEvents;
      _events.sort((a, b) => b.createdAt.compareTo(a.createdAt)); // Newest first

      if (_events.isNotEmpty) {
        _oldestEventTime = _events.last.createdAt;
      }

      _isLoading = false;
      safeNotifyListeners();
    } catch (e) {
      _isLoading = false;
      _errorMessage = 'Failed to load events: $e';
      safeNotifyListeners();
    }
  }

  Future<void> loadMoreEvents() async {
    if (_nostrService == null || !_isConnected || _isLoadingMore || _oldestEventTime == null) {
      return;
    }

    try {
      _isLoadingMore = true;
      safeNotifyListeners();

      // Request events older than the oldest one we have
      final pastEvents = await _nostrService!.requestPastEvents(
        kind: 1,
        until: _oldestEventTime!.subtract(const Duration(seconds: 1)),
        limit: _pageSize,
      );

      if (pastEvents.isNotEmpty) {
        // Add new events to the end (they're older)
        _events.addAll(pastEvents);
        _events.sort((a, b) => b.createdAt.compareTo(a.createdAt)); // Keep sorted
        _oldestEventTime = _events.last.createdAt;
      } else {
        // No more events available
        _oldestEventTime = null;
      }

      _isLoadingMore = false;
      safeNotifyListeners();
    } catch (e) {
      _isLoadingMore = false;
      _errorMessage = 'Failed to load more events: $e';
      safeNotifyListeners();
    }
  }

  void _startListeningForNewEvents() {
    if (_nostrService == null || !_isConnected) return;

    try {
      // Listen for new events (kind 1 = text notes)
      // This will receive events as they come in real-time
      _eventSubscription = _nostrService!.listenToEvents(
        kind: 1,
        limit: null, // No limit for real-time events
      ).listen(
        (event) {
          // Check if we already have this event (avoid duplicates)
          if (!_events.any((e) => e.id == event.id)) {
            // Add new events at the top (they're newest)
            _events.insert(0, event);
            safeNotifyListeners();
          }
        },
        onError: (error) {
          debugPrint('Error listening to events: $error');
          _errorMessage = 'Error receiving events: $error';
          safeNotifyListeners();
        },
      );
    } catch (e) {
      debugPrint('Failed to start listening for events: $e');
      _errorMessage = 'Failed to start listening: $e';
      safeNotifyListeners();
    }
  }

  Future<void> retryConnection() async {
    _errorMessage = null;
    _events.clear();
    _oldestEventTime = null;
    safeNotifyListeners();
    await _initialize();
  }
}

