import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:url_launcher/url_launcher.dart';

import '../config/app_distribution.dart';

typedef PlayPurchaseVerifier =
    Future<String?> Function(String purchaseToken, String productId);

enum PlayBillingEventType {
  pending,
  accessGranted,
  canceled,
  error,
  nothingToRestore,
}

class PlayBillingEvent {
  const PlayBillingEvent(this.type, this.message);

  final PlayBillingEventType type;
  final String message;
}

/// Owns the Google Play purchase stream for the lifetime of the app.
class PlayBillingService extends ChangeNotifier {
  PlayBillingService._();

  static final instance = PlayBillingService._();

  static const packageName = 'com.socketagent.app';
  static const subscriptionId = 'socketagent_relay';
  static const trialOfferId = 'seven-day-trial';

  final InAppPurchase _store = InAppPurchase.instance;
  final StreamController<PlayBillingEvent> _events =
      StreamController<PlayBillingEvent>.broadcast();
  final Set<String> _verificationInFlight = <String>{};

  StreamSubscription<List<PurchaseDetails>>? _purchaseSubscription;
  Timer? _restoreTimer;
  PlayPurchaseVerifier? _verifier;
  ProductDetails? _product;
  bool _initialized = false;
  bool _loading = false;
  bool _available = false;
  bool _purchaseInProgress = false;
  bool _restoring = false;
  String? _error;

  Stream<PlayBillingEvent> get events => _events.stream;
  ProductDetails? get product => _product;
  bool get loading => _loading;
  bool get available => _available;
  bool get purchaseInProgress => _purchaseInProgress;
  bool get restoring => _restoring;
  String? get error => _error;

  String? get renewalPrice {
    final offer = _selectedOffer;
    if (offer == null || offer.pricingPhases.isEmpty) return _product?.price;
    return offer.pricingPhases.last.formattedPrice;
  }

  bool get includesFreeTrial {
    final offer = _selectedOffer;
    if (offer == null || offer.pricingPhases.isEmpty) return false;
    return offer.offerId == trialOfferId &&
        offer.pricingPhases.first.priceAmountMicros == 0;
  }

  String get renewalPeriodLabel {
    final offer = _selectedOffer;
    if (offer == null || offer.pricingPhases.isEmpty) return 'billing period';
    return _periodLabel(offer.pricingPhases.last.billingPeriod);
  }

  String get trialPeriodLabel {
    final offer = _selectedOffer;
    if (offer == null || offer.pricingPhases.isEmpty) return 'trial';
    return _trialPeriodLabel(offer.pricingPhases.first.billingPeriod);
  }

  SubscriptionOfferDetailsWrapper? get _selectedOffer {
    final product = _product;
    if (product is! GooglePlayProductDetails) return null;
    final offers = product.productDetails.subscriptionOfferDetails;
    final index = product.subscriptionIndex;
    if (offers == null || index == null || index >= offers.length) return null;
    return offers[index];
  }

  void initialize(PlayPurchaseVerifier verifier) {
    if (!AppBuild.supportsPlayBilling) return;
    _verifier = verifier;
    if (_initialized) return;
    _initialized = true;
    _purchaseSubscription = _store.purchaseStream.listen(
      _handlePurchaseUpdates,
      onError: (Object error, StackTrace stackTrace) {
        _setError('Google Play purchase updates failed. Try again.');
      },
    );
    unawaited(refreshProducts());
  }

  @override
  void dispose() {
    _restoreTimer?.cancel();
    unawaited(_purchaseSubscription?.cancel());
    unawaited(_events.close());
    super.dispose();
  }

