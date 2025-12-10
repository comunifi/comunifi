import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/profile.dart';

/// Modal for setting up user profile during onboarding
/// Allows setting username with option to skip
/// Photo upload is disabled during onboarding - can be added from settings later
class ProfileSetupModal extends StatefulWidget {
  final String pubkey;
  final String? privateKey;

  /// If true, this is shown during onboarding and photo upload is disabled
  final bool isOnboarding;

  const ProfileSetupModal({
    super.key,
    required this.pubkey,
    this.privateKey,
    this.isOnboarding = true,
  });

  @override
  State<ProfileSetupModal> createState() => _ProfileSetupModalState();
}

class _ProfileSetupModalState extends State<ProfileSetupModal> {
  final TextEditingController _usernameController = TextEditingController();
  final ImagePicker _imagePicker = ImagePicker();

  bool _isCheckingUsername = false;
  bool? _usernameAvailable;
  String? _usernameCheckError;
  Timer? _debounceTimer;

  Uint8List? _selectedPhotoBytes;
  bool _isUploadingPhoto = false;

  bool _isSaving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _usernameController.addListener(_onUsernameChanged);
    _loadCurrentUsername();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _usernameController.removeListener(_onUsernameChanged);
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _loadCurrentUsername() async {
    final profileState = context.read<ProfileState>();
    final profile = await profileState.getProfile(widget.pubkey);
    if (mounted && profile != null) {
      final username = profile.getUsername();
      if (username.isNotEmpty) {
        setState(() {
          _usernameController.text = username;
          _usernameAvailable = true; // Current username is always available
        });
      }
    }
  }

