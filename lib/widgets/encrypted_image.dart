import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:provider/provider.dart';

import 'package:comunifi/models/nostr_event.dart';
import 'package:comunifi/services/media/encrypted_media.dart';
import 'package:comunifi/state/group.dart';

/// Widget for displaying encrypted images
///
/// Handles downloading, decrypting, caching, and displaying encrypted images.
/// Falls back to regular network image for non-encrypted images.
class EncryptedImage extends StatefulWidget {
  final EventImageInfo imageInfo;
  final BoxFit fit;
  final double? maxWidth;
  final double? maxHeight;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;
  final Widget? loadingWidget;

  const EncryptedImage({
    super.key,
    required this.imageInfo,
    this.fit = BoxFit.contain,
    this.maxWidth,
    this.maxHeight,
    this.errorBuilder,
    this.loadingWidget,
  });

  @override
  State<EncryptedImage> createState() => _EncryptedImageState();
}

class _EncryptedImageState extends State<EncryptedImage> {
  final EncryptedMediaService _encryptedMediaService = EncryptedMediaService();

  String? _localPath;
  bool _isLoading = true;
  Object? _error;
  StackTrace? _stackTrace;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(EncryptedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reload if image info changed
    if (oldWidget.imageInfo.url != widget.imageInfo.url ||
        oldWidget.imageInfo.sha256 != widget.imageInfo.sha256) {
      _loadImage();
    }
  }

  Future<void> _loadImage() async {
    // Non-encrypted images use regular network loading
    if (!widget.imageInfo.isEncrypted) {
      setState(() {
        _isLoading = false;
        _localPath = null;
        _error = null;
      });
      return;
    }

    // Encrypted image - need to decrypt and cache
    setState(() {
      _isLoading = true;
      _error = null;
      _localPath = null;
    });

    try {
      // Get the active MLS group for decryption
      final groupState = context.read<GroupState>();
      final activeGroup = groupState.activeGroup;

      if (activeGroup == null) {
        throw Exception('No active group for decryption');
      }

      // Get sha256 - required for encrypted images
      final sha256 = widget.imageInfo.sha256;
      if (sha256 == null || sha256.isEmpty) {
        throw Exception('SHA-256 hash required for encrypted image');
      }

      // Decrypt and cache
      final localPath = await _encryptedMediaService.decryptAndCacheMedia(
        url: widget.imageInfo.url,
        sha256: sha256,
        group: activeGroup,
      );

      if (mounted) {
        setState(() {
          _localPath = localPath;
          _isLoading = false;
        });
      }
    } catch (e, st) {
      if (mounted) {
        setState(() {
          _error = e;
          _stackTrace = st;
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Loading state
    if (_isLoading) {
      return _buildContainer(
        child: widget.loadingWidget ??
            const Center(child: CupertinoActivityIndicator()),
      );
    }

    // Error state
    if (_error != null) {
      if (widget.errorBuilder != null) {
        return widget.errorBuilder!(context, _error!, _stackTrace);
      }
      return _buildContainer(
        child: const Center(
          child: Icon(
            CupertinoIcons.exclamationmark_triangle,
            color: CupertinoColors.systemRed,
          ),
        ),
      );
    }

    // Non-encrypted - use regular network image
    if (!widget.imageInfo.isEncrypted) {
      return Image.network(
        widget.imageInfo.url,
        fit: widget.fit,
        loadingBuilder: (context, child, loadingProgress) {
          if (loadingProgress == null) return child;
          return _buildContainer(
            child: widget.loadingWidget ??
                const Center(child: CupertinoActivityIndicator()),
          );
        },
        errorBuilder: (context, error, stackTrace) {
          if (widget.errorBuilder != null) {
            return widget.errorBuilder!(context, error, stackTrace);
          }
          return _buildContainer(
            child: const Center(
              child: Icon(
                CupertinoIcons.photo,
                color: CupertinoColors.systemGrey,
              ),
            ),
          );
        },
      );
    }

    // Encrypted - use local file
    if (_localPath != null) {
      return Image.file(
        File(_localPath!),
        fit: widget.fit,
        errorBuilder: (context, error, stackTrace) {
          if (widget.errorBuilder != null) {
            return widget.errorBuilder!(context, error, stackTrace);
          }
          return _buildContainer(
            child: const Center(
              child: Icon(
                CupertinoIcons.photo,
                color: CupertinoColors.systemGrey,
              ),
            ),
          );
        },
      );
    }

    // Fallback error
    return _buildContainer(
      child: const Center(
        child: Icon(
          CupertinoIcons.photo,
          color: CupertinoColors.systemGrey,
        ),
      ),
    );
  }

  Widget _buildContainer({required Widget child}) {
    return SizedBox(
      width: widget.maxWidth,
      height: widget.maxHeight ?? 200,
      child: child,
    );
  }
}

/// Widget to display a list of images (encrypted or not)
class EventImages extends StatelessWidget {
  final List<EventImageInfo> images;

  /// Fixed max width for images
  static const double maxImageWidth = 500;

  /// Fixed max height for images in feed
  static const double maxImageHeight = 400;

  const EventImages({
    super.key,
    required this.images,
  });

  @override
  Widget build(BuildContext context) {
    if (images.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 8.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: images.map((imageInfo) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: maxImageWidth,
                maxHeight: maxImageHeight,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12.0),
                child: GestureDetector(
                  onTap: () => _showFullImage(context, imageInfo),
                  child: Container(
                    decoration: BoxDecoration(
                      color: CupertinoColors.systemGrey5,
                      borderRadius: BorderRadius.circular(12.0),
                    ),
                    child: EncryptedImage(
                      imageInfo: imageInfo,
                      fit: BoxFit.contain,
                      maxWidth: maxImageWidth,
                      maxHeight: maxImageHeight,
                      loadingWidget: const SizedBox(
                        width: maxImageWidth,
                        height: maxImageHeight,
                        child: Center(child: CupertinoActivityIndicator()),
                      ),
                      errorBuilder: (context, error, stackTrace) {
                        return const SizedBox(
                          width: maxImageWidth,
                          height: 100,
                          child: Center(
                            child: Icon(
                              CupertinoIcons.photo,
                              color: CupertinoColors.systemGrey,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  void _showFullImage(BuildContext context, EventImageInfo imageInfo) {
    Navigator.of(context).push(
      CupertinoPageRoute(
        fullscreenDialog: true,
        builder: (context) => _FullScreenImageViewer(imageInfo: imageInfo),
      ),
    );
  }
}

/// Full screen viewer for encrypted images
class _FullScreenImageViewer extends StatelessWidget {
  final EventImageInfo imageInfo;

  const _FullScreenImageViewer({required this.imageInfo});

  @override
  Widget build(BuildContext context) {
    return CupertinoPageScaffold(
      navigationBar: CupertinoNavigationBar(
        backgroundColor: CupertinoColors.black.withOpacity(0.8),
        leading: CupertinoButton(
          padding: EdgeInsets.zero,
          onPressed: () => Navigator.of(context).pop(),
          child: const Icon(
            CupertinoIcons.xmark,
            color: CupertinoColors.white,
          ),
        ),
      ),
      backgroundColor: CupertinoColors.black,
      child: SafeArea(
        child: Center(
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 4.0,
            child: EncryptedImage(
              imageInfo: imageInfo,
              fit: BoxFit.contain,
              loadingWidget: const CupertinoActivityIndicator(
                color: CupertinoColors.white,
              ),
              errorBuilder: (context, error, stackTrace) {
                return const Center(
                  child: Icon(
                    CupertinoIcons.photo,
                    color: CupertinoColors.systemGrey,
                    size: 48,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