  Future<void> refreshProducts() async {
    if (!AppBuild.supportsPlayBilling || _loading) return;
    _loading = true;
    _error = null;
    notifyListeners();

    try {
      _available = await _store.isAvailable();
      if (!_available) {
        _error = 'Google Play Billing is not available on this device.';
        return;
      }

      final response = await _store.queryProductDetails(<String>{
        subscriptionId,
      });
      if (response.error != null) {
        _error = response.error!.message;
        return;
      }
      if (response.productDetails.isEmpty) {
        _error = 'The SocketAgent subscription is not available yet.';
        return;
      }
      _product = _chooseProduct(response.productDetails);
    } catch (error) {
      _error = 'Could not reach Google Play Billing.';
      debugPrint('[PlayBilling] Product query failed: $error');
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> purchase() async {
    final product = _product;
    if (product == null || _purchaseInProgress) return;
    _purchaseInProgress = true;
    _error = null;
    notifyListeners();

    try {
      final started = await _store.buyNonConsumable(
        purchaseParam: PurchaseParam(productDetails: product),
      );
      if (!started) {
        _purchaseInProgress = false;
        _setError('Google Play could not start the purchase.');
      }
    } catch (error) {
      _purchaseInProgress = false;
      debugPrint('[PlayBilling] Purchase launch failed: $error');
      _setError('Google Play could not start the purchase.');
    }
  }

  Future<void> restore() async {
    if (_restoring) return;
    _restoring = true;
    _error = null;
    notifyListeners();
    _restoreTimer?.cancel();
    _restoreTimer = Timer(const Duration(seconds: 20), () {
      if (!_restoring) return;
      _restoring = false;
      notifyListeners();
      _events.add(
        const PlayBillingEvent(
          PlayBillingEventType.nothingToRestore,
          'No active Google Play subscription was found.',
        ),
      );
    });
    try {
      await _store.restorePurchases();
    } catch (error) {
      _restoreTimer?.cancel();
      _restoring = false;
      debugPrint('[PlayBilling] Restore failed: $error');
      _setError('Could not restore Google Play purchases.');
    }
  }

  Future<void> _handlePurchaseUpdates(List<PurchaseDetails> purchases) async {
    if (_restoring) _restoreTimer?.cancel();
    if (purchases.isEmpty && _restoring) {
      _restoring = false;
      notifyListeners();
      _events.add(
        const PlayBillingEvent(
          PlayBillingEventType.nothingToRestore,
          'No active Google Play subscription was found.',
        ),
      );
      return;
    }

    for (final purchase in purchases) {
      if (purchase.productID.isNotEmpty &&
          purchase.productID != subscriptionId) {
        continue;
      }

      switch (purchase.status) {
        case PurchaseStatus.pending:
          _purchaseInProgress = true;
          _events.add(
            const PlayBillingEvent(
              PlayBillingEventType.pending,
              'Google Play is still processing this purchase.',
            ),
          );
          break;
        case PurchaseStatus.purchased:
        case PurchaseStatus.restored:
          await _verifyAndComplete(purchase);
          break;
        case PurchaseStatus.canceled:
          _purchaseInProgress = false;
          _restoring = false;
          notifyListeners();
          _events.add(
            const PlayBillingEvent(
              PlayBillingEventType.canceled,
              'Purchase canceled.',
            ),
          );
          break;
        case PurchaseStatus.error:
          _purchaseInProgress = false;
          _restoring = false;
          final message = purchase.error?.message.trim();
          _setError(
            message == null || message.isEmpty
                ? 'Google Play could not complete the purchase.'
                : message,
          );
      }
    }
  }

  Future<void> _verifyAndComplete(PurchaseDetails purchase) async {
    final purchaseToken = purchase.verificationData.serverVerificationData
        .trim();
    final verifier = _verifier;
    if (purchaseToken.isEmpty || verifier == null) {
      _setError('The purchase did not include a verification token.');
      return;
    }
    if (!_verificationInFlight.add(purchaseToken)) return;

    try {
      final verificationError = await verifier(
        purchaseToken,
        purchase.productID.isEmpty ? subscriptionId : purchase.productID,
      );
      if (verificationError != null) {
        _setError(verificationError);
        return;
      }

      if (purchase.pendingCompletePurchase) {
        await _store.completePurchase(purchase);
      }
      _purchaseInProgress = false;
      _restoring = false;
      _restoreTimer?.cancel();
      _error = null;
      notifyListeners();
      _events.add(
        const PlayBillingEvent(
          PlayBillingEventType.accessGranted,
          'Relay access is active.',
        ),
      );
    } catch (error) {
      debugPrint('[PlayBilling] Verification failed: $error');
      _setError('The relay could not verify this Google Play purchase.');
    } finally {
      _verificationInFlight.remove(purchaseToken);
    }
  }

  void _setError(String message) {
    _purchaseInProgress = false;
    _restoring = false;
    _error = message;
    notifyListeners();
    _events.add(PlayBillingEvent(PlayBillingEventType.error, message));
  }

  ProductDetails _chooseProduct(List<ProductDetails> products) {
    for (final product in products) {
      if (product is! GooglePlayProductDetails) continue;
      final offers = product.productDetails.subscriptionOfferDetails;
      final index = product.subscriptionIndex;
      if (offers == null || index == null || index >= offers.length) continue;
      if (offers[index].offerId == trialOfferId) return product;
    }

    for (final product in products) {
      if (product is! GooglePlayProductDetails) continue;
      final offers = product.productDetails.subscriptionOfferDetails;
      final index = product.subscriptionIndex;
      if (offers == null || index == null || index >= offers.length) continue;
      if (offers[index].offerId == null) return product;
    }
    return products.first;
  }

  static Future<bool> openSubscriptionManagement() {
    final uri = Uri.parse(
      'https://play.google.com/store/account/subscriptions'
      '?sku=$subscriptionId&package=$packageName',
    );
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  static Future<bool> openPlayStoreListing() {
    final uri = Uri.parse(
      'https://play.google.com/store/apps/details?id=$packageName',
    );
    return launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  String _periodLabel(String isoPeriod) {
    return switch (isoPeriod) {
      'P1W' => 'week',
      'P1M' => 'month',
      'P3M' => '3 months',
      'P6M' => '6 months',
      'P1Y' => 'year',
      _ => 'billing period',
    };
  }

  String _trialPeriodLabel(String isoPeriod) {
    final daysMatch = RegExp(r'^P(\d+)D$').firstMatch(isoPeriod);
    if (daysMatch != null) return '${daysMatch.group(1)} days';
    final weeksMatch = RegExp(r'^P(\d+)W$').firstMatch(isoPeriod);
    if (weeksMatch != null) return '${weeksMatch.group(1)} weeks';
    return 'trial';
  }
}
