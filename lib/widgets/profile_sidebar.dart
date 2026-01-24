import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:comunifi/state/group.dart';
import 'package:comunifi/state/profile.dart';
import 'package:comunifi/state/feed.dart';
import 'package:comunifi/services/profile/profile.dart' show ProfileData;
import 'package:comunifi/screens/recovery/send_recovery_screen.dart';
import 'package:comunifi/theme/colors.dart';

class ProfileSidebar extends StatefulWidget {
  final VoidCallback onClose;
  final bool showCloseButton;

  const ProfileSidebar({
    super.key,
    required this.onClose,
    this.showCloseButton = true,
  });

  @override
  State<ProfileSidebar> createState() => _ProfileSidebarState();
}

class _ProfileSidebarState extends State<ProfileSidebar> {
  final TextEditingController _usernameController = TextEditingController();
  bool _isCheckingUsername = false;
  bool? _usernameAvailable;
  String? _usernameCheckError;
  bool _isUpdatingUsername = false;
  String? _updateUsernameError;
  Timer? _debounceTimer;
  String? _userNostrPubkey;
  String? _userUsername;
  bool _skipNextUsernameLoad = false;
  bool _hasLoadedProfile = false;

  // Profile photo state
  String? _currentProfilePictureUrl;
  bool _isUploadingPhoto = false;
  String? _uploadPhotoError;
  final ImagePicker _imagePicker = ImagePicker();

  // Danger zone state
  bool _isDeletingData = false;

  // Device linking state
  bool _isGeneratingRecoveryLink = false;
  final GlobalKey _saveRecoveryLinkButtonKey = GlobalKey();

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

