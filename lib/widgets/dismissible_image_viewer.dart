import 'package:flutter/cupertino.dart';

/// A fullscreen image viewer with swipe-down-to-dismiss functionality.
/// Similar to image viewers in Instagram, Twitter, etc.
class DismissibleImageViewer extends StatefulWidget {
  final String imageUrl;

  const DismissibleImageViewer({
    super.key,
    required this.imageUrl,
  });

  /// Shows the dismissible image viewer as a fullscreen modal
  static void show(BuildContext context, String imageUrl) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        barrierColor: CupertinoColors.black,
        pageBuilder: (context, animation, secondaryAnimation) {
          return DismissibleImageViewer(imageUrl: imageUrl);
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return FadeTransition(
            opacity: animation,
            child: child,
          );
        },
      ),
    );
  }

  @override
  State<DismissibleImageViewer> createState() => _DismissibleImageViewerState();
}

class _DismissibleImageViewerState extends State<DismissibleImageViewer>
    with SingleTickerProviderStateMixin {
  /// Current vertical drag offset
  double _dragOffset = 0;

  /// Animation controller for dismiss/reset animations
  late AnimationController _animationController;

  /// Animation for smooth transitions
  Animation<double>? _animation;

  /// Threshold to trigger dismiss (percentage of screen height)
  static const double _dismissThreshold = 0.2;

  /// Velocity threshold to trigger dismiss even with small drag
  static const double _velocityThreshold = 1000;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
  }

  @override
  void dispose() {
    _animationController.dispose();
    super.dispose();
  }

  void _onVerticalDragStart(DragStartDetails details) {
    _animationController.stop();
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    setState(() {
      _dragOffset += details.delta.dy;
    });
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final screenHeight = MediaQuery.of(context).size.height;
    final dragPercentage = _dragOffset.abs() / screenHeight;
    final velocity = details.primaryVelocity ?? 0;

    // Dismiss if dragged past threshold or with high velocity
    if (dragPercentage > _dismissThreshold ||
        velocity.abs() > _velocityThreshold) {
      _dismiss(velocity > 0 ? 1 : -1);
    } else {
      _resetPosition();
    }
  }

  void _dismiss(int direction) {
    final screenHeight = MediaQuery.of(context).size.height;
    final targetOffset = direction * screenHeight;

    _animation = Tween<double>(
      begin: _dragOffset,
      end: targetOffset,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    ));

    _animation!.addListener(() {
      setState(() {
        _dragOffset = _animation!.value;
      });
    });

    _animationController.forward(from: 0).then((_) {
      Navigator.of(context).pop();
    });
  }

  void _resetPosition() {
    _animation = Tween<double>(
      begin: _dragOffset,
      end: 0,
    ).animate(CurvedAnimation(
      parent: _animationController,
      curve: Curves.easeOut,
    ));

    _animation!.addListener(() {
      setState(() {
        _dragOffset = _animation!.value;
      });
    });

    _animationController.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final dragPercentage = (_dragOffset.abs() / screenHeight).clamp(0.0, 1.0);

    // Background opacity decreases as we drag
    final backgroundOpacity = (1.0 - dragPercentage * 1.5).clamp(0.0, 1.0);

    // Scale decreases slightly as we drag
    final scale = (1.0 - dragPercentage * 0.3).clamp(0.7, 1.0);

    return CupertinoPageScaffold(
      backgroundColor: CupertinoColors.black.withOpacity(backgroundOpacity),
      child: Stack(
        children: [
          // Dismiss area (tap to close)
          Positioned.fill(
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              behavior: HitTestBehavior.opaque,
              child: const SizedBox.expand(),
            ),
          ),
          // Image with drag gesture
          Positioned.fill(
            child: GestureDetector(
              onVerticalDragStart: _onVerticalDragStart,
              onVerticalDragUpdate: _onVerticalDragUpdate,
              onVerticalDragEnd: _onVerticalDragEnd,
              child: Transform.translate(
                offset: Offset(0, _dragOffset),
                child: Transform.scale(
                  scale: scale,
                  child: Center(
                    child: InteractiveViewer(
                      minScale: 0.5,
                      maxScale: 4.0,
                      child: Image.network(
                        widget.imageUrl,
                        fit: BoxFit.contain,
                        loadingBuilder: (context, child, loadingProgress) {
                          if (loadingProgress == null) return child;
                          return const Center(
                            child: CupertinoActivityIndicator(
                              color: CupertinoColors.white,
                            ),
                          );
                        },
                        errorBuilder: (context, error, stackTrace) {
                          return const Center(
                            child: Icon(
                              CupertinoIcons.photo,
                              color: CupertinoColors.systemGrey,
                              size: 64,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          // Close button (appears at top)
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 16,
            child: Opacity(
              opacity: backgroundOpacity,
              child: CupertinoButton(
                padding: EdgeInsets.zero,
                onPressed: () => Navigator.of(context).pop(),
                child: Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    color: CupertinoColors.black.withOpacity(0.5),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    CupertinoIcons.xmark,
                    color: CupertinoColors.white,
                    size: 20,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

