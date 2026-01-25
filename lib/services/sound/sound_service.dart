import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Global sound service for simple app-wide sound effects.
class SoundService {
  SoundService._();

  /// Singleton instance.
  static final SoundService instance = SoundService._();

  final AudioPlayer _player = AudioPlayer();

  /// Play the notification sound for a newly received post.
  ///
  /// Errors are logged but never thrown.
  Future<void> playNewPostSound() async {
    try {
      // Restart from the beginning each time.
      await _player.stop();
      await _player.play(
        AssetSource('sounds/ding.mp3'),
      );
    } catch (e) {
      debugPrint('Failed to play new post sound: $e');
    }
  }
}

