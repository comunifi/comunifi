import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/profile.dart';

/// Screen for setting up user profile during onboarding
/// Allows setting username and profile photo
class ProfileSetupScreen extends StatefulWidget {
  const ProfileSetupScreen({super.key});

  @override
  State<ProfileSetupScreen> createState() => _ProfileSetupScreenState();
}

class _ProfileSetupScreenState extends State<ProfileSetupScreen> {
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

  String? _pubkey;
  String? _privateKey;

  @override
  void initState() {
    super.initState();
    _usernameController.addListener(_onUsernameChanged);
    _loadKeys();
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _usernameController.removeListener(_onUsernameChanged);
    _usernameController.dispose();
    super.dispose();
  }

  Future<void> _loadKeys() async {
    final groupState = context.read<GroupState>();
    final pubkey = await groupState.getNostrPublicKey();
    final privateKey = await groupState.getNostrPrivateKey();

    if (mounted) {
      setState(() {
        _pubkey = pubkey;
        _privateKey = privateKey;
      });
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

    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      _checkUsernameAvailability(username);
    });
  }

  Future<void> _checkUsernameAvailability(String username) async {
    if (username.isEmpty || _pubkey == null) {
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
        _pubkey!,
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
    if (_isSaving) return;

    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );
      if (pickedFile == null) return;
      final bytes = await pickedFile.readAsBytes();
      setState(() {
        _selectedPhotoBytes = bytes;
        _error = null;
      });
    } catch (e) {
      setState(() => _error = 'Failed to pick image');
    }
  }

  Future<void> _save() async {
    if (_pubkey == null || _privateKey == null) {
      setState(() => _error = 'Account not ready. Please try again.');
      return;
    }

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

      // Upload photo if selected
      if (_selectedPhotoBytes != null) {
        setState(() => _isUploadingPhoto = true);

        final imageUrl = await groupState.uploadMediaToOwnGroup(
          _selectedPhotoBytes!,
          'image/jpeg',
        );

        await profileState.updateProfilePicture(
          pictureUrl: imageUrl,
          pubkey: _pubkey!,
          privateKey: _privateKey!,
        );

        setState(() => _isUploadingPhoto = false);
      }

      // Update username if changed
      if (username.isNotEmpty) {
        await profileState.updateUsername(
          username: username,
          pubkey: _pubkey!,
          privateKey: _privateKey!,
        );
      }

      // Navigate to backup prompt screen
      if (mounted) {
        context.go('/onboarding/backup');
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
    context.go('/onboarding/backup');
  }

  @override
  Widget build(BuildContext context) {
    final hasChanges =
        _selectedPhotoBytes != null ||
        (_usernameController.text.trim().isNotEmpty &&
            _usernameAvailable == true);

    return CupertinoPageScaffold(
      child: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: SingleChildScrollView(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(height: 40),

                    // Profile photo picker
                    GestureDetector(
                      onTap: _isSaving ? null : _pickPhoto,
                      child: Stack(
                        children: [
                          Container(
                            width: 120,
                            height: 120,
                            decoration: BoxDecoration(
                              color: CupertinoColors.systemBlue.withOpacity(
                                0.15,
                              ),
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
                                    size: 50,
                                    color: CupertinoColors.systemBlue,
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
                          if (!_isSaving)
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
                    const SizedBox(height: 8),
                    Text(
                      _isUploadingPhoto
                          ? 'Uploading...'
                          : _selectedPhotoBytes != null
                          ? 'Tap to change'
                          : 'Add profile photo',
                      style: TextStyle(
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // Title
                    const Text(
                      'Set Up Your Profile',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),

                    // Description
                    Text(
                      'Personalize your profile to help others recognize you.',
                      style: TextStyle(
                        fontSize: 16,
                        color: CupertinoColors.secondaryLabel.resolveFrom(
                          context,
                        ),
                        height: 1.4,
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
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                    // Username field
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        'Username',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    CupertinoTextField(
                      controller: _usernameController,
                      placeholder: 'Enter your username',
                      padding: const EdgeInsets.all(14),
                      enabled: !_isSaving,
                      autocorrect: false,
                      textCapitalization: TextCapitalization.none,
                      decoration: BoxDecoration(
                        color: CupertinoColors.systemGrey6.resolveFrom(context),
                        borderRadius: BorderRadius.circular(12),
                      ),
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

                    const SizedBox(height: 32),

                    // Continue button
                    SizedBox(
                      width: double.infinity,
                      child: CupertinoButton(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        color: CupertinoColors.activeBlue,
                        borderRadius: BorderRadius.circular(12),
                        onPressed: (_isSaving || !hasChanges) ? null : _save,
                        child: _isSaving
                            ? const CupertinoActivityIndicator(
                                color: CupertinoColors.white,
                              )
                            : const Text(
                                'Continue',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  fontSize: 16,
                                  color: CupertinoColors.white,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 12),

                    // Skip button
                    SizedBox(
                      width: double.infinity,
                      child: CupertinoButton(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        color: CupertinoColors.systemGrey5,
                        borderRadius: BorderRadius.circular(12),
                        onPressed: _isSaving ? null : _skip,
                        child: const Text(
                          'Skip for Now',
                          style: TextStyle(
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                            color: CupertinoColors.label,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Note about settings
                    Text(
                      'You can always update your profile later from Settings.',
                      style: TextStyle(
                        fontSize: 13,
                        color: CupertinoColors.tertiaryLabel.resolveFrom(
                          context,
                        ),
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
