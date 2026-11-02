import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';

class MakePostPage extends StatefulWidget {
  const MakePostPage({Key? key}) : super(key: key);

  @override
  State<MakePostPage> createState() => _MakePostPageState();
}

class _MakePostPageState extends State<MakePostPage> {
  final _textController = TextEditingController();
  final _captionController = TextEditingController();
  Uint8List? _imageBytes;
  String? _imageName;
  bool _isImagePost = false;
  bool _isLoading = false;
  bool _isPublished = false;
  String? _errorMessage;

  // Stubbed Google Secret Manager API key configuration
  static const String _visionApiKey = 'GOOGLE_SECRET_MANAGER_VISION_API_KEY_STUB';

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final pickedFile = await picker.pickImage(source: ImageSource.gallery);
    if (pickedFile != null) {
      final bytes = await pickedFile.readAsBytes();
      setState(() {
        _imageBytes = bytes;
        _imageName = pickedFile.name;
        _isImagePost = true;
      });
    }
  }

  Future<bool> _checkSafeSearch(Uint8List imageBytes) async {
    // Stubbed Google SafeSearch validation via Cloud Vision API
    // In production, send a POST request to:
    // https://vision.googleapis.com/v1/images:annotate?key=$_visionApiKey
    await Future.delayed(const Duration(seconds: 1)); // Simulate network latency

    // Stub check: if image filename contains 'unsafe', mock a violation
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

      if (_isImagePost && _imageBytes != null) {
        bool isSafe = await _checkSafeSearch(_imageBytes!);
        if (!isSafe) {
          setState(() {
            _isLoading = false;
            _errorMessage = 'Post rejected: Image failed Google SafeSearch validation.';
          });
          return;
        }

        // Upload image to Firebase Storage
        final storageRef = FirebaseStorage.instance
            .ref()
            .child('post_images/${DateTime.now().millisecondsSinceEpoch}_$_imageName');
        final uploadTask = await storageRef.putData(_imageBytes!);
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

      // Save post to Firestore
      await FirebaseFirestore.instance.collection('posts').add({
        'text': _isImagePost ? null : _textController.text.trim(),
        'imageUrl': imageUrl,
        'caption': _isImagePost ? _captionController.text.trim() : null,
        'upvotes': 0,
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
      _imageBytes = null;
      _imageName = null;
      _isImagePost = false;
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
                        onPressed: () => setState(() => _isImagePost = false),
                        icon: const Icon(Icons.text_fields),
                        label: const Text('Text Post'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: !_isImagePost ? Theme.of(context).primaryColor : Colors.grey[300],
                          foregroundColor: !_isImagePost ? Colors.white : Colors.black,
                        ),
                      ),
                      const SizedBox(width: 12),
                      ElevatedButton.icon(
                        onPressed: _pickImage,
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
                    if (_imageBytes != null) ...[
                      Container(
                        height: 200,
                        decoration: BoxDecoration(
                          border: Border.all(color: Colors.grey),
                          image: DecorationImage(
                            image: MemoryImage(_imageBytes!),
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
                      onPressed: _isLoading ? null : _publishPost,
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