import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const int _maxTextChars = 800;

class MakePostPage extends StatefulWidget {
  const MakePostPage({super.key});

  @override
  State<MakePostPage> createState() => _MakePostPageState();
}

class _MakePostPageState extends State<MakePostPage> {
  final TextEditingController _textController = TextEditingController();

  bool _isPublishing = false;
  bool _isPublished = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _textController.addListener(_onFormChanged);
  }

  void _onFormChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  void dispose() {
    _textController.removeListener(_onFormChanged);
    _textController.dispose();
    super.dispose();
  }

  void _resetForAnotherPost() {
    _textController.clear();
    setState(() {
      _isPublishing = false;
      _isPublished = false;
      _errorMessage = null;
    });
  }

  Future<void> _publishPost() async {
    final String textContent = _textController.text.trim();

    if (textContent.isEmpty) {
      setState(() {
        _errorMessage = 'Please enter some text before publishing.';
      });
      return;
    }
    if (textContent.length > _maxTextChars) {
      setState(() {
        _errorMessage = 'Text posts must be $_maxTextChars characters or fewer.';
      });
      return;
    }

    setState(() {
      _isPublishing = true;
      _errorMessage = null;
    });

    try {
      final Map<String, dynamic> postData = <String, dynamic>{
        'type': 'text',
        'text': textContent,
        'timestamp': FieldValue.serverTimestamp(),
        'lingerCount': 0,
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
                  TextField(
                    controller: _textController,
                    maxLines: 6,
                    maxLength: _maxTextChars,
                    maxLengthEnforcement: MaxLengthEnforcement.enforced,
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
                    onPressed: _isPublishing ? null : _publishPost,
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