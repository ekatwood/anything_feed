import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:web/web.dart' as web;

const int _humanCheckValidityMs = 7200000; // 2 hours
const String _humanVerifiedPrefKey = 'human_verified_timestamp';

// Cloudflare Turnstile Site Key (public key).
const String _turnstileSiteKey = '0x4AAAAAAGWLwhlANVORLWZw';

@JS('cloudflareTurnstileBridge')
external JSObject? get _turnstileBridge;

class HumanTestDialog extends StatefulWidget {
  final VoidCallback? onSuccess;
  final String siteKey;

  const HumanTestDialog({
    super.key,
    this.onSuccess,
    this.siteKey = _turnstileSiteKey,
  });

  static Future<bool> isVerified() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int verifiedTime = prefs.getInt(_humanVerifiedPrefKey) ?? 0;
    if (verifiedTime <= 0) return false;
    final int now = DateTime.now().millisecondsSinceEpoch;
    return (now - verifiedTime) < _humanCheckValidityMs;
  }

  static Future<String?> showAndVerify(
      BuildContext context, {
        String siteKey = _turnstileSiteKey,
        VoidCallback? onSuccess,
      }) async {
    if (await isVerified()) {
      onSuccess?.call();
      return 'cached-2h-session';
    }

    if (!context.mounted) return null;

    final String? token = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return HumanTestDialog(
          siteKey: siteKey,
          onSuccess: onSuccess,
        );
      },
    );

    return token;
  }

  @override
  State<HumanTestDialog> createState() => _HumanTestDialogState();
}

class _HumanTestDialogState extends State<HumanTestDialog> {
  late final String _containerId;
  bool _isLoading = true;
  String? _errorMessage;
  bool _containerRegistered = false;

  @override
  void initState() {
    super.initState();
    _containerId = 'cf-turnstile-${DateTime.now().microsecondsSinceEpoch}';
    if (kIsWeb) {
      _ensureContainerAndVerify();
    } else {
      _isLoading = false;
      _errorMessage = 'Turnstile verification is configured for web.';
    }
  }

  void _ensureContainerElement() {
    if (_containerRegistered) return;
    final web.Document? doc = web.window.document;
    if (doc == null) return;

    final web.Element? existing = doc.getElementById(_containerId);
    if (existing == null) {
      final web.HTMLDivElement div = doc.createElement('div') as web.HTMLDivElement;
      div.id = _containerId;
      div.style.minHeight = '65px';
      div.style.display = 'flex';
      div.style.justifyContent = 'center';
      doc.body?.appendChild(div);
    }
    _containerRegistered = true;
  }

  void _moveContainerIntoHost() {
    final web.Document? doc = web.window.document;
    if (doc == null) return;
    final web.Element? div = doc.getElementById(_containerId);
    final web.Element? host = doc.getElementById('$_containerId-host');
    if (div != null && host != null && div.parentElement != host) {
      host.appendChild(div);
    }
  }

  void _cleanupContainerElement() {
    final JSObject? bridge = _turnstileBridge;
    if (bridge != null) {
      try {
        bridge.callMethod<JSAny?>('cleanup'.toJS, _containerId.toJS);
      } catch (_) {
        // Ignore bridge cleanup errors.
      }
    }
    final web.Element? div = web.window.document?.getElementById(_containerId);
    div?.remove();
  }

  Future<void> _ensureContainerAndVerify() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      _ensureContainerElement();
      _moveContainerIntoHost();
      await _runTurnstileChallenge();
    });
  }

  Future<void> _runTurnstileChallenge() async {
    try {
      final JSObject? bridge = _turnstileBridge;
      if (bridge == null) {
        throw StateError(
          'cloudflareTurnstileBridge not found. Ensure web/javascript/cloudflare_turnstile.js is loaded in web/index.html.',
        );
      }

      final Brightness brightness = Theme.of(context).brightness;
      final String themeName = brightness == Brightness.dark ? 'dark' : 'light';

      final JSPromise<JSString>? promise = bridge.callMethod<JSPromise<JSString>>(
        'verify'.toJS,
        _containerId.toJS,
        widget.siteKey.toJS,
        themeName.toJS,
      );

      if (promise == null) {
        throw StateError('Turnstile verify() did not return a promise.');
      }

      final JSString jsToken = await promise.toDart;
      final String token = jsToken.toDart.trim();
      if (token.isEmpty) {
        throw StateError('Turnstile verification returned an empty token.');
      }

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        _humanVerifiedPrefKey,
        DateTime.now().millisecondsSinceEpoch,
      );

      if (!mounted) return;
      widget.onSuccess?.call();
      Navigator.of(context).pop(token);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = e.toString().replaceFirst('Bad state: ', '');
      });
    }
  }

  @override
  void dispose() {
    _cleanupContainerElement();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Human Verification'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Text(
              'Complete the quick check below to continue posting.',
               style: TextStyle(fontSize: 19),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 76,
            width: 300,
            child: kIsWeb
                ? HtmlElementSlot(hostId: '$_containerId-host')
                : const Center(child: Text('Web-only check')),
          ),
          if (_isLoading) ...<Widget>[
            const SizedBox(height: 12),
            const CircularProgressIndicator(strokeWidth: 2),
          ],
          if (_errorMessage != null) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              _errorMessage!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop<String>(null),
          child: const Text(
            'Cancel',
            style: TextStyle(fontSize: 19),
          ),
        ),
        if (_errorMessage != null && kIsWeb)
          TextButton(
            onPressed: _ensureContainerAndVerify,
            child: const Text(
                'Retry',
                style: TextStyle(fontSize: 19),
            ),
          ),
      ],
    );
  }
}

/// Lightweight DOM placeholder widget on Flutter Web that exposes a div with
/// [hostId] so [_moveContainerIntoHost] can dock the Turnstile widget inside
/// the Flutter modal overlay.
class HtmlElementSlot extends StatefulWidget {
  final String hostId;

  const HtmlElementSlot({super.key, required this.hostId});

  @override
  State<HtmlElementSlot> createState() => _HtmlElementSlotState();
}

class _HtmlElementSlotState extends State<HtmlElementSlot> {
  web.HTMLDivElement? _slotDiv;

  @override
  void initState() {
    super.initState();
    if (kIsWeb) {
      final web.HTMLDivElement div =
      web.window.document!.createElement('div') as web.HTMLDivElement;
      div.id = widget.hostId;
      div.style.width = '100%';
      div.style.height = '100%';
      div.style.display = 'flex';
      div.style.alignItems = 'center';
      div.style.justifyContent = 'center';
      _slotDiv = div;
      web.window.document!.body?.appendChild(div);
    }
  }

  @override
  void dispose() {
    _slotDiv?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return const SizedBox.expand();
  }
}