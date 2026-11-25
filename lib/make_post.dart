import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:heic_to_png_jpg/heic_to_png_jpg.dart';
import 'package:web/web.dart' as web;

const int _maxImageDimension = 1080;
const double _imageQuality = 0.85;
const int _maxUploadBytes = 5 * 1024 * 1024;

class MakePostPage extends StatefulWidget {
  const MakePostPage({super.key});

  @override
  State<MakePostPage> createState() => _MakePostPageState();
}

class _MakePostPageState extends State<MakePostPage> {
  final TextEditingController _textController = TextEditingController();
  final TextEditingController _captionController = TextEditingController();

  bool _includeImage = false;
  bool _isProcessingImage = false;
  bool _isPublishing = false;

  String? _selectedFileName;
  String _processedMimeType = 'image/webp';
  Uint8List? _processedImageBytes;
  String? _errorMessage;

  @override
  void dispose() {
    _textController.dispose();
    _captionController.dispose();
    super.dispose();
  }

  Future<({String name, Uint8List bytes})?> _pickImageFromBrowser() async {
    final web.HTMLInputElement input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = 'image/*,.heic,.heif';

    final Completer<({String name, Uint8List bytes})?> completer =
    Completer<({String name, Uint8List bytes})?>();
    bool settled = false;

    late final JSFunction onChangeFn;
    late final JSFunction onCancelFn;

    void cleanup() {
      input.removeEventListener('change', onChangeFn);
      input.removeEventListener('cancel', onCancelFn);
    }

    onChangeFn = ((web.Event _) {
      if (settled) return;
      settled = true;
      cleanup();

      final web.FileList? files = input.files;
      if (files == null || files.length == 0) {
        if (!completer.isCompleted) completer.complete(null);
        return;
      }

      final web.File? file = files.item(0);
      if (file == null) {
        if (!completer.isCompleted) completer.complete(null);
        return;
      }

      file.arrayBuffer().toDart.then((JSArrayBuffer buffer) {
        if (!completer.isCompleted) {
          completer.complete((
          name: file.name,
          bytes: buffer.toDart.asUint8List(),
          ));
        }
      }).catchError((Object err, StackTrace stack) {
        if (!completer.isCompleted) {
          completer.completeError(err, stack);
        }
      });
    }).toJS;

    onCancelFn = ((web.Event _) {
      if (settled) return;
      settled = true;
      cleanup();
      if (!completer.isCompleted) completer.complete(null);
    }).toJS;

    input.addEventListener('change', onChangeFn);
    input.addEventListener('cancel', onCancelFn);
    input.click();

    return completer.future.timeout(
      const Duration(minutes: 5),
      onTimeout: () {
        cleanup();
        return null;
      },
    );
  }

  Future<void> _pickAndProcessImage() async {
    setState(() {
      _errorMessage = null;
      _isProcessingImage = true;
    });

    try {
      final ({String name, Uint8List bytes})? picked =
      await _pickImageFromBrowser();

      if (picked == null) {
        if (!mounted) return;
        setState(() {
          _isProcessingImage = false;
        });
        return;
      }

      if (picked.bytes.isEmpty) {
        throw Exception('Could not read image data.');
      }

      final ({Uint8List bytes, String mimeType}) processed =
      await _processImage(
        rawBytes: picked.bytes,
        fileName: picked.name,
      );

      if (processed.bytes.length > _maxUploadBytes) {
        throw Exception(
          'Processed image exceeds the 5 MB upload limit.',
        );
      }

      if (!mounted) return;
      setState(() {
        _processedImageBytes = processed.bytes;
        _processedMimeType = processed.mimeType;
        _selectedFileName = _buildOutputFileName(
          picked.name,
          mimeType: processed.mimeType,
        );
        _isProcessingImage = false;
      });
    } catch (e, stack) {
      debugPrint('Image processing error: $e\n$stack');
      if (!mounted) return;
      setState(() {
        _processedImageBytes = null;
        _selectedFileName = null;
        _processedMimeType = 'image/webp';
        _isProcessingImage = false;
        _errorMessage =
        'Could not process image: ${e.toString().replaceFirst('Exception: ', '')}';
      });
    }
  }

  String _extensionForMimeType(String mimeType) {
    if (mimeType == 'image/jpeg') return 'jpg';
    return 'webp';
  }

  String _labelForMimeType(String mimeType) {
    if (mimeType == 'image/jpeg') return 'JPEG';
    return 'WebP';
  }

  String _buildOutputFileName(
      String originalName, {
        required String mimeType,
      }) {
    final int dotIndex = originalName.lastIndexOf('.');
    final String baseName = dotIndex > 0
        ? originalName.substring(0, dotIndex)
        : originalName;
    final String sanitized = baseName
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final String safeBase = sanitized.isEmpty ? 'image' : sanitized;
    final String ext = _extensionForMimeType(mimeType);
    return '${DateTime.now().millisecondsSinceEpoch}_$safeBase.$ext';
  }

