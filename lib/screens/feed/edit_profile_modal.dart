import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/profile.dart';

/// Modal for editing user profile
/// Shows as a bottom sheet with profile picture and username editing
class EditProfileModal extends StatefulWidget {
  const EditProfileModal({super.key});

  @override
  State<EditProfileModal> createState() => _EditProfileModalState();
}

class _EditProfileModalState extends State<EditProfileModal> {
  final TextEditingController _usernameController = TextEditingController();
  bool _isCheckingUsername = false;
  bool? _usernameAvailable;
  String? _usernameCheckError;
  bool _isSaving = false;
  String? _error;
  Timer? _debounceTimer;
  String? _userNostrPubkey;
  String? _userUsername;
  bool _skipNextUsernameLoad = false;

  // Profile photo state
  String? _currentProfilePictureUrl;
  Uint8List? _selectedPhotoBytes;
  bool _isUploadingPhoto = false;
  String? _uploadPhotoError;
  final ImagePicker _imagePicker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _usernameController.addListener(_onUsernameChanged);
    _loadUserData();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _loadUserData() async {
    final groupState = context.read<GroupState>();
    final profileState = context.read<ProfileState>();

    // Retry mechanism: try up to 5 times with increasing delays
    String? pubkey;
    for (int attempt = 0; attempt < 5; attempt++) {
      pubkey = await groupState.getNostrPublicKey();
      if (pubkey != null) {
        break;
      }

      // Wait before retrying (exponential backoff: 200ms, 400ms, 800ms, 1600ms, 3200ms)
      if (attempt < 4) {
        await Future.delayed(Duration(milliseconds: 200 * (1 << attempt)));
      }
    }

    if (mounted) {
      setState(() {
        _userNostrPubkey = pubkey;
      });
    }

    // Load username and profile picture
    if (pubkey != null && !_skipNextUsernameLoad) {
      final profile = await profileState.getProfile(pubkey);
      if (mounted) {
        setState(() {
          _userUsername = profile?.getUsername();
          _usernameController.text = profile?.getUsername() ?? '';
          _currentProfilePictureUrl = profile?.picture;
        });
      }
    }
  }

  Future<void> _pickPhoto() async {
    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );

      if (pickedFile == null) {
        return; // User cancelled
      }

