import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/window_security_service.dart';

/// WebView screen that loads Outlook Web and captures OAuth tokens
/// by injecting JavaScript to hook XHR and fetch requests.
class OutlookAuthScreen extends StatefulWidget {
  const OutlookAuthScreen({super.key});

  @override
  State<OutlookAuthScreen> createState() => _OutlookAuthScreenState();
}

class _OutlookAuthScreenState extends State<OutlookAuthScreen> {
  late final WebViewController _controller;

  final List<Map<String, dynamic>> _accessTokens = [];
  final List<Map<String, dynamic>> _refreshTokens = [];
  String? _clientId;
  String? _tenantId;
  bool _hasCapturedTokens = false;

  @override
  void initState() {
    super.initState();
    // Enable FLAG_SECURE to prevent screenshots during OAuth
    WindowSecurityService.enableScreenshotProtection();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36',
      )
      ..addJavaScriptChannel(
        'TokenCapture',
        onMessageReceived: _onTokenCaptured,
      )
      ..setNavigationDelegate(NavigationDelegate(
        onPageFinished: (_) => _injectTokenCapture(),
      ))
      ..loadRequest(Uri.parse('https://webmail.jci.com'));
  }

  /// Inject JS to hook XHR and fetch to capture OAuth tokens
  Future<void> _injectTokenCapture() async {
    await _controller.runJavaScript(_tokenCaptureJs);
  }

  void _onTokenCaptured(JavaScriptMessage message) {
    try {
      final data = jsonDecode(message.message) as Map<String, dynamic>;
      final type = data['type'] as String?;

      if (type == 'token_response') {
        final accessToken = data['access_token'] as String?;
        final scope = data['scope'] as String? ?? '';
        final expiresIn = data['expires_in'] as int? ?? 3600;
        final refreshToken = data['refresh_token'] as String?;
        final clientId = data['client_id'] as String?;

        if (accessToken != null && accessToken.isNotEmpty) {
          _accessTokens.add({
            'token': accessToken,
            'scopes': scope,
            'expiresIn': expiresIn,
            'capturedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
          });
        }

        if (refreshToken != null && refreshToken.isNotEmpty) {
          _refreshTokens.add({
            'token': refreshToken,
            'clientId': clientId ?? _clientId ?? '',
          });
        }

        if (clientId != null) _clientId = clientId;

        setState(() => _hasCapturedTokens = _accessTokens.isNotEmpty);
      } else if (type == 'bearer_token') {
        final token = data['token'] as String?;
        final scopes = data['scopes'] as String? ?? '';
        if (token != null && token.isNotEmpty) {
          // Deduplicate
          if (!_accessTokens.any((t) => t['token'] == token)) {
            _accessTokens.add({
              'token': token,
              'scopes': scopes,
              'expiresIn': 3600,
              'capturedAt': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            });
            setState(() => _hasCapturedTokens = true);
          }
        }
      } else if (type == 'auth_params') {
        if (data['client_id'] != null) _clientId = data['client_id'] as String;
        if (data['tenant_id'] != null) _tenantId = data['tenant_id'] as String;
      }
    } catch (e) {
      debugPrint('[OutlookAuth] Error parsing token: $e');
    }
  }

  void _saveAndClose() {
    final tokenData = {
      'accessTokens': _accessTokens,
      'refreshTokens': _refreshTokens,
      'clientId': _clientId ?? '89bee1f7-5e6e-4d8a-9f3d-ecd601259da7',
      'tenantId': _tenantId ?? 'organizations',
    };
    Navigator.of(context).pop(tokenData);
  }

  /// Decode a JWT token's payload to extract claims (scopes, audience, etc.)
  Map<String, dynamic>? _decodeJwt(String token) {
    try {
      final parts = token.split('.');
      if (parts.length != 3) return null;
      // Base64url decode the payload
      var payload = parts[1];
      // Add padding if needed
      switch (payload.length % 4) {
        case 2: payload += '=='; break;
        case 3: payload += '='; break;
      }
      final decoded = utf8.decode(base64Url.decode(payload));
      return jsonDecode(decoded) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  /// Get scope list for a token — from OAuth response or JWT payload
  List<String> _getTokenScopeList(Map<String, dynamic> tokenInfo) {
    // First check the captured scopes from OAuth response
    final oauthScopes = tokenInfo['scopes'] as String? ?? '';
    if (oauthScopes.isNotEmpty) return oauthScopes.split(' ').where((s) => s.isNotEmpty).toList();
    // Fall back to decoding the JWT
    final token = tokenInfo['token'] as String? ?? '';
    final claims = _decodeJwt(token);
    if (claims == null) return ['(unknown)'];
    final scp = claims['scp'] as String?;
    if (scp != null && scp.isNotEmpty) return scp.split(' ').where((s) => s.isNotEmpty).toList();
    final roles = claims['roles'] as List?;
    if (roles != null && roles.isNotEmpty) return roles.map((r) => r.toString()).toList();
    return ['(no scopes)'];
  }

  /// Get the audience (aud) claim from a JWT, shortened
  String _getTokenAudience(Map<String, dynamic> tokenInfo) {
    final token = tokenInfo['token'] as String? ?? '';
    final claims = _decodeJwt(token);
    final aud = claims?['aud'] as String? ?? '(unknown)';
    // Strip https:// prefix for readability
    return aud.replaceFirst(RegExp(r'^https?://'), '');
  }

  /// Build grouped token data: audience → { tokens, scopes (union), expiresIn list }
  Map<String, Map<String, dynamic>> _buildAudienceGroups() {
    final groups = <String, Map<String, dynamic>>{};
    for (int i = 0; i < _accessTokens.length; i++) {
      final aud = _getTokenAudience(_accessTokens[i]);
      final scopes = _getTokenScopeList(_accessTokens[i]);
      final expiresIn = _accessTokens[i]['expiresIn'] as int? ?? 0;
      if (!groups.containsKey(aud)) {
        groups[aud] = {
          'scopes': <String>{},
          'tokenCount': 0,
          'expiresIn': <int>[],
        };
      }
      (groups[aud]!['scopes'] as Set<String>).addAll(scopes);
      groups[aud]!['tokenCount'] = (groups[aud]!['tokenCount'] as int) + 1;
      (groups[aud]!['expiresIn'] as List<int>).add(expiresIn);
    }
    return groups;
  }

  bool _tokenDetailsExpanded = false;

  @override
  void dispose() {
    // Re-enable screenshots when leaving OAuth screen
    WindowSecurityService.disableScreenshotProtection();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Outlook Sign-In'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.of(context).pop(null),
        ),
        actions: [
          if (_hasCapturedTokens)
            TextButton.icon(
              onPressed: _saveAndClose,
              icon: Icon(Icons.check, color: Colors.green.shade400),
              label: Text(
                'Save & Close',
                style: TextStyle(color: Colors.green.shade400),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          if (_hasCapturedTokens)
            Container(
              width: double.infinity,
              color: Colors.green.shade50,
              child: Column(
                children: [
                  InkWell(
                    onTap: () => setState(() => _tokenDetailsExpanded = !_tokenDetailsExpanded),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      child: Row(
                        children: [
                          Icon(Icons.check_circle, size: 16, color: Colors.green.shade700),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${_accessTokens.length} access token(s), ${_refreshTokens.length} refresh token(s)',
                              style: TextStyle(
                                fontSize: 13,
                                color: Colors.green.shade700,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                          Icon(
                            _tokenDetailsExpanded ? Icons.expand_less : Icons.expand_more,
                            size: 20,
                            color: Colors.green.shade700,
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (_tokenDetailsExpanded)
                    Builder(builder: (context) {
                      final groups = _buildAudienceGroups();
                      final hasMailScope = _accessTokens.any((t) =>
                        (_getTokenScopeList(t)).any((s) => s.toLowerCase().contains('mail')));
                      final hasDriveScope = _accessTokens.any((t) =>
                        (_getTokenScopeList(t)).any((s) {
                          final lower = s.toLowerCase();
                          return lower.contains('files') || lower.contains('sites');
                        }));
                      bool _isHighlightedScope(String scope) {
                        final lower = scope.toLowerCase();
                        return lower.contains('mail') || lower.contains('files') || lower.contains('sites');
                      }
                      Color _scopeBg(String scope) {
                        final lower = scope.toLowerCase();
                        if (lower.contains('mail')) return Colors.blue.shade100;
                        if (lower.contains('files') || lower.contains('sites')) return Colors.purple.shade50;
                        return Colors.green.shade50;
                      }
                      Color _scopeBorder(String scope) {
                        final lower = scope.toLowerCase();
                        if (lower.contains('mail')) return Colors.blue.shade300;
                        if (lower.contains('files') || lower.contains('sites')) return Colors.purple.shade200;
                        return Colors.green.shade200;
                      }
                      Color _scopeText(String scope) {
                        final lower = scope.toLowerCase();
                        if (lower.contains('mail')) return Colors.blue.shade900;
                        if (lower.contains('files') || lower.contains('sites')) return Colors.purple.shade900;
                        return Colors.green.shade900;
                      }
                      return Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(maxHeight: 300),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final warning in [
                                if (!hasMailScope) 'No Mail scopes found — email access may fail',
                                if (!hasDriveScope) 'No Files/Sites scopes found — OneDrive/SharePoint access may fail',
                              ])
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                  margin: const EdgeInsets.only(bottom: 8),
                                  decoration: BoxDecoration(
                                    color: Colors.orange.shade100,
                                    borderRadius: BorderRadius.circular(6),
                                  ),
                                  child: Row(
                                    children: [
                                      Icon(Icons.warning_amber, size: 14, color: Colors.orange.shade800),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          warning,
                                          style: TextStyle(fontSize: 11, color: Colors.orange.shade900, fontWeight: FontWeight.w500),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              for (final entry in groups.entries) ...[
                                Container(
                                  width: double.infinity,
                                  margin: const EdgeInsets.only(bottom: 8),
                                  padding: const EdgeInsets.all(8),
                                  decoration: BoxDecoration(
                                    color: Colors.green.shade100,
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Icon(Icons.language, size: 12, color: Colors.green.shade800),
                                          const SizedBox(width: 4),
                                          Expanded(
                                            child: Text(
                                              entry.key,
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w700,
                                                color: Colors.green.shade900,
                                              ),
                                            ),
                                          ),
                                          Text(
                                            '${entry.value['tokenCount']} token(s)',
                                            style: TextStyle(fontSize: 10, color: Colors.green.shade700),
                                          ),
                                        ],
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2, bottom: 4),
                                        child: Text(
                                          'expires: ${(entry.value['expiresIn'] as List<int>).map((e) => e >= 3600 ? '${(e / 3600).toStringAsFixed(1)}h' : '${e}s').join(', ')}',
                                          style: TextStyle(fontSize: 10, color: Colors.green.shade700),
                                        ),
                                      ),
                                      Wrap(
                                        spacing: 4,
                                        runSpacing: 3,
                                        children: [
                                          for (final scope in (entry.value['scopes'] as Set<String>).toList()..sort())
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: _scopeBg(scope),
                                                borderRadius: BorderRadius.circular(4),
                                                border: Border.all(
                                                  color: _scopeBorder(scope),
                                                  width: 0.5,
                                                ),
                                              ),
                                              child: Text(
                                                scope,
                                                style: TextStyle(
                                                  fontSize: 9,
                                                  color: _scopeText(scope),
                                                  fontWeight: _isHighlightedScope(scope)
                                                      ? FontWeight.w600
                                                      : FontWeight.normal,
                                                ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    }),
                ],
              ),
            ),
          Expanded(
            child: WebViewWidget(controller: _controller),
          ),
        ],
      ),
    );
  }
}

/// JavaScript to inject into pages to capture OAuth tokens.
/// Hooks XMLHttpRequest and fetch to intercept token responses and Bearer headers.
const _tokenCaptureJs = r'''
(function() {
  if (window.__tokenCaptureInjected) return;
  window.__tokenCaptureInjected = true;

  // --- Hook XMLHttpRequest ---
  var origOpen = XMLHttpRequest.prototype.open;
  var origSend = XMLHttpRequest.prototype.send;
  var origSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;

  XMLHttpRequest.prototype.open = function(method, url) {
    this._captureUrl = url;
    this._captureMethod = method;

    // Capture client_id from OAuth authorize URLs
    if (typeof url === 'string' && url.includes('oauth2/v2.0/authorize') && url.includes('client_id=')) {
      try {
        var params = new URL(url).searchParams;
        var cid = params.get('client_id');
        var urlParts = url.match(/\/([^\/]+)\/oauth2/);
        var tid = urlParts ? urlParts[1] : null;
        if (cid) {
          TokenCapture.postMessage(JSON.stringify({
            type: 'auth_params',
            client_id: cid,
            tenant_id: tid
          }));
        }
      } catch(e) {}
    }
    return origOpen.apply(this, arguments);
  };

  // Hook setRequestHeader to capture Bearer tokens from XHR requests
  XMLHttpRequest.prototype.setRequestHeader = function(name, value) {
    if (name && name.toLowerCase() === 'authorization' && value && value.startsWith('Bearer ')) {
      var url = this._captureUrl || '';
      if (url.match(/outlook\.office|graph\.microsoft|substrate\.office/)) {
        var token = value.substring(7);
        TokenCapture.postMessage(JSON.stringify({
          type: 'bearer_token',
          token: token,
          scopes: ''
        }));
      }
    }
    return origSetRequestHeader.apply(this, arguments);
  };

  XMLHttpRequest.prototype.send = function() {
    var xhr = this;
    var origOnLoad = xhr.onload;
    var origOnReady = xhr.onreadystatechange;

    function checkResponse() {
      if (xhr.readyState !== 4) return;
      var url = xhr._captureUrl || '';

      // Capture token responses
      if (url.includes('oauth2/v2.0/token') || url.includes('oauth2/token')) {
        try {
          var body = JSON.parse(xhr.responseText);
          if (body.access_token) {
            TokenCapture.postMessage(JSON.stringify({
              type: 'token_response',
              access_token: body.access_token,
              scope: body.scope || '',
              expires_in: body.expires_in || 3600,
              refresh_token: body.refresh_token || null,
              client_id: body.client_id || null
            }));
          }
        } catch(e) {}
      }
    }

    xhr.onload = function() {
      checkResponse();
      if (origOnLoad) origOnLoad.apply(this, arguments);
    };

    var origReady = xhr.onreadystatechange;
    xhr.onreadystatechange = function() {
      checkResponse();
      if (origReady) origReady.apply(this, arguments);
    };

    return origSend.apply(this, arguments);
  };

  // --- Hook fetch ---
  var origFetch = window.fetch;
  window.fetch = function(input, init) {
    var url = typeof input === 'string' ? input : (input && input.url ? input.url : '');

    // Capture client_id from OAuth authorize URLs
    if (url.includes('oauth2/v2.0/authorize') && url.includes('client_id=')) {
      try {
        var params = new URL(url).searchParams;
        var cid = params.get('client_id');
        var urlParts = url.match(/\/([^\/]+)\/oauth2/);
        var tid = urlParts ? urlParts[1] : null;
        if (cid) {
          TokenCapture.postMessage(JSON.stringify({
            type: 'auth_params',
            client_id: cid,
            tenant_id: tid
          }));
        }
      } catch(e) {}
    }

    // Capture Bearer tokens from outgoing request headers
    if (url.match(/outlook\.office|graph\.microsoft|substrate\.office/)) {
      var headers = (init && init.headers) || {};
      var auth = null;
      if (headers instanceof Headers) {
        auth = headers.get('Authorization') || headers.get('authorization');
      } else if (typeof headers === 'object') {
        auth = headers['Authorization'] || headers['authorization'];
      }
      if (auth && auth.startsWith('Bearer ')) {
        var token = auth.substring(7);
        TokenCapture.postMessage(JSON.stringify({
          type: 'bearer_token',
          token: token,
          scopes: ''
        }));
      }
    }

    return origFetch.apply(this, arguments).then(function(response) {
      // Capture token responses
      if (url.includes('oauth2/v2.0/token') || url.includes('oauth2/token')) {
        response.clone().json().then(function(body) {
          if (body.access_token) {
            TokenCapture.postMessage(JSON.stringify({
              type: 'token_response',
              access_token: body.access_token,
              scope: body.scope || '',
              expires_in: body.expires_in || 3600,
              refresh_token: body.refresh_token || null,
              client_id: body.client_id || null
            }));
          }
        }).catch(function() {});
      }
      return response;
    });
  };
})();
''';
