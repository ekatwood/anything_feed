import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'human_test.dart';

const int _maxTextChars = 800;
const int _maxNewlines = 10;
const int _maxConsecutiveNewlines = 3;
const int _maxPostsPerHour = 5;
const Duration _minPostInterval = Duration(seconds: 10);
const Duration _rateWindow = Duration(hours: 1);

const String _recentPostTimestampsPrefKey = 'recent_post_timestamps';

// Replace with your deployed Python Cloud Function HTTP URL.
const String _spamCheckFunctionUrl =
    'https://check-post-similarity-aatw47juga-uc.a.run.app';

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

  String? _validateInitialText(String rawText) {
    final String trimmed = rawText.trim();
    if (trimmed.isEmpty) {
      return 'Please enter some text before publishing.';
    }
    if (trimmed.length > _maxTextChars) {
      return 'Text posts must be $_maxTextChars characters or fewer.';
    }

    final String normalizedNewlines =
    trimmed.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final int totalNewlines = '\n'.allMatches(normalizedNewlines).length;
    if (totalNewlines > _maxNewlines) {
      return 'Please use fewer line breaks in your post.';
    }
    final RegExp consecutiveNewlinesPattern =
    RegExp('\n{${_maxConsecutiveNewlines + 1},}');
    if (consecutiveNewlinesPattern.hasMatch(normalizedNewlines)) {
      return 'Please avoid large blank gaps between lines.';
    }

    if (_containsDisallowedLink(normalizedNewlines)) {
      return 'Links and web addresses are not allowed in posts.';
    }

    return null;
  }

  bool _containsDisallowedLink(String text) {
    final String lower = text.toLowerCase();

    final RegExp directUrlRegex = RegExp(
      r'(?:https?|ftp|mailto):\/\/|www\.',
      caseSensitive: false,
    );
    if (directUrlRegex.hasMatch(lower)) {
      return true;
    }

    final String deobfuscated = lower
        .replaceAll('[.]', '.')
        .replaceAll('(.)', '.')
        .replaceAll('{.}', '.')
        .replaceAll(' dot ', '.')
        .replaceAll('[dot]', '.')
        .replaceAll('(dot)', '.');

    final RegExp domainRegex = RegExp(
      r'(?:^|[\s\W])(?:[a-z0-9-]+\.)+(?:com|net|org|io|co|gg|me|xyz|app|dev|link|info|biz|tv|ly|gl|be|to|ai|uk|us|ca)(?:\/[^\s]*)?',
      caseSensitive: false,
    );
    if (domainRegex.hasMatch(deobfuscated)) {
      return true;
    }

    final String collapsedSpaces = deobfuscated.replaceAll(RegExp(r'\s+'), '');
    if (directUrlRegex.hasMatch(collapsedSpaces) ||
        domainRegex.hasMatch(' $collapsedSpaces')) {
      return true;
    }

    return false;
  }

  Future<List<int>> _loadPrunedRecentPostTimestamps(int nowMs) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String> rawList =
        prefs.getStringList(_recentPostTimestampsPrefKey) ?? <String>[];
    final int cutoffMs = nowMs - _rateWindow.inMilliseconds;

    final List<int> pruned = <int>[];
    for (final String item in rawList) {
      final int? ts = int.tryParse(item);
      if (ts != null && ts >= cutoffMs && ts <= nowMs + 5000) {
        pruned.add(ts);
      }
    }
    pruned.sort();
    await prefs.setStringList(
      _recentPostTimestampsPrefKey,
      pruned.map((int e) => e.toString()).toList(),
    );
    return pruned;
  }

  Future<void> _recordPostTimestamp(int nowMs) async {
    final List<int> timestamps = await _loadPrunedRecentPostTimestamps(nowMs);
    timestamps.add(nowMs);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _recentPostTimestampsPrefKey,
      timestamps.map((int e) => e.toString()).toList(),
    );
  }

  String? _checkRateLimits(List<int> recentTimestampsMs, int nowMs) {
    if (recentTimestampsMs.isNotEmpty) {
      final int lastPostMs = recentTimestampsMs.last;
      final int elapsedMs = nowMs - lastPostMs;
      final int minIntervalMs = _minPostInterval.inMilliseconds;
      if (elapsedMs < minIntervalMs) {
        final int remainingSec =
        ((minIntervalMs - elapsedMs) / 1000).ceil().clamp(1, 60);
        return 'Please wait $remainingSec second${remainingSec == 1 ? '' : 's'} before publishing another post.';
      }
    }

    if (recentTimestampsMs.length >= _maxPostsPerHour) {
      final int oldestInWindowMs = recentTimestampsMs.first;
      final int unlockAtMs = oldestInWindowMs + _rateWindow.inMilliseconds;
      final int remainingMinutes =
      ((unlockAtMs - nowMs) / 60000).ceil().clamp(1, 60);
      return 'You have reached the limit of $_maxPostsPerHour posts per hour. Try again in about $remainingMinutes minute${remainingMinutes == 1 ? '' : 's'}.';
    }

    return null;
  }

  Map<String, dynamic> _buildCompactTextPayload(String text) {
    final String compact = text.replaceAll(RegExp(r'[ \t]+'), ' ').trim();
    if (kIsWeb) {
      return <String, dynamic>{
        'text': compact,
        'char_len': text.length,
      };
    }
    return <String, dynamic>{
      'text': compact,
      'char_len': text.length,
    };
  }

  Future<bool> _submitAndScreenPost({
    required String textContent,
    String? turnstileToken,
  }) async {
    final Uri uri = Uri.parse(_spamCheckFunctionUrl);
    final Map<String, dynamic> payload = <String, dynamic>{
      ..._buildCompactTextPayload(textContent),
      if (turnstileToken != null) 'turnstile_token': turnstileToken,
    };

    final http.Response response = await http
        .post(
      uri,
      headers: const <String, String>{
        'Content-Type': 'application/json',
      },
      body: jsonEncode(payload),
    )
        .timeout(const Duration(seconds: 12));

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('Screening service returned status ${response.statusCode}.');
    }

    final dynamic decoded = jsonDecode(response.body);
    if (decoded is bool) {
      return decoded;
    }
    if (decoded is Map<String, dynamic> && decoded['allowed'] is bool) {
      return decoded['allowed'] as bool;
    }
    throw Exception('Unexpected response from screening service.');
  }

  Future<void> _publishPost() async {
    final String textContent = _textController.text.trim();

    final String? textError = _validateInitialText(textContent);
    if (textError != null) {
      setState(() {
        _errorMessage = textError;
      });
      return;
    }

    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    final List<int> recentTimestampsMs =
    await _loadPrunedRecentPostTimestamps(nowMs);
    final String? rateLimitError = _checkRateLimits(recentTimestampsMs, nowMs);
    if (rateLimitError != null) {
      setState(() {
        _errorMessage = rateLimitError;
      });
      return;
    }

    String? turnstileToken;
    final bool alreadyHumanVerified = await HumanTestDialog.isVerified();
    if (!alreadyHumanVerified) {
      if (!mounted) return;
      turnstileToken = await HumanTestDialog.showAndVerify(context);
      if (turnstileToken == null) {
        if (!mounted) return;
        setState(() {
          _errorMessage = 'Human verification is required before publishing.';
        });
        return;
      }
    }

    setState(() {
      _isPublishing = true;
      _errorMessage = null;
    });

    try {
      final bool isAllowed = await _submitAndScreenPost(
        textContent: textContent,
        turnstileToken: turnstileToken,
      );

      if (!mounted) return;
      if (!isAllowed) {
        setState(() {
          _isPublishing = false;
          _errorMessage =
          'Your post is too similar to a previous post. Please write something new.';
        });
        return;
      }

      await _recordPostTimestamp(DateTime.now().millisecondsSinceEpoch);

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
                    textCapitalization: TextCapitalization.sentences,
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