      final bytes = await pickedFile.readAsBytes();
      setState(() {
        _selectedPhotoBytes = bytes;
        _uploadPhotoError = null;
      });
    } catch (e) {
      setState(() {
        _uploadPhotoError = 'Failed to pick image: $e';
      });
    }
  }

  void _onUsernameChanged() {
    // Reset state when username changes
    setState(() {
      _usernameAvailable = null;
      _usernameCheckError = null;
      _error = null;
    });

    // Cancel previous timer
    _debounceTimer?.cancel();

    final username = _usernameController.text.trim();
    if (username.isEmpty) {
      return;
    }

    // Don't check if it's the same as current username
    if (username == _userUsername) {
      setState(() {
        _usernameAvailable = true; // Their own username is always available
      });
      return;
    }

    // Debounce: wait 500ms after user stops typing
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _checkUsernameAvailability(username);
    });
  }

  Future<void> _checkUsernameAvailability(String username) async {
    if (username.isEmpty || _userNostrPubkey == null) {
      setState(() {
        _usernameAvailable = null;
        _isCheckingUsername = false;
      });
      return;
    }

    setState(() {
      _isCheckingUsername = true;
      _usernameCheckError = null;
    });

    try {
      final profileState = context.read<ProfileState>();
      final isAvailable = await profileState.isUsernameAvailable(
        username,
        _userNostrPubkey!,
      );

      if (mounted) {
        setState(() {
          _isCheckingUsername = false;
          _usernameAvailable = isAvailable;
          if (!isAvailable) {
            _usernameCheckError = 'Username is already taken';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCheckingUsername = false;
          _usernameAvailable = false;
          _usernameCheckError = 'Error checking username: $e';
        });
      }
    }
  }

  Future<void> _save() async {
    final groupState = context.read<GroupState>();
    if (!groupState.isConnected) {
      setState(() => _error = 'Not connected to relay');
      return;
    }

    final username = _usernameController.text.trim();
    if (username.isEmpty) {
      setState(() => _error = 'Username cannot be empty');
      return;
    }

    if (username != _userUsername && _usernameAvailable != true) {
      setState(() => _error = 'Please choose an available username');
      return;
    }

    if (_userNostrPubkey == null) {
      setState(() => _error = 'No user pubkey available');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      final profileState = context.read<ProfileState>();
      final privateKey = await groupState.getNostrPrivateKey();
      if (privateKey == null) {
        throw Exception('No private key available');
      }

      // Upload photo if selected
      if (_selectedPhotoBytes != null) {
        setState(() => _isUploadingPhoto = true);

        final imageUrl = await groupState.uploadMediaToOwnGroup(
          _selectedPhotoBytes!,
          'image/jpeg',
        );

        await profileState.updateProfilePicture(
          pictureUrl: imageUrl,
          pubkey: _userNostrPubkey!,
          privateKey: privateKey,
        );

        setState(() {
          _currentProfilePictureUrl = imageUrl;
          _isUploadingPhoto = false;
        });
      }

      // Update username if changed
      if (username != _userUsername) {
        await profileState.updateUsername(
          username: username,
          pubkey: _userNostrPubkey!,
          privateKey: privateKey,
        );

        setState(() {
          _userUsername = username;
          _skipNextUsernameLoad = true;
        });
      }

      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _isSaving = false;
        _isUploadingPhoto = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasChanges = _selectedPhotoBytes != null ||
        (_usernameController.text.trim() != (_userUsername ?? ''));

    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      decoration: const BoxDecoration(
        color: CupertinoColors.systemBackground,
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: CupertinoColors.systemGrey4,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 0,
                    onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const Text(
                    'Edit Profile',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 0,
                    onPressed: (_isSaving || !hasChanges) ? null : _save,
                    child: _isSaving
                        ? const CupertinoActivityIndicator()
                        : const Text(
                            'Save',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                  ),
                ],
              ),
            ),
            Container(height: 0.5, color: CupertinoColors.separator),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (_error != null)
                    Container(
                      padding: const EdgeInsets.all(12),
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: CupertinoColors.systemRed.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            CupertinoIcons.exclamationmark_triangle,
                            color: CupertinoColors.systemRed,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _error!,
                              style: const TextStyle(
                                color: CupertinoColors.systemRed,
                                fontSize: 12,
                              ),
                            ),
                          ),
                          CupertinoButton(
                            padding: EdgeInsets.zero,
                            minSize: 0,
                            onPressed: () => setState(() => _error = null),
                            child: const Icon(
                              CupertinoIcons.xmark_circle_fill,
                              color: CupertinoColors.systemRed,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                    ),
                  // Profile photo picker
                  Center(
                    child: GestureDetector(
                      onTap: _isSaving ? null : _pickPhoto,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: CupertinoColors.systemGrey4,
                              image: _selectedPhotoBytes != null
                                  ? DecorationImage(
                                      image: MemoryImage(_selectedPhotoBytes!),
                                      fit: BoxFit.cover,
                                    )
                                  : (_currentProfilePictureUrl != null
                                      ? DecorationImage(
                                          image: NetworkImage(
                                            _currentProfilePictureUrl!,
                                          ),
                                          fit: BoxFit.cover,
                                        )
                                      : null),
                            ),
                            child: (_selectedPhotoBytes == null &&
                                    _currentProfilePictureUrl == null)
                                ? const Icon(
                                    CupertinoIcons.person_fill,
                                    size: 50,
                                    color: CupertinoColors.systemGrey,
                                  )
                                : null,
                          ),
                          if (_isUploadingPhoto)
                            Container(
                              width: 100,
                              height: 100,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: CupertinoColors.black.withOpacity(0.5),
                              ),
                              child: const CupertinoActivityIndicator(
                                color: CupertinoColors.white,
                              ),
                            ),
                          if (!_isUploadingPhoto)
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: CupertinoColors.activeBlue,
                                ),
                                child: const Icon(
                                  CupertinoIcons.camera_fill,
                                  size: 16,
                                  color: CupertinoColors.white,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      _isUploadingPhoto
                          ? 'Uploading...'
                          : _selectedPhotoBytes != null ||
                                  _currentProfilePictureUrl != null
                          ? 'Tap to change photo'
                          : 'Tap to add photo',
                      style: const TextStyle(
                        color: CupertinoColors.secondaryLabel,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  if (_uploadPhotoError != null) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: CupertinoColors.systemRed.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            CupertinoIcons.exclamationmark_triangle,
                            color: CupertinoColors.systemRed,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _uploadPhotoError!,
                              style: const TextStyle(
                                color: CupertinoColors.systemRed,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  // Username field
                  CupertinoTextField(
                    controller: _usernameController,
                    placeholder: _userNostrPubkey == null
                        ? 'Loading...'
                        : 'Enter username',
                    padding: const EdgeInsets.all(12),
                    enabled: _userNostrPubkey != null && !_isSaving,
                    decoration: BoxDecoration(
                      color: _userNostrPubkey == null
                          ? CupertinoColors.systemGrey5
                          : CupertinoColors.systemBackground,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: CupertinoColors.separator,
                        width: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Username availability check status
                  if (_isCheckingUsername)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8.0),
                      child: Row(
                        children: [
                          CupertinoActivityIndicator(radius: 10),
                          SizedBox(width: 8),
                          Text(
                            'Checking availability...',
                            style: TextStyle(
                              color: CupertinoColors.secondaryLabel,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    )
                  else if (_usernameAvailable != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8.0),
                      child: Row(
                        children: [
                          Icon(
                            _usernameAvailable!
                                ? CupertinoIcons.check_mark_circled_solid
                                : CupertinoIcons.xmark_circle,
                            color: _usernameAvailable!
                                ? CupertinoColors.systemGreen
                                : CupertinoColors.systemRed,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _usernameAvailable!
                                  ? 'Username available'
                                  : (_usernameCheckError ?? 'Username taken'),
                              style: TextStyle(
                                color: _usernameAvailable!
                                    ? CupertinoColors.systemGreen
                                    : CupertinoColors.systemRed,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (_userNostrPubkey == null)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8.0),
                      child: Row(
                        children: [
                          CupertinoActivityIndicator(radius: 10),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              'Loading user data...',
                              style: TextStyle(
                                color: CupertinoColors.secondaryLabel,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
