import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../config/app_distribution.dart';
import '../services/chat_provider.dart';
import '../services/play_billing_service.dart';

class PaywallScreen extends StatefulWidget {
  const PaywallScreen({super.key});

  @override
  State<PaywallScreen> createState() => _PaywallScreenState();
}

class _PaywallScreenState extends State<PaywallScreen> {
  final PlayBillingService _billing = PlayBillingService.instance;
  final TextEditingController _emailController = TextEditingController();
  StreamSubscription<PlayBillingEvent>? _eventSubscription;
  bool _ownerLoading = false;
  bool _reviewLoading = false;
  bool _directLoading = false;
  bool _showDirectCheckout = false;
  String? _directCheckoutSessionId;
  WebViewController? _directCheckoutController;
  String? _message;

  @override
  void initState() {
    super.initState();
    _billing.addListener(_onBillingChanged);
    _eventSubscription = _billing.events.listen(_handleBillingEvent);
  }

  @override
  void dispose() {
    _eventSubscription?.cancel();
    _billing.removeListener(_onBillingChanged);
    _emailController.dispose();
    super.dispose();
  }

  void _onBillingChanged() {
    if (mounted) setState(() {});
  }

  void _handleBillingEvent(PlayBillingEvent event) {
    if (!mounted) return;
    if (event.type == PlayBillingEventType.accessGranted) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _message = event.message);
  }

  Future<void> _openPlayStore() async {
    final opened = await PlayBillingService.openPlayStoreListing();
    if (!opened && mounted) {
      setState(() => _message = 'Could not open SocketAgent in Google Play.');
    }
  }

  Future<void> _restore() async {
    setState(() => _message = null);
    await _billing.restore();
  }

  Future<void> _startDirectCheckout() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() => _message = 'Enter your email address.');
      return;
    }
    setState(() {
      _directLoading = true;
      _message = null;
    });

    final result = await context
        .read<ChatProvider>()
        .createDirectCheckoutSession(email);
    if (!mounted) return;
    final error = result['error'] as String?;
    final url = result['url'] as String?;
    final sessionId = result['sessionId'] as String?;
    if (error != null || url == null || sessionId == null) {
      setState(() {
        _directLoading = false;
        _message = error ?? 'The relay did not return a checkout session.';
      });
      return;
    }

    _directCheckoutSessionId = sessionId;
    _directCheckoutController = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            if (uri?.path == '/checkout/direct/success') {
              unawaited(_finishDirectCheckout());
              return NavigationDecision.prevent;
            }
            if (uri?.path == '/checkout/direct/cancel') {
              setState(() {
                _showDirectCheckout = false;
                _directLoading = false;
              });
              return NavigationDecision.prevent;
            }
            return NavigationDecision.navigate;
          },
        ),
      )
      ..loadRequest(Uri.parse(url));
    setState(() {
      _showDirectCheckout = true;
      _directLoading = false;
    });
  }

  Future<void> _finishDirectCheckout() async {
    if (_directLoading) return;
    final sessionId = _directCheckoutSessionId;
    if (sessionId == null) return;
    setState(() {
      _showDirectCheckout = false;
      _directLoading = true;
      _message = null;
    });
    final error = await context
        .read<ChatProvider>()
        .verifyDirectCheckoutSession(sessionId);
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _directLoading = false;
      _message = error;
    });
  }

  Future<void> _showOwnerAccess() async {
    final controller = TextEditingController();
    final ownerCode = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Owner access'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Owner code'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (ownerCode == null || ownerCode.isEmpty || !mounted) return;

    setState(() {
      _ownerLoading = true;
      _message = null;
    });
    final error = await context.read<ChatProvider>().requestOwnerAccess(
      ownerCode,
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _ownerLoading = false;
      _message = error;
    });
  }

  Future<void> _showReviewAccess() async {
    final controller = TextEditingController();
    final reviewCode = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Play review access'),
        content: TextField(
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Review code'),
          onSubmitted: (value) => Navigator.pop(dialogContext, value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (reviewCode == null || reviewCode.isEmpty || !mounted) return;

    setState(() {
      _reviewLoading = true;
      _message = null;
    });
    final error = await context.read<ChatProvider>().requestPlayReviewAccess(
      reviewCode,
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _reviewLoading = false;
      _message = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isPlay = AppBuild.supportsPlayBilling;
    if (_showDirectCheckout && _directCheckoutController != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          title: const Text('Subscribe'),
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () {
              setState(() {
                _showDirectCheckout = false;
                _directLoading = false;
              });
            },
          ),
        ),
        body: WebViewWidget(controller: _directCheckoutController!),
      );
    }
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('Relay access'),
      ),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 480),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.bolt,
                    size: 58,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(height: 18),
                  Text(
                    isPlay
                        ? 'Use SocketAgent away from home'
                        : 'Subscribe to relay access',
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    isPlay
                        ? 'Connect to your computers through the encrypted relay.'
                        : 'Direct subscriptions are handled securely by Stripe.',
                    style: TextStyle(color: Colors.white.withAlpha(175)),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 36),
                  if (isPlay) _buildPlayActions() else _buildDirectActions(),
                  if (isPlay) ...[
                    const SizedBox(height: 12),
                    _buildReviewAccessAction(),
                  ],
                  const SizedBox(height: 8),
                  _buildOwnerAccessAction(),
                  if (_message != null) ...[
                    const SizedBox(height: 18),
                    Text(
                      _message!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlayActions() {
    if (_billing.loading && _billing.product == null) {
      return const CircularProgressIndicator(strokeWidth: 2);
    }

    if (_billing.product == null) {
      return Column(
        children: [
          Text(
            _billing.error ?? 'The subscription is not available.',
            style: const TextStyle(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _billing.loading ? null : _billing.refreshProducts,
            child: const Text('Try again'),
          ),
        ],
      );
    }

    final price = _billing.renewalPrice ?? _billing.product!.price;
    final actionText = _billing.includesFreeTrial
        ? 'Start ${_billing.trialPeriodLabel} free'
        : 'Subscribe for $price';
    final terms = _billing.includesFreeTrial
        ? 'Then $price per ${_billing.renewalPeriodLabel}. Cancel anytime in Google Play.'
        : '$price per ${_billing.renewalPeriodLabel}. Cancel anytime in Google Play.';

    return Column(
      children: [
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton(
            onPressed: _billing.purchaseInProgress ? null : _billing.purchase,
            child: _billing.purchaseInProgress
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Text(actionText),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          terms,
          style: TextStyle(fontSize: 12, color: Colors.white.withAlpha(145)),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: _billing.purchaseInProgress || _billing.restoring
              ? null
              : _restore,
          child: Text(
            _billing.restoring
                ? 'Checking Google Play…'
                : 'Restore Google Play purchase',
          ),
        ),
      ],
    );
  }

  Widget _buildReviewAccessAction() {
    return TextButton(
      onPressed: _reviewLoading ? null : _showReviewAccess,
      child: _reviewLoading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('Play reviewer access'),
    );
  }

  Widget _buildOwnerAccessAction() {
    return TextButton(
      onPressed: _ownerLoading ? null : _showOwnerAccess,
      child: _ownerLoading
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Text('Owner access'),
    );
  }

  Widget _buildDirectActions() {
    return Column(
      children: [
        TextField(
          controller: _emailController,
          keyboardType: TextInputType.emailAddress,
          textInputAction: TextInputAction.go,
          autofillHints: const [AutofillHints.email],
          onSubmitted: (_) => _startDirectCheckout(),
          decoration: const InputDecoration(
            labelText: 'Email',
            hintText: 'you@example.com',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.email_outlined),
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          height: 50,
          child: FilledButton(
            onPressed: _directLoading ? null : _startDirectCheckout,
            child: _directLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Start 7-day free trial'),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'Stripe shows the renewal price before you confirm. Cancel anytime.',
          style: TextStyle(fontSize: 12, color: Colors.white.withAlpha(145)),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: _openPlayStore,
          child: const Text('Use Google Play instead'),
        ),
      ],
    );
  }
}
