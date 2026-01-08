import 'package:flutter/cupertino.dart';
import 'package:comunifi/models/nostr_event.dart';

/// Button widget for quoting/reposting a post
/// Opens the quote post modal when pressed
class QuoteButton extends StatelessWidget {
  final NostrEventModel event;
  final VoidCallback onPressed;

  const QuoteButton({
    super.key,
    required this.event,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return CupertinoButton(
      padding: EdgeInsets.zero,
      minSize: 0,
      onPressed: onPressed,
      child: const Icon(
        CupertinoIcons.arrow_2_squarepath,
        size: 20,
        color: CupertinoColors.systemGreen,
      ),
    );
  }
}