  bool _isHeicFile(Uint8List bytes, String? fileName) {
    final String lower = (fileName ?? '').toLowerCase();
    if (lower.endsWith('.heic') || lower.endsWith('.heif')) {
      return true;
    }

    if (bytes.length >= 12 &&
        bytes[4] == 0x66 && // 'f'
        bytes[5] == 0x74 && // 't'
        bytes[6] == 0x79 && // 'y'
        bytes[7] == 0x70) {
      // 'p'
      final String brand =
      String.fromCharCodes(bytes.sublist(8, 12)).toLowerCase();
      return brand == 'heic' ||
          brand == 'heix' ||
          brand == 'hevc' ||
          brand == 'hevx' ||
          brand == 'mif1' ||
          brand == 'msf1';
    }

    return false;
  }

  Future<({Uint8List bytes, String mimeType})> _processImage({
    required Uint8List rawBytes,
    String? fileName,
  }) async {
    Uint8List imageBytesForCanvas = rawBytes;

    if (_isHeicFile(rawBytes, fileName)) {
      final Uint8List convertedBytes = await _convertHeicToBytes(rawBytes);
      if (convertedBytes.isEmpty || _isHeicFile(convertedBytes, null)) {
        throw Exception(
          'Could not convert HEIC image in browser. Please select a JPG, PNG, or WebP photo.',
        );
      }
      imageBytesForCanvas = convertedBytes;
    }

    return _resizeAndEncodeCanvas(imageBytesForCanvas);
  }

  Future<Uint8List> _convertHeicToBytes(Uint8List rawBytes) async {
    return HeicConverter.convertToJPG(
      heicData: rawBytes,
      quality: 90,
      maxWidth: _maxImageDimension,
      maxHeight: _maxImageDimension,
    );
  }

