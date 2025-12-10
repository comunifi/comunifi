import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import 'package:comunifi/state/group.dart';
import 'package:comunifi/services/whatsapp/whatsapp_import.dart';

/// Modal for importing WhatsApp chat exports into a group
/// Shows as a bottom sheet with file picker and progress indicator
class ImportWhatsAppModal extends StatefulWidget {
  final VoidCallback? onImported;

  const ImportWhatsAppModal({super.key, this.onImported});

  @override
  State<ImportWhatsAppModal> createState() => _ImportWhatsAppModalState();
}

class _ImportWhatsAppModalState extends State<ImportWhatsAppModal> {
  Uint8List? _selectedZipBytes;
  String? _selectedFileName;
  WhatsAppExportResult? _preview;
  bool _isLoadingPreview = false;
  bool _isImporting = false;
  double _importProgress = 0;
  int _importedCount = 0;
  int _totalCount = 0;
  String? _error;
  WhatsAppImportResult? _result;

  Future<void> _pickFile() async {
    try {
      setState(() {
        _error = null;
        _preview = null;
        _result = null;
      });

      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['zip'],
        withData: true,
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      if (file.bytes == null) {
        setState(() => _error = 'Failed to read file');
        return;
      }

      setState(() {
        _selectedZipBytes = file.bytes;
        _selectedFileName = file.name;
        _isLoadingPreview = true;
      });

      // Preview the export
      try {
        final groupState = context.read<GroupState>();
        final preview = await groupState.previewWhatsAppExport(file.bytes!);
        setState(() {
          _preview = preview;
          _isLoadingPreview = false;
        });
      } catch (e) {
        setState(() {
          _error = 'Failed to parse WhatsApp export: $e';
          _isLoadingPreview = false;
          _selectedZipBytes = null;
          _selectedFileName = null;
        });
      }
    } catch (e) {
      setState(() => _error = 'Failed to pick file: $e');
    }
  }

