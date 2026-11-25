import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
// ignore: avoid_web_libraries_in_flutter
import 'dart:html' as html;
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;

class MakePostPage extends StatefulWidget {
  const MakePostPage({Key? key}) : super(key: key);

  @override
  State<MakePostPage> createState() => _MakePostPageState();
}

class _MakePostPageState extends State<MakePostPage> {
  static const double _maxDimension = 1080;

  // Stubbed Cloud Function endpoint (which loads the Vision API key from Google Secret Manager)
  static const String _safeSearchCloudFunctionUrl =
      'https://REGION-PROJECT_ID.cloudfunctions.net/checkSafeSearch';

  final _textController = TextEditingController();
  final _captionController = TextEditingController();

  Uint8List? _processedWebpBytes;
  String? _imageName;
  bool _isImagePost = false;
  bool _isProcessingImage = false;
  bool _isLoading = false;
  bool _isPublished = false;
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
    });

    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile == null) return;

    setState(() {
      _isProcessingImage = true;
      _isImagePost = true;
      _imageName = _toWebpFileName(pickedFile.name);
    });

    try {
      final rawBytes = await pickedFile.readAsBytes();
      final webpBytes = await _resizeAndConvertToWebp(rawBytes);
      setState(() {
        _processedWebpBytes = webpBytes;
        _isProcessingImage = false;
      });
    } catch (e) {
      setState(() {
        _processedWebpBytes = null;
        _isProcessingImage = false;
        _errorMessage = 'Could not process image: $e';
      });
    }
  }

  String _toWebpFileName(String originalName) {
    final dotIndex = originalName.lastIndexOf('.');
    final baseName = dotIndex > 0 ? originalName.substring(0, dotIndex) : originalName;
    return '$baseName.webp';
  }

  Future<Uint8List> _resizeAndConvertToWebp(Uint8List sourceBytes) async {
    final blob = html.Blob([sourceBytes]);
    final objectUrl = html.Url.createObjectUrlFromBlob(blob);
    final img = html.ImageElement(src: objectUrl);

    final completer = Completer<void>();
    img.onLoad.listen((_) => completer.complete());
    img.onError.listen((_) => completer.completeError('Failed to decode selected image.'));
    await completer.future;
    html.Url.revokeObjectUrl(objectUrl);

    final naturalWidth = img.naturalWidth > 0 ? img.naturalWidth.toDouble() : _maxDimension;
    final naturalHeight = img.naturalHeight > 0 ? img.naturalHeight.toDouble() : _maxDimension;

    final scale = math.min(
      1.0,
      math.min(_maxDimension / naturalWidth, _maxDimension / naturalHeight),
    );

    final targetWidth = math.max(1, (naturalWidth * scale).round());
    final targetHeight = math.max(1, (naturalHeight * scale).round());

    final canvas = html.CanvasElement(width: targetWidth, height: targetHeight);
    final ctx = canvas.context2D;
    ctx.drawImageScaled(img, 0, 0, targetWidth, targetHeight);

    // Encode to WebP at 0.85 quality
    final dataUrl = canvas.toDataUrl('image/webp', 0.85);
    final base64Data = dataUrl.split(',').last;
    return base64Decode(base64Data);
  }

  Future<bool> _checkSafeSearchViaCloudFunction(Uint8List webpBytes) async {
    // Stubbed call to Cloud Function (which fetches the API key from Google Secret Manager
    // and calls Google Cloud Vision SafeSearch).
    // In production, send a POST request to [_safeSearchCloudFunctionUrl] with base64 image bytes:
    //
    // final response = await http.post(
    //   Uri.parse(_safeSearchCloudFunctionUrl),
    //   headers: {'Content-Type': 'application/json'},
    //   body: jsonEncode({'imageBase64': base64Encode(webpBytes)}),
    // );
    // if (response.statusCode == 200) {
    //   final json = jsonDecode(response.body) as Map<String, dynamic>;
    //   return json['safe'] == true;
    // }
    // return false;

    await Future.delayed(const Duration(milliseconds: 600));
    if (_imageName != null && _imageName!.toLowerCase().contains('unsafe')) {
      return false;
    }
    return true;
  }

  Future<void> _publishPost() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      String? imageUrl;

      if (_isImagePost) {
        if (_processedWebpBytes == null) {
          setState(() {
            _isLoading = false;
            _errorMessage = 'Please select an image first.';
          });
          return;
        }

        // 1. Ping SafeSearch via Cloud Function (Secret Manager key lives on backend)
        final isSafe = await _checkSafeSearchViaCloudFunction(_processedWebpBytes!);
        if (!isSafe) {
          setState(() {
            _isLoading = false;
            _errorMessage = 'Image did not pass Google SafeSearch check and was not uploaded.';
          });
          return;
        }

        // 2. Upload converted WebP image to Firebase Storage bucket
        final safeFileName = _imageName ?? 'upload.webp';
        final storageRef = FirebaseStorage.instance
            .ref()
            .child('post_images/${DateTime.now().millisecondsSinceEpoch}_$safeFileName');
        final metadata = SettableMetadata(contentType: 'image/webp');
        final uploadTask = await storageRef.putData(_processedWebpBytes!, metadata);
        imageUrl = await uploadTask.ref.getDownloadURL();
      } else {
        if (_textController.text.trim().isEmpty) {
          setState(() {
            _isLoading = false;
            _errorMessage = 'Please enter text or upload an image.';
          });
          return;
        }
      }

      // 3. Save post metadata to Firestore
      await FirebaseFirestore.instance.collection('posts').add({
        'text': _isImagePost ? null : _textController.text.trim(),
        'imageUrl': imageUrl,
        'caption': _isImagePost ? _captionController.text.trim() : null,
        'viewTimeMs': 0,
        'timestamp': FieldValue.serverTimestamp(),
      });

      setState(() {
        _isLoading = false;
        _isPublished = true;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _errorMessage = 'Error publishing post: $e';
      });
    }
  }

  void _resetForm() {
    setState(() {
      _textController.clear();
      _captionController.clear();
      _processedWebpBytes = null;
      _imageName = null;
      _isImagePost = false;
      _isProcessingImage = false;
      _isPublished = false;
      _errorMessage = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text('Create Post'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: _isPublished
                ? Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'Published!',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.green),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: _resetForm,
                  child: const Text('Make another post'),
                ),
              ],
            )
                : SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      ElevatedButton.icon(
                        onPressed: _isLoading
                            ? null
                            : () => setState(() {
                          _isImagePost = false;
                          _errorMessage = null;
                        }),
                        icon: const Icon(Icons.text_fields),
                        label: const Text('Text Post'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: !_isImagePost ? Theme.of(context).primaryColor : Colors.grey[300],
                          foregroundColor: !_isImagePost ? Colors.white : Colors.black,
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton.icon(
                        onPressed: _isLoading ? null : _pickAndProcessImage,
                        icon: const Icon(Icons.image),
                        label: Text(_imageName == null ? 'Upload Picture' : 'Change Picture'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isImagePost ? Theme.of(context).primaryColor : Colors.grey[300],
                          foregroundColor: _isImagePost ? Colors.white : Colors.black,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  if (!_isImagePost) ...[
                    TextField(
                      controller: _textController,
                      maxLength: 800,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: 'Write your post (up to 800 characters)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ] else ...[
                    if (_isProcessingImage) ...[
                      const SizedBox(
                        height: 200,
                        child: Center(child: CircularProgressIndicator()),
                      ),
                      const SizedBox(height: 16),
                    ] else if (_processedWebpBytes != null) ...[
                      Container(
                        height: 200,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          image: DecorationImage(
                            image: MemoryImage(_processedWebpBytes!),
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                    TextField(
                      controller: _captionController,
                      maxLength: 300,
                      decoration: const InputDecoration(
                        labelText: 'Optional caption (max 300 characters)',
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  if (_errorMessage != null) ...[
                    Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 16),
                  ],
                  SizedBox(
                    height: 50,
                    child: ElevatedButton(
                      onPressed: (_isLoading || _isProcessingImage) ? null : _publishPost,
                      child: _isLoading
                          ? const CircularProgressIndicator(color: Colors.white)
                          : const Text('Publish', style: TextStyle(fontSize: 18)),
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