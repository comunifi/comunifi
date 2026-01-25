import 'package:flutter/cupertino.dart';
import 'package:comunifi/widgets/channels_sidebar.dart';
import 'package:comunifi/widgets/members_sidebar.dart';

/// Tabbed sidebar that switches between Channels and Members views
class GroupRightSidebar extends StatefulWidget {
  final VoidCallback onClose;
  final bool showCloseButton;

  const GroupRightSidebar({
    super.key,
    required this.onClose,
    this.showCloseButton = true,
  });

  @override
  State<GroupRightSidebar> createState() => _GroupRightSidebarState();
}

class _GroupRightSidebarState extends State<GroupRightSidebar> {
  int _selectedIndex = 0; // 0 = Channels, 1 = Members

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Tab selector
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: CupertinoSlidingSegmentedControl<int>(
            groupValue: _selectedIndex,
            onValueChanged: (value) {
              if (value != null) {
                setState(() {
                  _selectedIndex = value;
                });
              }
            },
            children: const {
              0: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('Channels'),
              ),
              1: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('Members'),
              ),
            },
          ),
        ),

        Container(
          height: 0.5,
          color: CupertinoColors.separator.resolveFrom(context),
        ),

        // Content based on selected tab
        Expanded(
          child: _selectedIndex == 0
              ? ChannelsSidebar(
                  onClose: widget.onClose,
                  showCloseButton: false,
                )
              : MembersSidebar(
                  onClose: widget.onClose,
                  showCloseButton: false,
                ),
        ),
      ],
    );
  }
}
