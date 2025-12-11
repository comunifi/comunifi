import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/profile.dart';

/// Author avatar that displays profile photo by pubkey
class AuthorAvatar extends StatefulWidget {
  final String pubkey;
  final double size;

  const AuthorAvatar({super.key, required this.pubkey, this.size = 32});

  @override
  State<AuthorAvatar> createState() => _AuthorAvatarState();
}

class _AuthorAvatarState extends State<AuthorAvatar> {
  String? _profilePictureUrl;

  @override
  void initState() {
    super.initState();
    _loadProfilePicture();
  }

  Future<void> _loadProfilePicture() async {
    try {
      final profileState = context.read<ProfileState>();
      final profile = await profileState.getProfile(widget.pubkey);
      if (mounted && profile?.picture != null) {
        setState(() {
          _profilePictureUrl = profile!.picture;
        });
      }
    } catch (e) {
      // Silently fail - will show placeholder
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey4,
        shape: BoxShape.circle,
        image: _profilePictureUrl != null
            ? DecorationImage(
                image: NetworkImage(_profilePictureUrl!),
                fit: BoxFit.cover,
              )
            : null,
      ),
      child: _profilePictureUrl == null
          ? Icon(
              CupertinoIcons.person_fill,
              size: widget.size * 0.6,
              color: CupertinoColors.systemGrey,
            )
          : null,
    );
  }
}
