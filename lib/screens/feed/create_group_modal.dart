import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'package:comunifi/state/group.dart';
import 'package:comunifi/l10n/app_localizations.dart';

/// Modal for creating a new group
/// Shows as a bottom sheet with form fields
class CreateGroupModal extends StatefulWidget {
  final VoidCallback? onCreated;

  const CreateGroupModal({super.key, this.onCreated});

  @override
  State<CreateGroupModal> createState() => _CreateGroupModalState();
}

class _CreateGroupModalState extends State<CreateGroupModal> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _aboutController = TextEditingController();
  Uint8List? _selectedPhotoBytes;
  bool _isCreating = false;
  bool _isUploadingPhoto = false;
  String? _error;
  final ImagePicker _imagePicker = ImagePicker();

  @override
  void dispose() {
    _nameController.dispose();
    _aboutController.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 400,
        maxHeight: 400,
        imageQuality: 85,
      );
      if (pickedFile == null) return;
      final bytes = await pickedFile.readAsBytes();
      setState(() => _selectedPhotoBytes = bytes);
    } catch (e) {
      setState(() => _error = 'Failed to pick image: $e');
    }
  }

  Future<void> _create() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Group name is required');
      return;
    }

    final groupState = context.read<GroupState>();
    if (!groupState.isConnected) {
      setState(() => _error = 'Not connected to relay');
      return;
    }

    setState(() {
      _isCreating = true;
      _error = null;
    });

    try {
      final about = _aboutController.text.trim();

      // 1. Create the group first (without picture)
      final newGroup = await groupState.createGroup(
        name,
        about: about.isEmpty ? null : about,
      );

      // 2. Set it as active so the user is navigated into the new group
      groupState.setActiveGroup(newGroup);

      // 3. Upload image to the group (unencrypted, but with group ID)
      String? pictureUrl;
      if (_selectedPhotoBytes != null) {
        // Small delay to let the relay process the kind 9000 (put-user) event
        // so membership is recognized before we try to upload with the group ID
        await Future.delayed(const Duration(milliseconds: 500));

        setState(() => _isUploadingPhoto = true);
        final groupIdHex = newGroup.id.bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        pictureUrl = await groupState.uploadGroupIcon(
          _selectedPhotoBytes!,
          'image/jpeg',
          groupIdHex,
        );
        setState(() => _isUploadingPhoto = false);

        // 4. Update group metadata with the picture URL
        await groupState.updateGroupMetadata(
          groupIdHex: groupIdHex,
          name: name,
          about: about.isEmpty ? null : about,
          picture: pictureUrl,
        );
      }

      widget.onCreated?.call();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _isCreating = false;
        _isUploadingPhoto = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.6,
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
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  Builder(
                    builder: (context) {
                      final localizations = AppLocalizations.of(context);
                      return Text(
                        localizations?.createGroup ?? 'Create Group',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                      );
                    },
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 0,
                    onPressed: _isCreating ? null : _create,
                    child: _isCreating
                        ? const CupertinoActivityIndicator()
                        : const Text(
                            'Create',
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
                  // Photo picker
                  Center(
                    child: GestureDetector(
                      onTap: _isCreating ? null : _pickPhoto,
                      child: Container(
                        width: 80,
                        height: 80,
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
                                CupertinoIcons.camera_fill,
                                size: 32,
                                color: CupertinoColors.systemGrey,
                              )
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Builder(
                    builder: (context) {
                      final localizations = AppLocalizations.of(context);
                      return Center(
                        child: Text(
                          _isUploadingPhoto
                              ? (localizations?.uploading ?? 'Uploading...')
                              : _selectedPhotoBytes != null
                              ? (localizations?.tapToChange ?? 'Tap to change')
                              : (localizations?.addPhotoOptional ?? 'Add photo (optional)'),
                          style: const TextStyle(
                            color: CupertinoColors.secondaryLabel,
                            fontSize: 12,
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 20),
                  Builder(
                    builder: (context) {
                      final localizations = AppLocalizations.of(context);
                      return CupertinoTextField(
                        controller: _nameController,
                        placeholder: localizations?.groupName ?? 'Group name',
                        padding: const EdgeInsets.all(12),
                        enabled: !_isCreating,
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  Builder(
                    builder: (context) {
                      final localizations = AppLocalizations.of(context);
                      return CupertinoTextField(
                        controller: _aboutController,
                        placeholder: localizations?.aboutOptional ?? 'About (optional)',
                        padding: const EdgeInsets.all(12),
                        maxLines: 2,
                        enabled: !_isCreating,
                      );
                    },
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