  Future<void> _import() async {
    if (_selectedZipBytes == null || _preview == null) return;

    setState(() {
      _isImporting = true;
      _error = null;
      _importProgress = 0;
      _importedCount = 0;
      _totalCount = _preview!.messages.length;
    });

    try {
      final groupState = context.read<GroupState>();
      final result = await groupState.importWhatsAppChat(
        _selectedZipBytes!,
        onProgress: (current, total) {
          setState(() {
            _importedCount = current;
            _totalCount = total;
            _importProgress = current / total;
          });
        },
      );

      setState(() {
        _result = result;
        _isImporting = false;
      });

      // Call callback on success
      if (result.isSuccess || result.hasPartialFailure) {
        widget.onImported?.call();
      }
    } catch (e) {
      setState(() {
        _error = 'Import failed: $e';
        _isImporting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: CupertinoColors.systemBackground.resolveFrom(context),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Handle bar
            Container(
              margin: const EdgeInsets.only(top: 8),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: CupertinoColors.systemGrey3.resolveFrom(context),
                borderRadius: BorderRadius.circular(2),
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  CupertinoButton(
                    padding: EdgeInsets.zero,
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const Expanded(
                    child: Text(
                      'Import WhatsApp Chat',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  // Spacer for symmetry
                  const SizedBox(width: 60),
                ],
              ),
            ),

            Container(
              height: 0.5,
              color: CupertinoColors.separator.resolveFrom(context),
            ),

            // Content
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Instructions
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: CupertinoColors.systemGrey6.resolveFrom(context),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Icon(
                                CupertinoIcons.info_circle,
                                size: 18,
                                color: CupertinoColors.systemBlue.resolveFrom(
                                  context,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                'How to export from WhatsApp',
                                style: TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: CupertinoColors.label.resolveFrom(
                                    context,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '1. Open the WhatsApp chat\n'
                            '2. Tap the group name at the top\n'
                            '3. Scroll down and tap "Export Chat"\n'
                            '4. Choose "Attach Media" for photos\n'
                            '5. Save the .zip file',
                            style: TextStyle(
                              fontSize: 13,
                              color: CupertinoColors.secondaryLabel.resolveFrom(
                                context,
                              ),
                              height: 1.5,
                            ),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // File picker button
                    if (!_isImporting && _result == null)
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        color: CupertinoColors.systemBlue.resolveFrom(context),
                        borderRadius: BorderRadius.circular(10),
                        onPressed: _isLoadingPreview ? null : _pickFile,
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              CupertinoIcons.folder,
                              size: 20,
                              color: CupertinoColors.white,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              _selectedFileName ??
                                  'Select WhatsApp Export (.zip)',
                              style: const TextStyle(
                                color: CupertinoColors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),

                    // Loading preview indicator
                    if (_isLoadingPreview) ...[
                      const SizedBox(height: 20),
                      const Center(child: CupertinoActivityIndicator()),
                      const SizedBox(height: 8),
                      Text(
                        'Parsing WhatsApp export...',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: CupertinoColors.secondaryLabel.resolveFrom(
                            context,
                          ),
                        ),
                      ),
                    ],

                    // Preview
                    if (_preview != null &&
                        !_isImporting &&
                        _result == null) ...[
                      const SizedBox(height: 20),
                      _buildPreview(),
                      const SizedBox(height: 20),
                      CupertinoButton(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        color: CupertinoColors.systemGreen.resolveFrom(context),
                        borderRadius: BorderRadius.circular(10),
                        onPressed: _import,
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              CupertinoIcons.arrow_down_doc,
                              size: 20,
                              color: CupertinoColors.white,
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Import Messages',
                              style: TextStyle(
                                color: CupertinoColors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    // Import progress
                    if (_isImporting) ...[
                      const SizedBox(height: 20),
                      _buildProgressIndicator(),
                    ],

                    // Result
                    if (_result != null) ...[
                      const SizedBox(height: 20),
                      _buildResult(),
                    ],

                    // Error
                    if (_error != null) ...[
                      const SizedBox(height: 16),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: CupertinoColors.systemRed.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              CupertinoIcons.exclamationmark_circle,
                              color: CupertinoColors.systemRed.resolveFrom(
                                context,
                              ),
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _error!,
                                style: TextStyle(
                                  color: CupertinoColors.systemRed.resolveFrom(
                                    context,
                                  ),
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

                    const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreview() {
    final preview = _preview!;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Export Preview',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 12),
          _buildPreviewRow(
            icon: CupertinoIcons.chat_bubble_2,
            label: 'Messages',
            value: '${preview.messages.length}',
          ),
          const SizedBox(height: 8),
          _buildPreviewRow(
            icon: CupertinoIcons.person_2,
            label: 'Participants',
            value: '${preview.authors.length}',
          ),
          const SizedBox(height: 12),
          Text(
            'Participants:',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: preview.authors.map((author) {
              final count = preview.messageCountByAuthor[author] ?? 0;
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 5,
                ),
                decoration: BoxDecoration(
                  color: CupertinoColors.systemGrey5.resolveFrom(context),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Text(
                  '$author ($count)',
                  style: TextStyle(
                    fontSize: 12,
                    color: CupertinoColors.label.resolveFrom(context),
                  ),
                ),
              );
            }).toList(),
          ),
          if (preview.messages.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Date range:',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: CupertinoColors.secondaryLabel.resolveFrom(context),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${_formatDate(preview.messages.first.timestamp)} - ${_formatDate(preview.messages.last.timestamp)}',
              style: TextStyle(
                fontSize: 13,
                color: CupertinoColors.label.resolveFrom(context),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPreviewRow({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Icon(
          icon,
          size: 16,
          color: CupertinoColors.systemGrey.resolveFrom(context),
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            color: CupertinoColors.secondaryLabel.resolveFrom(context),
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: CupertinoColors.label.resolveFrom(context),
          ),
        ),
      ],
    );
  }

  Widget _buildProgressIndicator() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: CupertinoColors.systemGrey6.resolveFrom(context),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          const CupertinoActivityIndicator(),
          const SizedBox(height: 12),
          Text(
            'Importing messages...',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$_importedCount of $_totalCount',
            style: TextStyle(
              fontSize: 13,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: Stack(
              children: [
                Container(
                  height: 8,
                  decoration: BoxDecoration(
                    color: CupertinoColors.systemGrey4.resolveFrom(context),
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: _importProgress,
                  child: Container(
                    height: 8,
                    decoration: BoxDecoration(
                      color: CupertinoColors.systemGreen.resolveFrom(context),
                      borderRadius: BorderRadius.circular(4),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResult() {
    final result = _result!;
    final isSuccess = result.isSuccess;
    final color = isSuccess
        ? CupertinoColors.systemGreen
        : CupertinoColors.systemOrange;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(
            isSuccess
                ? CupertinoIcons.checkmark_circle_fill
                : CupertinoIcons.exclamationmark_circle_fill,
            size: 48,
            color: color.resolveFrom(context),
          ),
          const SizedBox(height: 12),
          Text(
            isSuccess ? 'Import Complete!' : 'Import Completed with Errors',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: CupertinoColors.label.resolveFrom(context),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '${result.importedCount} messages imported',
            style: TextStyle(
              fontSize: 15,
              color: CupertinoColors.secondaryLabel.resolveFrom(context),
            ),
          ),
          if (result.failedCount > 0) ...[
            const SizedBox(height: 4),
            Text(
              '${result.failedCount} messages failed',
              style: TextStyle(
                fontSize: 13,
                color: CupertinoColors.systemOrange.resolveFrom(context),
              ),
            ),
          ],
          const SizedBox(height: 16),
          CupertinoButton(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
            color: CupertinoColors.systemBlue.resolveFrom(context),
            borderRadius: BorderRadius.circular(8),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              'Done',
              style: TextStyle(
                color: CupertinoColors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }
}
