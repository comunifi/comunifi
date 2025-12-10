import 'package:flutter/cupertino.dart';

/// A sidebar that slides in from the left or right side of the screen
class SlideInSidebar extends StatefulWidget {
  final Widget child;
  final bool isOpen;
  final VoidCallback onClose;
  final SlideInSidebarPosition position;
  final double width;

  const SlideInSidebar({
    super.key,
    required this.child,
    required this.isOpen,
    required this.onClose,
    this.position = SlideInSidebarPosition.left,
    this.width = 300.0,
  });

  @override
  State<SlideInSidebar> createState() => _SlideInSidebarState();
}

enum SlideInSidebarPosition { left, right }

class _SlideInSidebarState extends State<SlideInSidebar>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<Offset> _slideAnimation;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    final slideDirection = widget.position == SlideInSidebarPosition.left
        ? const Offset(-1.0, 0.0)
        : const Offset(1.0, 0.0);

    _slideAnimation = Tween<Offset>(
      begin: slideDirection,
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    _fadeAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));

    if (widget.isOpen) {
      _controller.forward();
    }
  }

  @override
  void didUpdateWidget(SlideInSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isOpen != oldWidget.isOpen) {
      if (widget.isOpen) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isOpen && _controller.value == 0.0) {
      return const SizedBox.shrink();
    }

    // Positioned must be a direct child of Stack, so wrap IgnorePointer inside it
    // Use IgnorePointer when closing to allow touch events to pass through
    // during the close animation
    return Positioned.fill(
      child: IgnorePointer(
        ignoring: !widget.isOpen,
        child: Stack(
          children: [
            // Backdrop
            GestureDetector(
              onTap: widget.onClose,
              child: FadeTransition(
                opacity: _fadeAnimation,
                child: Container(color: CupertinoColors.black.withOpacity(0.3)),
              ),
            ),
            // Sidebar
            SlideTransition(
              position: _slideAnimation,
              child: Align(
                alignment: widget.position == SlideInSidebarPosition.left
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                child: GestureDetector(
                  onTap:
                      () {}, // Prevent tap from closing when tapping inside sidebar
                  child: Container(
                    width: widget.width,
                    height: double.infinity,
                    color: CupertinoColors.systemBackground,
                    child: widget.child,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
