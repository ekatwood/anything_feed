import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:heic_to_png_jpg/heic_to_png_jpg.dart';
import 'package:http/http.dart' as http;
import 'package:web/web.dart' as web;

const int _maxImageDimension = 1080;
const double _imageQuality = 0.85;
const int _maxUploadBytes = 5 * 1024 * 1024;
const int _maxTextChars = 800;
const int _maxCaptionChars = 300;
const String _safeSearchEndpoint = '';

// Minimum aspect ratio (width / height): 4:5 (0.8) prevents overly tall portrait photos.
const double _minAspectRatio = 4 / 5;

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
  bool _isPublished = false;

  String? _selectedFileName;
  String _processedMimeType = 'image/webp';
  Uint8List? _processedImageBytes;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onFormChanged);
    _captionController.addListener(_onFormChanged);
  }

  void _onFormChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _textController.removeListener(_onFormChanged);
    _captionController.removeListener(_onFormChanged);
    _textController.dispose();
    _captionController.dispose();
    super.dispose();
  }

  void _resetForAnotherPost() {
    _textController.clear();
    _captionController.clear();
    setState(() {
      _includeImage = false;
      _isProcessingImage = false;
      _isPublishing = false;
      _isPublished = false;
      _selectedFileName = null;
      _processedMimeType = 'image/webp';
      _processedImageBytes = null;
      _errorMessage = null;
    });
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
        throw Exception('Processed image exceeds the 5 MB upload limit.');
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

  String _buildOutputFileName(
      String originalName, {
        required String mimeType,
      }) {
    final int dotIndex = originalName.lastIndexOf('.');
    final String baseName =
    dotIndex > 0 ? originalName.substring(0, dotIndex) : originalName;
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

      double srcX = 0;
      double srcY = 0;
      double srcW = naturalW.toDouble();
      double srcH = naturalH.toDouble();
      final double aspect = srcW / srcH;

      // Only crop vertically when the image is taller than 4:5.
      if (aspect < _minAspectRatio) {
        srcH = srcW / _minAspectRatio;
        srcY = (naturalH - srcH) / 2;
      }

      final double scale = math.min(
        1.0,
        math.min(
          _maxImageDimension / srcW,
          _maxImageDimension / srcH,
        ),
      );
      final int targetW = math.max(1, (srcW * scale).round());
      final int targetH = math.max(1, (srcH * scale).round());

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
      ctx.drawImage(
        img,
        srcX,
        srcY,
        srcW,
        srcH,
        0,
        0,
        targetW.toDouble(),
        targetH.toDouble(),
      );

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

  Future<void> _validateImageSafeSearch({
    required Uint8List bytes,
    required String mimeType,
  }) async {
    if (_safeSearchEndpoint.trim().isEmpty) {
      return;
    }

    final response = await http.post(
      Uri.parse(_safeSearchEndpoint.trim()),
      headers: const {'Content-Type': 'application/json'},
      body: jsonEncode({
        'imageBase64': base64Encode(bytes),
        'mimeType': mimeType,
      }),
    );

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Image safety check failed (${response.statusCode}).');
    }

    if (response.body.isNotEmpty) {
      final dynamic decoded = jsonDecode(response.body);
      if (decoded is Map<String, dynamic>) {
        final bool isSafe = decoded['safe'] as bool? ?? true;
        if (!isSafe) {
          final String reason = decoded['reason'] as String? ??
              'Image did not pass SafeSearch validation.';
          throw Exception(reason);
        }
      }
    }
  }

  Future<void> _publishPost() async {
    final String textContent = _textController.text.trim();
    final String captionContent = _captionController.text.trim();

    if (!_includeImage) {
      if (textContent.isEmpty) {
        setState(() {
          _errorMessage = 'Please enter some text before publishing.';
        });
        return;
      }
      if (textContent.length > _maxTextChars) {
        setState(() {
          _errorMessage =
          'Text posts must be $_maxTextChars characters or fewer.';
        });
        return;
      }
    } else {
      if (_processedImageBytes == null) {
        setState(() {
          _errorMessage = 'Please select an image first.';
        });
        return;
      }
      if (captionContent.length > _maxCaptionChars) {
        setState(() {
          _errorMessage =
          'Captions must be $_maxCaptionChars characters or fewer.';
        });
        return;
      }
    }

    setState(() {
      _isPublishing = true;
      _errorMessage = null;
    });

    try {
      String? imageUrl;
      String? storagePath;

      if (_includeImage && _processedImageBytes != null) {
        await _validateImageSafeSearch(
          bytes: _processedImageBytes!,
          mimeType: _processedMimeType,
        );

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
      setState(() {
        _isPublishing = false;
        _isPublished = true;
      });
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
    final int textLength = _textController.text.length;
    final int captionLength = _captionController.text.length;

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              child: _isPublished
                  ? Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.start,
                    children: <Widget>[
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        icon: const Icon(Icons.arrow_back),
                        tooltip: 'Back',
                      ),
                    ],
                  ),
                  const SizedBox(height: 36),
                  Icon(
                    Icons.check_circle_outline,
                    size: 48,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Published!',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineLarge?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 32),
                  FilledButton.icon(
                    onPressed: _resetForAnotherPost,
                    icon: const Icon(Icons.add),
                    label: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        'Make another post',
                        style: TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              )
                  : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: <Widget>[
                      IconButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        icon: const Icon(Icons.arrow_back),
                        tooltip: 'Back',
                      ),
                      Text(
                        'New Post',
                        style: theme.textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 48),
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
                      maxLength: _maxTextChars,
                      maxLengthEnforcement:
                      MaxLengthEnforcement.enforced,
                      enabled: !_isPublishing,
                      decoration: const InputDecoration(
                        hintText: 'Up to 800 characters',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        '$textLength / $_maxTextChars',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
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
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
                      )
                          : const Icon(Icons.upload_file, size: 22),
                      label: Text(
                        _isProcessingImage
                            ? ''
                            : (_processedImageBytes == null
                            ? 'Choose Image'
                            : 'Replace Image'),
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    if (_processedImageBytes != null) ...<Widget>[
                      Center(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(16),
                          child: ConstrainedBox(
                            constraints:
                            const BoxConstraints(maxHeight: 420),
                            child: Image.memory(
                              _processedImageBytes!,
                              fit: BoxFit.contain,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      controller: _captionController,
                      maxLines: 3,
                      maxLength: _maxCaptionChars,
                      maxLengthEnforcement:
                      MaxLengthEnforcement.enforced,
                      enabled: !_isPublishing,
                      decoration: const InputDecoration(
                        hintText: 'Optional caption up to 300 characters',
                        border: OutlineInputBorder(),
                        counterText: '',
                      ),
                    ),
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        '$captionLength / $_maxCaptionChars',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
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
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                        ),
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