  Future<void> _pickAndUploadPhoto() async {
    try {
      // Pick image from gallery
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 800,
        maxHeight: 800,
        imageQuality: 85,
      );

      if (pickedFile == null) {
        return; // User cancelled
      }

      setState(() {
        _isUploadingPhoto = true;
        _uploadPhotoError = null;
      });

      // Read file bytes
      final Uint8List fileBytes = await pickedFile.readAsBytes();
      final String mimeType = pickedFile.mimeType ?? 'image/jpeg';

      // Upload to user's own group
      final groupState = context.read<GroupState>();
      final imageUrl = await groupState.uploadMediaToOwnGroup(
        fileBytes,
        mimeType,
      );

      // Update profile with new picture URL
      final profileState = context.read<ProfileState>();
      final privateKey = await groupState.getNostrPrivateKey();

      await profileState.updateProfilePicture(
        pictureUrl: imageUrl,
        pubkey: _userNostrPubkey,
        privateKey: privateKey,
      );

      if (mounted) {
        setState(() {
          _currentProfilePictureUrl = imageUrl;
          _isUploadingPhoto = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isUploadingPhoto = false;
          _uploadPhotoError = e.toString();
        });
      }
    }
  }

  void _onUsernameChanged() {
    // Reset state when username changes
    setState(() {
      _usernameAvailable = null;
      _usernameCheckError = null;
      _updateUsernameError = null;
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

  Future<void> _updateUsername() async {
    final username = _usernameController.text.trim();
    if (username.isEmpty) {
      setState(() {
        _updateUsernameError = 'Username cannot be empty';
      });
      return;
    }

    if (_usernameAvailable != true) {
      setState(() {
        _updateUsernameError = 'Please choose an available username';
      });
      return;
    }

    if (_userNostrPubkey == null) {
      setState(() {
        _updateUsernameError = 'No user pubkey available';
      });
      return;
    }

    setState(() {
      _isUpdatingUsername = true;
      _updateUsernameError = null;
    });

    try {
      final profileState = context.read<ProfileState>();
      final groupState = context.read<GroupState>();

      // Get private key from GroupState
      final privateKey = await groupState.getNostrPrivateKey();
      if (privateKey == null) {
        throw Exception('No private key available');
      }

      await profileState.updateUsername(
        username: username,
        pubkey: _userNostrPubkey!,
        privateKey: privateKey,
      );

      // Update local state immediately with the new username
      if (mounted) {
        setState(() {
          _userUsername = username;
          _usernameController.text = username;
          _isUpdatingUsername = false;
          _skipNextUsernameLoad = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isUpdatingUsername = false;
          _updateUsernameError = e.toString();
        });
      }
    }
  }

  Future<void> _addNewDevice() async {
    Navigator.of(context).push(
      CupertinoPageRoute(builder: (context) => const SendRecoveryScreen()),
    );
  }

  Future<void> _saveRecoveryLink() async {
    setState(() {
      _isGeneratingRecoveryLink = true;
    });

    try {
      final groupState = context.read<GroupState>();
      final payload = await groupState.generateRecoveryPayload();
      if (payload == null) {
        throw Exception('Failed to generate recovery link');
      }

      final recoveryLink = payload.toRecoveryLink();

      // Get button position for macOS
      Rect? sharePositionOrigin;
      if (Platform.isMacOS) {
        final box =
            _saveRecoveryLinkButtonKey.currentContext?.findRenderObject()
                as RenderBox?;
        if (box != null) {
          final position = box.localToGlobal(Offset.zero);
          sharePositionOrigin = position & box.size;
        }
      }

      // Show share sheet
      await Share.share(
        recoveryLink,
        subject: 'Comunifi Recovery Link',
        sharePositionOrigin: sharePositionOrigin,
      );
    } catch (e) {
      if (mounted) {
        showCupertinoDialog(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('Error'),
            content: Text('Failed to generate recovery link: $e'),
            actions: [
              CupertinoDialogAction(
                child: const Text('OK'),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGeneratingRecoveryLink = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch for profile changes - when the profile updates, refresh local state
    if (_userNostrPubkey != null) {
      final profile = context.select<ProfileState, ProfileData?>(
        (state) => state.profiles[_userNostrPubkey],
      );

      // Update local state if profile picture changed and we're not currently uploading
      if (profile != null && !_isUploadingPhoto) {
        final newPicture = profile.picture;
        final newUsername = profile.getUsername();

        // Schedule state update after build if values changed
        // Allow updates if: first load OR picture actually changed from a non-null value
        final shouldUpdatePicture =
            newPicture != _currentProfilePictureUrl &&
            (!_hasLoadedProfile ||
                (_currentProfilePictureUrl != null && newPicture != null));
        if (shouldUpdatePicture) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_isUploadingPhoto) {
              setState(() {
                _currentProfilePictureUrl = newPicture;
                _hasLoadedProfile = true;
              });
            }
          });
        }

        // Also update username if not currently editing
        if (!_skipNextUsernameLoad &&
            newUsername != _userUsername &&
            _usernameController.text == (_userUsername ?? '')) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_isUpdatingUsername) {
              setState(() {
                _userUsername = newUsername;
                _usernameController.text = newUsername;
              });
            }
          });
        }
      }
    }

    return SafeArea(
      child: Column(
        children: [
          // Header with close button
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: AppColors.separator,
                  width: 0.5,
                ),
              ),
            ),
            child: Row(
              children: [
                const Text(
                  'Profile',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
                if (widget.showCloseButton) ...[
                  const Spacer(),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 0,
                    onPressed: widget.onClose,
                    child: const Icon(CupertinoIcons.xmark),
                  ),
                ],
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // Profile photo section
                Container(
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      const Text(
                        'Profile Photo',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Profile picture avatar
                      GestureDetector(
                        onTap: _isUploadingPhoto ? null : _pickAndUploadPhoto,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            Container(
                              width: 100,
                              height: 100,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.surfaceElevated,
                              ),
                              child: _currentProfilePictureUrl != null
                                  ? ClipOval(
                                      child: Image.network(
                                        _currentProfilePictureUrl!,
                                        width: 100,
                                        height: 100,
                                        fit: BoxFit.cover,
                                        loadingBuilder:
                                            (context, child, loadingProgress) {
                                              if (loadingProgress == null) {
                                                return child;
                                              }
                                              return Container(
                                                width: 100,
                                                height: 100,
                                                color: AppColors.surfaceElevated,
                                                child: const Center(
                                                  child:
                                                      CupertinoActivityIndicator(
                                                    radius: 15,
                                                  ),
                                                ),
                                              );
                                            },
                                        errorBuilder:
                                            (context, error, stackTrace) {
                                              return const Icon(
                                                CupertinoIcons.person_fill,
                                                size: 50,
                                                color: AppColors.secondaryLabel,
                                              );
                                            },
                                      ),
                                    )
                                  : const Icon(
                                      CupertinoIcons.person_fill,
                                      size: 50,
                                      color: AppColors.secondaryLabel,
                                    ),
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
                                    color: AppColors.primary,
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
                      const SizedBox(height: 8),
                      Text(
                        _isUploadingPhoto ? 'Uploading...' : 'Tap to change',
                        style: const TextStyle(
                          color: AppColors.secondaryLabel,
                          fontSize: 13,
                        ),
                      ),
                      if (_uploadPhotoError != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppColors.errorBackground,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                CupertinoIcons.exclamationmark_triangle,
                                color: AppColors.error,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _uploadPhotoError!,
                                  style: const TextStyle(
                                    color: AppColors.error,
                                    fontSize: 11,
                                  ),
                                ),
                              ),
                              CupertinoButton(
                                padding: EdgeInsets.zero,
                                minSize: 0,
                                onPressed: () {
                                  setState(() {
                                    _uploadPhotoError = null;
                                  });
                                },
                                child: const Icon(
                                  CupertinoIcons.xmark_circle_fill,
                                  color: AppColors.error,
                                  size: 18,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                // Username editing section
                Container(
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Username',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      CupertinoTextField(
                        controller: _usernameController,
                        placeholder: _userNostrPubkey == null
                            ? 'Loading...'
                            : 'Enter username',
                        padding: const EdgeInsets.all(12),
                        enabled: _userNostrPubkey != null,
                        decoration: BoxDecoration(
                          color: _userNostrPubkey == null
                              ? AppColors.chipBackground
                              : AppColors.surface,
                          borderRadius: BorderRadius.circular(8),
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
                                  color: AppColors.secondaryLabel,
                                  fontSize: 14,
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
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _usernameAvailable!
                                      ? 'Username available'
                                      : (_usernameCheckError ??
                                            'Username taken'),
                                  style: TextStyle(
                                    color: _usernameAvailable!
                                        ? CupertinoColors.systemGreen
                                        : AppColors.error,
                                    fontSize: 14,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (_updateUsernameError != null)
                        Container(
                          padding: const EdgeInsets.all(12),
                          margin: const EdgeInsets.only(top: 8),
                          decoration: BoxDecoration(
                            color: AppColors.errorBackground,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              const Icon(
                                CupertinoIcons.exclamationmark_triangle,
                                color: AppColors.error,
                                size: 20,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  _updateUsernameError!,
                                  style: const TextStyle(
                                    color: AppColors.error,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                              CupertinoButton(
                                padding: EdgeInsets.zero,
                                minSize: 0,
                                onPressed: () {
                                  setState(() {
                                    _updateUsernameError = null;
                                  });
                                },
                                child: const Icon(
                                  CupertinoIcons.xmark_circle_fill,
                                  color: AppColors.error,
                                  size: 20,
                                ),
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 8),
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
                                    color: AppColors.secondaryLabel,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      CupertinoButton.filled(
                        onPressed:
                            (_userNostrPubkey != null &&
                                _usernameAvailable == true &&
                                !_isUpdatingUsername &&
                                _usernameController.text.trim() !=
                                    _userUsername)
                            ? _updateUsername
                            : null,
                        child: _isUpdatingUsername
                            ? const CupertinoActivityIndicator(
                                color: CupertinoColors.white,
                              )
                            : const Text('Update Username'),
                      ),
                      if (_userNostrPubkey != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Pubkey: ${_userNostrPubkey!.length > 20 ? "${_userNostrPubkey!.substring(0, 10)}...${_userNostrPubkey!.substring(_userNostrPubkey!.length - 10)}" : _userNostrPubkey!}',
                          style: const TextStyle(
                            color: AppColors.secondaryLabel,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Link Device section
                Container(
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 12),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'Link Another Device',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Transfer your account to another device or save a recovery link.',
                        style: TextStyle(
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 16),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        color: AppColors.primary,
                        borderRadius: BorderRadius.circular(8),
                        onPressed: _addNewDevice,
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              CupertinoIcons.device_phone_portrait,
                              size: 18,
                              color: CupertinoColors.white,
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Add New Device',
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: CupertinoColors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      CupertinoButton(
                        key: _saveRecoveryLinkButtonKey,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        color: AppColors.chipBackground,
                        borderRadius: BorderRadius.circular(8),
                        onPressed: _isGeneratingRecoveryLink
                            ? null
                            : _saveRecoveryLink,
                        child: _isGeneratingRecoveryLink
                            ? const CupertinoActivityIndicator()
                            : const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    CupertinoIcons.link,
                                    size: 18,
                                    color: AppColors.label,
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    'Save Recovery Link',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: AppColors.label,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // Danger Zone section
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.errorBackground,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: AppColors.error.withOpacity(0.3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Icon(
                            CupertinoIcons.exclamationmark_triangle_fill,
                            color: CupertinoColors.systemRed.resolveFrom(
                              context,
                            ),
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          const Text(
                            'Danger Zone',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color: AppColors.error,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'These actions are permanent and cannot be undone.',
                        style: TextStyle(
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 16),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        color: AppColors.error,
                        borderRadius: BorderRadius.circular(8),
                        onPressed: _isDeletingData
                            ? null
                            : _showDeleteConfirmation,
                        child: _isDeletingData
                            ? const CupertinoActivityIndicator(
                                color: CupertinoColors.white,
                              )
                            : const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    CupertinoIcons.trash,
                                    size: 18,
                                    color: CupertinoColors.white,
                                  ),
                                  SizedBox(width: 8),
                                  Text(
                                    'Delete All App Data',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      color: CupertinoColors.white,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirmation() {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Delete All App Data?'),
        content: const Text(
          'This will permanently delete:\n\n'
          '• All your messages and groups\n'
          '• Your encryption keys\n'
          '• Your local settings\n'
          '• Your Nostr profile data\n\n'
          'If you don\'t have a recovery link saved, you will lose access to your account forever.\n\n'
          'This action cannot be undone.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.of(context).pop(),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(context).pop();
              _showFinalConfirmation();
            },
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  void _showFinalConfirmation() {
    showCupertinoDialog(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Are you absolutely sure?'),
        content: const Text(
          'Type "DELETE" to confirm you want to permanently delete all your data.',
        ),
        actions: [
          CupertinoDialogAction(
            child: const Text('Cancel'),
            onPressed: () => Navigator.of(context).pop(),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () {
              Navigator.of(context).pop();
              _deleteAllData();
            },
            child: const Text('Delete Everything'),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteAllData() async {
    setState(() {
      _isDeletingData = true;
    });

    try {
      // Shutdown all services with NostrService instances first
      // to prevent auto-reconnect after database deletion
      FeedState? feedState;
      ProfileState? profileState;

      try {
        feedState = context.read<FeedState>();
        await feedState.shutdown();
      } catch (_) {}

      try {
        profileState = context.read<ProfileState>();
        await profileState.shutdown();
      } catch (_) {}

      final groupState = context.read<GroupState>();
      await groupState.deleteAllAppData();

      // Reinitialize all services so "New Account" works
      await groupState.reinitialize();
      await feedState?.reinitialize();
      await profileState?.reinitialize();

      // Navigate to onboarding screen
      if (mounted) {
        context.go('/');
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isDeletingData = false;
        });
        showCupertinoDialog(
          context: context,
          builder: (context) => CupertinoAlertDialog(
            title: const Text('Error'),
            content: Text('Failed to delete data: $e'),
            actions: [
              CupertinoDialogAction(
                child: const Text('OK'),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        );
      }
    }
  }
}
