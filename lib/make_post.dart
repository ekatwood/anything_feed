import 'dart:async';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:heic_to_png_jpg/heic_to_png_jpg.dart';
import 'package:web/web.dart' as web;

const int _maxImageDimension = 1080;
const double _webpQuality = 0.85;
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
  Uint8List? _processedWebpBytes;
  String? _errorMessage;

  @override
  void dispose() {
    _textController.dispose();
    _captionController.dispose();
    super.dispose();
  }

  Future<void> _pickAndProcessImage() async {
    setState(() {
      _errorMessage = null;
      _isProcessingImage = true;
    });

    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) {
        setState(() {
          _isProcessingImage = false;
        });
        return;
      }

      final PlatformFile pickedFile = result.files.single;
      final Uint8List? rawBytes = pickedFile.bytes;
      if (rawBytes == null || rawBytes.isEmpty) {
        throw Exception('Could not read image data.');
      }

      final Uint8List webpBytes = await _processImageToWebp(
        rawBytes: rawBytes,
        fileName: pickedFile.name,
      );

      if (webpBytes.length > _maxUploadBytes) {
        throw Exception(
          'Processed image exceeds the 5 MB upload limit.',
        );
      }

      if (!mounted) return;
      setState(() {
        _processedWebpBytes = webpBytes;
        _selectedFileName = _buildWebpFileName(pickedFile.name);
        _isProcessingImage = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _processedWebpBytes = null;
        _selectedFileName = null;
        _isProcessingImage = false;
        _errorMessage =
        'Could not process image: ${e.toString().replaceFirst('Exception: ', '')}';
      });
    }
  }

  String _buildWebpFileName(String originalName) {
    final int dotIndex = originalName.lastIndexOf('.');
    final String baseName = dotIndex > 0
        ? originalName.substring(0, dotIndex)
        : originalName;
    final String sanitized = baseName
        .replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    final String safeBase = sanitized.isEmpty ? 'image' : sanitized;
    return '${DateTime.now().millisecondsSinceEpoch}_$safeBase.webp';
  }

  bool _isHeicFile(Uint8List bytes, String? fileName) {
    if (HeicConverter.isHeic(bytes)) {
      return true;
    }
    final String lower = (fileName ?? '').toLowerCase();
    return lower.endsWith('.heic') || lower.endsWith('.heif');
  }

  Future<Uint8List> _processImageToWebp({
    required Uint8List rawBytes,
    String? fileName,
  }) async {
    if (_isHeicFile(rawBytes, fileName)) {
      final Uint8List convertedHeic = await HeicConverter.convertToWebP(
        heicData: rawBytes,
        maxWidth: _maxImageDimension,
        maxHeight: _maxImageDimension,
        quality: (_webpQuality * 100).round(),
      );
      if (convertedHeic.isEmpty) {
        throw Exception('Failed to decode HEIC image.');
      }
      return convertedHeic;
    }

    return _resizeAndEncodeCanvasWebp(rawBytes);
  }

  Future<Uint8List> _resizeAndEncodeCanvasWebp(Uint8List bytes) async {
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

      final String dataUrl = canvas.toDataURL('image/webp', _webpQuality.toJS);
      const String prefix = 'data:image/webp;base64,';
      final int commaIndex = dataUrl.indexOf(',');
      if (commaIndex == -1 || !dataUrl.startsWith('data:image/webp')) {
        throw Exception('Failed to encode image as WebP.');
      }

      final String base64Payload = dataUrl.substring(commaIndex + 1);
      final web.Response dataResponse = await web.window
          .fetch('$prefix$base64Payload'.toJS)
          .toDart;
      final JSArrayBuffer arrayBuffer = await dataResponse.arrayBuffer().toDart;
      return arrayBuffer.toDart.asUint8List();
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

    if (_includeImage && _processedWebpBytes == null) {
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

      if (_includeImage && _processedWebpBytes != null) {
        final String fileName = _selectedFileName ??
            '${DateTime.now().millisecondsSinceEpoch}_upload.webp';
        storagePath = 'post_images/$fileName';

        final Reference ref = FirebaseStorage.instance.ref().child(storagePath);
        final SettableMetadata metadata = SettableMetadata(
          contentType: 'image/webp',
        );

        await ref.putData(_processedWebpBytes!, metadata);
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
                        //fontWeight: FontWeight.w700,
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
                        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
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
                            ? 'Resizing & Converting to WebP...'
                            : (_processedWebpBytes == null
                            ? 'Choose Photo (HEIC, JPG, PNG, WebP)'
                            : 'Replace Photo'),
                        style: const TextStyle(
                          fontSize: 17,
                          //fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_processedWebpBytes != null) ...<Widget>[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 420),
                          child: Image.memory(
                            _processedWebpBytes!,
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Ready as WebP (${(_processedWebpBytes!.length / 1024).toStringAsFixed(0)} KB, max 1080px)',
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