  void _onUsernameChanged() {
    setState(() {
      _usernameAvailable = null;
      _usernameCheckError = null;
      _error = null;
    });

    _debounceTimer?.cancel();

    final username = _usernameController.text.trim();
    if (username.isEmpty) {
      return;
    }

    // Debounce: wait 500ms after user stops typing
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _checkUsernameAvailability(username);
    });
  }

  Future<void> _checkUsernameAvailability(String username) async {
    if (username.isEmpty) {
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
        widget.pubkey,
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
          _usernameCheckError = 'Error checking username';
        });
      }
    }
  }

  Future<void> _pickPhoto() async {
    // Don't allow photo upload during onboarding - group isn't ready yet
    if (widget.isOnboarding) {
      setState(
        () => _error = 'Profile photos can be added from Settings after setup',
      );
      return;
    }

    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
      if (pickedFile == null) return;
      final bytes = await pickedFile.readAsBytes();
      setState(() => _selectedPhotoBytes = bytes);
    } catch (e) {
      setState(() => _error = 'Failed to pick image');
    }
  }

  Future<void> _save() async {
    final username = _usernameController.text.trim();

    // Validate username if provided
    if (username.isNotEmpty && _usernameAvailable != true) {
      setState(() => _error = 'Please choose an available username');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      final profileState = context.read<ProfileState>();
      final groupState = context.read<GroupState>();
      final privateKey =
          widget.privateKey ?? await groupState.getNostrPrivateKey();

      // Upload photo if selected (only if not onboarding - groups need to be ready)
      if (_selectedPhotoBytes != null && !widget.isOnboarding) {
        setState(() => _isUploadingPhoto = true);

        final imageUrl = await groupState.uploadMediaToOwnGroup(
          _selectedPhotoBytes!,
          'image/jpeg',
        );

        await profileState.updateProfilePicture(
          pictureUrl: imageUrl,
          pubkey: widget.pubkey,
          privateKey: privateKey,
        );

        setState(() => _isUploadingPhoto = false);
      }

      // Update username if changed
      if (username.isNotEmpty) {
        await profileState.updateUsername(
          username: username,
          pubkey: widget.pubkey,
          privateKey: privateKey,
        );
      }

      if (mounted) {
        Navigator.of(context).pop(true); // Return true to indicate save
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isSaving = false;
          _isUploadingPhoto = false;
          _error = 'Failed to save: ${e.toString()}';
        });
      }
    }
  }

  void _skip() {
    Navigator.of(context).pop(false); // Return false to indicate skip
  }

  @override
  Widget build(BuildContext context) {
    // For onboarding, only check username changes (photo disabled)
    final hasChanges = widget.isOnboarding
        ? (_usernameController.text.trim().isNotEmpty &&
              _usernameAvailable == true)
        : _selectedPhotoBytes != null ||
              (_usernameController.text.trim().isNotEmpty &&
                  _usernameAvailable == true);

    return Container(
      height: MediaQuery.of(context).size.height * 0.75,
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
                    onPressed: _isSaving ? null : _skip,
                    child: const Text('Skip'),
                  ),
                  const Text(
                    'Set Up Profile',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 0,
                    onPressed: (_isSaving || !hasChanges) ? null : _save,
                    child: _isSaving
                        ? const CupertinoActivityIndicator()
                        : const Text(
                            'Done',
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
                  // Welcome message
                  const Text(
                    'Welcome to Comunifi!',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Personalize your profile to help others recognize you.',
                    style: TextStyle(
                      color: CupertinoColors.secondaryLabel,
                      fontSize: 16,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 32),
                  // Error message
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
                  // Profile photo picker (disabled during onboarding)
                  Center(
                    child: GestureDetector(
                      onTap: (_isSaving || widget.isOnboarding)
                          ? null
                          : _pickPhoto,
                      child: Stack(
                        children: [
                          Container(
                            width: 120,
                            height: 120,
                            decoration: BoxDecoration(
                              color: CupertinoColors.systemGrey4,
                              shape: BoxShape.circle,
                              image: _selectedPhotoBytes != null
                                  ? DecorationImage(
                                      image: MemoryImage(_selectedPhotoBytes!),
                                      fit: BoxFit.cover,
                                    )
                                  : null,
                            ),
                            child: _selectedPhotoBytes == null
                                ? const Icon(
                                    CupertinoIcons.person_fill,
                                    size: 60,
                                    color: CupertinoColors.systemGrey,
                                  )
                                : null,
                          ),
                          if (_isUploadingPhoto)
                            Container(
                              width: 120,
                              height: 120,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: CupertinoColors.black.withOpacity(0.5),
                              ),
                              child: const CupertinoActivityIndicator(
                                color: CupertinoColors.white,
                              ),
                            ),
                          // Only show camera icon if not onboarding
                          if (!_isSaving && !widget.isOnboarding)
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                width: 36,
                                height: 36,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: CupertinoColors.activeBlue,
                                ),
                                child: const Icon(
                                  CupertinoIcons.camera_fill,
                                  size: 18,
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
                          : widget.isOnboarding
                          ? 'Photo can be added from Settings'
                          : _selectedPhotoBytes != null
                          ? 'Tap to change'
                          : 'Add profile photo (optional)',
                      style: const TextStyle(
                        color: CupertinoColors.secondaryLabel,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  const SizedBox(height: 32),
                  // Username field
                  const Text(
                    'Username',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  CupertinoTextField(
                    controller: _usernameController,
                    placeholder: 'Choose a username',
                    padding: const EdgeInsets.all(12),
                    enabled: !_isSaving,
                    autocorrect: false,
                  ),
                  const SizedBox(height: 8),
                  // Username availability status
                  if (_isCheckingUsername)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          CupertinoActivityIndicator(radius: 8),
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
                  else if (_usernameAvailable != null &&
                      _usernameController.text.trim().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            _usernameAvailable!
                                ? CupertinoIcons.check_mark_circled_solid
                                : CupertinoIcons.xmark_circle,
                            color: _usernameAvailable!
                                ? CupertinoColors.systemGreen
                                : CupertinoColors.systemRed,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Text(
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
                        ],
                      ),
                    ),
                  const SizedBox(height: 24),
                  // Helper text
                  const Text(
                    'You can always change these later in your profile settings.',
                    style: TextStyle(
                      color: CupertinoColors.tertiaryLabel,
                      fontSize: 13,
                    ),
                    textAlign: TextAlign.center,
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