  Future<({Uint8List bytes, String mimeType})> _resizeAndEncodeCanvas(
      Uint8List bytes,
      ) async {
    final web.Blob blob = web.Blob(<JSAny>[bytes.toJS].toJS);
    final String objectUrl = web.URL.createObjectURL(blob);

    final web.HTMLImageElement img = web.HTMLImageElement();
    final Completer<void> loadCompleter = Completer<void>();

    img.onLoad.listen((_) {
      if (!loadCompleter.isCompleted) {
        loadCompleter.complete();
      }
    });
    img.onError.listen((_) {
      if (!loadCompleter.isCompleted) {
        loadCompleter.completeError(
          Exception('Failed to decode selected image.'),
        );
      }
    });

    img.src = objectUrl;

    try {
      await loadCompleter.future.timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw Exception('Timed out while decoding image.'),
      );

      final int naturalW = img.naturalWidth;
      final int naturalH = img.naturalHeight;
      if (naturalW <= 0 || naturalH <= 0) {
        throw Exception('Invalid image dimensions.');
      }

      final double scale = math.min(
        1.0,
        math.min(
          _maxImageDimension / naturalW,
          _maxImageDimension / naturalH,
        ),
      );
      final int targetW = math.max(1, (naturalW * scale).round());
      final int targetH = math.max(1, (naturalH * scale).round());

      final web.HTMLCanvasElement canvas = web.HTMLCanvasElement()
        ..width = targetW
        ..height = targetH;

      final web.CanvasRenderingContext2D? ctx =
      canvas.getContext('2d') as web.CanvasRenderingContext2D?;
      if (ctx == null) {
        throw Exception('Could not initialize image canvas.');
      }

      ctx.imageSmoothingEnabled = true;
      ctx.imageSmoothingQuality = 'high';
      ctx.drawImage(img, 0, 0, targetW, targetH);

      String dataUrl = canvas.toDataURL('image/webp', _imageQuality.toJS);
      String mimeType = 'image/webp';

      if (!dataUrl.startsWith('data:image/webp,')) {
        dataUrl = canvas.toDataURL('image/jpeg', _imageQuality.toJS);
        mimeType = 'image/jpeg';
      }

      final int commaIndex = dataUrl.indexOf(',');
      if (commaIndex == -1 || !dataUrl.startsWith('data:$mimeType;base64,')) {
        throw Exception('Failed to encode resized image.');
      }

      final String prefix = 'data:$mimeType;base64,';
      final String base64Payload = dataUrl.substring(commaIndex + 1);
      final web.Response dataResponse = await web.window
          .fetch('$prefix$base64Payload'.toJS)
          .toDart;
      final JSArrayBuffer arrayBuffer = await dataResponse.arrayBuffer().toDart;
      return (
      bytes: arrayBuffer.toDart.asUint8List(),
      mimeType: mimeType,
      );
    } finally {
      web.URL.revokeObjectURL(objectUrl);
    }
  }

  Future<void> _publishPost() async {
    final String textContent = _textController.text.trim();
    final String captionContent = _captionController.text.trim();

    if (!_includeImage && textContent.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter some text before publishing.';
      });
      return;
    }

    if (_includeImage && _processedImageBytes == null) {
      setState(() {
        _errorMessage = 'Please select an image first.';
      });
      return;
    }

    setState(() {
      _isPublishing = true;
      _errorMessage = null;
    });

    try {
      String? imageUrl;
      String? storagePath;

      if (_includeImage && _processedImageBytes != null) {
        final String fallbackExt = _extensionForMimeType(_processedMimeType);
        final String fileName = _selectedFileName ??
            '${DateTime.now().millisecondsSinceEpoch}_upload.$fallbackExt';
        storagePath = 'post_images/$fileName';

        final Reference ref = FirebaseStorage.instance.ref().child(storagePath);
        final SettableMetadata metadata = SettableMetadata(
          contentType: _processedMimeType,
        );

        await ref.putData(_processedImageBytes!, metadata);
        imageUrl = await ref.getDownloadURL();
      }

      final Map<String, dynamic> postData = <String, dynamic>{
        'type': _includeImage ? 'image' : 'text',
        'text': _includeImage ? captionContent : textContent,
        'imageUrl': imageUrl,
        'storagePath': storagePath,
        'timestamp': FieldValue.serverTimestamp(),
        'viewTimeMs': 0,
      };

      await FirebaseFirestore.instance.collection('posts').add(postData);

      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isPublishing = false;
        _errorMessage =
        'Error publishing post: ${e.toString().replaceFirst('Exception: ', '')}';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colorScheme = theme.colorScheme;
    final String formatLabel = _labelForMimeType(_processedMimeType);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      Text(
                        'New Post',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _isPublishing
                            ? null
                            : () => Navigator.of(context).pop(false),
                        icon: const Icon(Icons.close, size: 20),
                        label: const Text(
                          'Cancel',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  SegmentedButton<bool>(
                    style: SegmentedButton.styleFrom(
                      textStyle: const TextStyle(
                        fontFamily: 'CormorantGaramond',
                        fontSize: 17,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 12,
                      ),
                    ),
                    segments: const <ButtonSegment<bool>>[
                      ButtonSegment<bool>(
                        value: false,
                        label: Text('Text Post'),
                        icon: Icon(Icons.notes),
                      ),
                      ButtonSegment<bool>(
                        value: true,
                        label: Text('Image Post'),
                        icon: Icon(Icons.image_outlined),
                      ),
                    ],
                    selected: <bool>{_includeImage},
                    onSelectionChanged: _isPublishing
                        ? null
                        : (Set<bool> selection) {
                      setState(() {
                        _includeImage = selection.first;
                        _errorMessage = null;
                      });
                    },
                  ),
                  const SizedBox(height: 20),
                  if (!_includeImage) ...<Widget>[
                    TextField(
                      controller: _textController,
                      maxLines: 6,
                      enabled: !_isPublishing,
                      decoration: const InputDecoration(
                        hintText: 'What is trending on your mind?',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ] else ...<Widget>[
                    OutlinedButton.icon(
                      onPressed: (_isPublishing || _isProcessingImage)
                          ? null
                          : _pickAndProcessImage,
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 14,
                        ),
                      ),
                      icon: _isProcessingImage
                          ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                          : const Icon(Icons.upload_file, size: 22),
                      label: Text(
                        _isProcessingImage
                            ? 'Resizing & Compressing...'
                            : (_processedImageBytes == null
                            ? 'Choose Photo (HEIC, JPG, PNG, WebP)'
                            : 'Replace Photo'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_processedImageBytes != null) ...<Widget>[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 420),
                          child: Image.memory(
                            _processedImageBytes!,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Ready as $formatLabel (${(_processedImageBytes!.length / 1024).toStringAsFixed(0)} KB, max 1080px)',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    TextField(
                      controller: _captionController,
                      maxLines: 3,
                      enabled: !_isPublishing,
                      decoration: const InputDecoration(
                        hintText: 'Optional caption...',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  if (_errorMessage != null) ...<Widget>[
                    const SizedBox(height: 16),
                    Text(
                      _errorMessage!,
                      style: TextStyle(
                        color: colorScheme.error,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  FilledButton(
                    onPressed: (_isPublishing || _isProcessingImage)
                        ? null
                        : _publishPost,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: _isPublishing
                          ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                          : const Text(
                        'Publish',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}