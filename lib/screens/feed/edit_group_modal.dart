import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:image_picker/image_picker.dart';
import 'package:provider/provider.dart';

import 'package:comunifi/state/group.dart';

/// Modal for editing group metadata (name, about, picture, cover)
/// Shows as a bottom sheet with form fields
class EditGroupModal extends StatefulWidget {
  final GroupAnnouncement announcement;
  final VoidCallback? onSaved;

  const EditGroupModal({super.key, required this.announcement, this.onSaved});

  @override
  State<EditGroupModal> createState() => _EditGroupModalState();
}

class _EditGroupModalState extends State<EditGroupModal> {
  late TextEditingController _nameController;
  late TextEditingController _aboutController;
  String? _pictureUrl;
  Uint8List? _selectedPhotoBytes;
  String? _coverUrl;
  Uint8List? _selectedCoverBytes;
  bool _isSaving = false;
  bool _isUploadingPhoto = false;
  bool _isUploadingCover = false;
  String? _error;
  final ImagePicker _imagePicker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.announcement.name ?? '',
    );
    _aboutController = TextEditingController(
      text: widget.announcement.about ?? '',
    );
    _pictureUrl = widget.announcement.picture;
    _coverUrl = widget.announcement.cover;
  }

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

  Future<void> _pickCover() async {
    try {
      final XFile? pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        maxWidth: 1920,
        maxHeight: 600,
        imageQuality: 85,
      );
      if (pickedFile == null) return;
      final bytes = await pickedFile.readAsBytes();
      setState(() => _selectedCoverBytes = bytes);
    } catch (e) {
      setState(() => _error = 'Failed to pick cover image: $e');
    }
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Group name cannot be empty');
      return;
    }

    final groupIdHex = widget.announcement.mlsGroupId;
    if (groupIdHex == null) {
      setState(() => _error = 'Invalid group ID');
      return;
    }

    setState(() {
      _isSaving = true;
      _error = null;
    });

    try {
      final groupState = context.read<GroupState>();
      String? newPictureUrl = _pictureUrl;
      String? newCoverUrl = _coverUrl;

      // Upload profile picture if changed
      if (_selectedPhotoBytes != null) {
        setState(() => _isUploadingPhoto = true);
        newPictureUrl = await groupState.uploadMediaToOwnGroup(
          _selectedPhotoBytes!,
          'image/jpeg',
        );
        setState(() => _isUploadingPhoto = false);
      }

      // Upload cover photo if changed
      if (_selectedCoverBytes != null) {
        setState(() => _isUploadingCover = true);
        newCoverUrl = await groupState.uploadMediaToOwnGroup(
          _selectedCoverBytes!,
          'image/jpeg',
        );
        setState(() => _isUploadingCover = false);
      }

      final about = _aboutController.text.trim();
      await groupState.updateGroupMetadata(
        groupIdHex: groupIdHex,
        name: name,
        about: about.isEmpty ? null : about,
        picture: newPictureUrl,
        cover: newCoverUrl,
      );

      widget.onSaved?.call();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _isSaving = false;
        _isUploadingPhoto = false;
        _isUploadingCover = false;
        _error = e.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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
            // Drag handle
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: CupertinoColors.systemGrey4,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Header with Cancel/Title/Save
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
                  const Text(
                    'Edit Group',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    minSize: 0,
                    onPressed: _isSaving ? null : _save,
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
            // Form content
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
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
                  // Photo picker
                  Center(
                    child: GestureDetector(
                      onTap: _isSaving ? null : _pickPhoto,
                      child: Stack(
                        children: [
                          Container(
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
                                  : _pictureUrl != null
                                  ? DecorationImage(
                                      image: NetworkImage(_pictureUrl!),
                                      fit: BoxFit.cover,
                                    )
                                  : null,
                            ),
                            child:
                                (_selectedPhotoBytes == null &&
                                    _pictureUrl == null)
                                ? const Icon(
                                    CupertinoIcons.person_2_fill,
                                    size: 32,
                                    color: CupertinoColors.systemGrey,
                                  )
                                : null,
                          ),
                          // Upload overlay
                          if (_isUploadingPhoto)
                            Container(
                              width: 80,
                              height: 80,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: CupertinoColors.black.withOpacity(0.5),
                              ),
                              child: const CupertinoActivityIndicator(
                                color: CupertinoColors.white,
                              ),
                            ),
                          // Camera badge
                          if (!_isSaving)
                            Positioned(
                              bottom: 0,
                              right: 0,
                              child: Container(
                                width: 28,
                                height: 28,
                                decoration: const BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: CupertinoColors.activeBlue,
                                ),
                                child: const Icon(
                                  CupertinoIcons.camera_fill,
                                  size: 14,
                                  color: CupertinoColors.white,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Text(
                      _isUploadingPhoto
                          ? 'Uploading...'
                          : 'Tap to change photo',
                      style: const TextStyle(
                        color: CupertinoColors.secondaryLabel,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Cover photo picker
                  const Text(
                    'Cover Photo',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: CupertinoColors.label,
                    ),
                  ),
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: _isSaving ? null : _pickCover,
                    child: Stack(
                      children: [
                        Container(
                          width: double.infinity,
                          height: 120,
                          decoration: BoxDecoration(
                            color: CupertinoColors.systemGrey5,
                            borderRadius: BorderRadius.circular(12),
                            image: _selectedCoverBytes != null
                                ? DecorationImage(
                                    image: MemoryImage(_selectedCoverBytes!),
                                    fit: BoxFit.cover,
                                  )
                                : _coverUrl != null
                                ? DecorationImage(
                                    image: NetworkImage(_coverUrl!),
                                    fit: BoxFit.cover,
                                  )
                                : null,
                          ),
                          child:
                              (_selectedCoverBytes == null && _coverUrl == null)
                              ? Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: const [
                                    Icon(
                                      CupertinoIcons.photo,
                                      size: 32,
                                      color: CupertinoColors.systemGrey,
                                    ),
                                    SizedBox(height: 4),
                                    Text(
                                      'Add cover photo',
                                      style: TextStyle(
                                        color: CupertinoColors.systemGrey,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                )
                              : null,
                        ),
                        // Upload overlay
                        if (_isUploadingCover)
                          Container(
                            width: double.infinity,
                            height: 120,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                              color: CupertinoColors.black.withOpacity(0.5),
                            ),
                            child: const CupertinoActivityIndicator(
                              color: CupertinoColors.white,
                            ),
                          ),
                        // Edit badge
                        if (!_isSaving &&
                            (_selectedCoverBytes != null || _coverUrl != null))
                          Positioned(
                            bottom: 8,
                            right: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: CupertinoColors.black.withOpacity(0.6),
                                borderRadius: BorderRadius.circular(16),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: const [
                                  Icon(
                                    CupertinoIcons.camera_fill,
                                    size: 12,
                                    color: CupertinoColors.white,
                                  ),
                                  SizedBox(width: 4),
                                  Text(
                                    'Change',
                                    style: TextStyle(
                                      color: CupertinoColors.white,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Text(
                      _isUploadingCover
                          ? 'Uploading cover...'
                          : 'Recommended: 1920×600 pixels',
                      style: const TextStyle(
                        color: CupertinoColors.secondaryLabel,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Name field
                  CupertinoTextField(
                    controller: _nameController,
                    placeholder: 'Group name',
                    padding: const EdgeInsets.all(12),
                    enabled: !_isSaving,
                  ),
                  const SizedBox(height: 12),
                  // About field
                  CupertinoTextField(
                    controller: _aboutController,
                    placeholder: 'About (optional)',
                    padding: const EdgeInsets.all(12),
                    maxLines: 2,
                    enabled: !_isSaving,
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

/// Shows the edit group modal as a bottom sheet
/// Returns true if changes were saved, false otherwise
Future<void> showEditGroupModal(
  BuildContext context,
  GroupAnnouncement announcement, {
  VoidCallback? onSaved,
}) {
  return showCupertinoModalPopup<void>(
    context: context,
    builder: (context) =>
        EditGroupModal(announcement: announcement, onSaved: onSaved),
  );
}
