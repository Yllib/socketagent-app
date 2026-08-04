import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';
import '../services/chat_provider.dart';

class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key});

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  final _emailController = TextEditingController();
  bool _loading = false;
  String? _error;
  bool _showWebView = false;
  String? _checkoutSessionId;
  late WebViewController _webViewController;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _subscribe() async {
    final input = _emailController.text.trim().toLowerCase();
    if (input.isEmpty) {
      setState(() => _error = 'Enter your email to continue');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    final provider = context.read<ChatProvider>();
    final result = await provider.createCheckoutSession(input);

    if (!mounted) return;

    if (result == null) {
      setState(() {
        _loading = false;
        _error =
            'Could not reach the relay service. Check your internet connection.';
      });
      return;
    }

    // Server returned an error
    if (result.containsKey('error')) {
      setState(() {
        _loading = false;
        _error = result['error'] as String? ?? 'Unknown relay error';
      });
      return;
    }

    // Existing subscription / owner bypass: token returned directly.
    if (result['ownerBypass'] == true ||
        result['existingSubscription'] == true) {
      final token = result['token'] as String? ?? '';
      final email = result['email'] as String? ?? '';
      await provider.saveSubscriberToken(token, email);
      if (mounted) {
        Navigator.of(context).pop(true);
      }
      return;
    }

    // Normal flow: open Stripe Checkout in WebView
    final url = result['url'] as String?;
    if (url == null || url.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'Could not create checkout session';
      });
      return;
    }

    // Extract session ID from the checkout response
    _checkoutSessionId = result['sessionId'] as String?;

    _webViewController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            // Intercept success redirect
            if (request.url.contains('/checkout/success')) {
              _handleCheckoutSuccess(request.url);
              return NavigationDecision.prevent;
            }
            if (request.url.contains('/checkout/cancel')) {
              setState(() {
                _showWebView = false;
                _loading = false;
              });
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(url));

    setState(() {
      _showWebView = true;
      _loading = false;
    });
  }

  Future<void> _handleCheckoutSuccess(String successUrl) async {
    setState(() {
      _showWebView = false;
      _loading = true;
    });

    final redirectSessionId = Uri.tryParse(
      successUrl,
    )?.queryParameters['session_id'];
    final sessionId = redirectSessionId ?? _checkoutSessionId;
    if (sessionId == null || sessionId.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'Missing session ID — please try again';
      });
      return;
    }

    final provider = context.read<ChatProvider>();
    final success = await provider.verifyCheckoutSession(sessionId);

    if (!mounted) return;

    if (success) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _loading = false;
        _error = 'Could not verify payment. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_showWebView) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Subscribe'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () {
              setState(() {
                _showWebView = false;
                _loading = false;
              });
            },
          ),
        ),
        body: WebViewWidget(controller: _webViewController),
      );
    }

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Spacer(flex: 2),
              Icon(
                Icons.bolt,
                size: 64,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 16),
              Text(
                'SocketAgent',
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Sign in to relay Claude and Codex from your phone.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurface.withAlpha(180),
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 48),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.go,
                onSubmitted: (_) => _subscribe(),
                decoration: InputDecoration(
                  labelText: 'Email',
                  hintText: 'you@example.com',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.email_outlined),
                  errorText: _error,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: FilledButton(
                  onPressed: _loading ? null : _subscribe,
                  child: _loading
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Continue'),
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'Existing subscribers are signed in automatically.\nNew accounts get 7 days free, then \$5/month.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurface.withAlpha(120),
                ),
              ),
              const Spacer(flex: 3),
            ],
          ),
        ),
      ),
    );
  }
}
