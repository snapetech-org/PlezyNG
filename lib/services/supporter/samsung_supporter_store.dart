import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';
import 'package:in_app_purchase_tizen/in_app_purchase_tizen.dart';

import 'supporter_store.dart';

const _dpiAppId = String.fromEnvironment('SAMSUNG_DPI_APP_ID');
const _dpiSecurityKey = String.fromEnvironment('SAMSUNG_DPI_SECURITY_KEY');

class SamsungInvoice {
  const SamsungInvoice({required this.productId, required this.invoiceId, required this.cancelled});
  final String productId;
  final String invoiceId;
  final bool cancelled;
}

class SamsungPurchasePage {
  const SamsungPurchasePage({required this.success, required this.hasNext, required this.invoices});
  final bool success;
  final bool hasNext;
  final List<SamsungInvoice> invoices;
}

/// Samsung Checkout uses verified invoices, including explicit cancellations.
/// A failed query or another Samsung account's empty history never revokes a
/// cached unlock. History reads do not replay restore events onto the stream.
class SamsungSupporterStore extends SupporterStore {
  SamsungSupporterStore(super.platform, {required this.queryPage, required this.verifyInvoice});

  final Future<SamsungPurchasePage> Function(int page) queryPage;
  final Future<bool> Function(String invoiceId) verifyInvoice;

  static SamsungSupporterStore? configured() {
    if (_dpiAppId.isEmpty || _dpiSecurityKey.isEmpty) return null;
    // Flutter-Tizen's generated registrant normally does this first. Keep the
    // store choice explicit because Dart reports the underlying OS as Linux.
    if (InAppPurchasePlatform.instance is! InAppPurchaseTizenPlatform) {
      InAppPurchaseTizenPlatform.register();
    }
    final iap = InAppPurchase.instance;
    iap.getPlatformAddition<InAppPurchaseTizenPlatformAddition>().setRequestParameters(
      appId: _dpiAppId,
      pageSize: 100,
      pageNum: 1,
      securityKey: _dpiSecurityKey,
    );
    BillingManager manager(int page) => BillingManager()
      ..setRequestParameters(
        RequestParameters()
          ..appId = _dpiAppId
          ..pageSize = 100
          ..pageNum = page
          ..securityKey = _dpiSecurityKey,
      );
    return SamsungSupporterStore(
      InAppPurchasePlatform.instance,
      queryPage: (page) async {
        final response = await manager(page).requestPurchases();
        return SamsungPurchasePage(
          success: response.cpStatus == '100000',
          hasNext: response.cpResult == 'hasNext:TRUE',
          invoices: [
            for (final invoice in response.invoiceDetails)
              if (invoice != null)
                SamsungInvoice(
                  productId: invoice['ItemID'] as String,
                  invoiceId: invoice['InvoiceID'] as String,
                  cancelled: invoice['CancelStatus'] as bool,
                ),
          ],
        );
      },
      verifyInvoice: (invoiceId) async {
        final response = await manager(1).verifyInvoice(invoiceId: invoiceId);
        return response.cpStatus == '100000' && response.appId == _dpiAppId && response.invoiceId == invoiceId;
      },
    );
  }

  @override
  Future<SupporterHistory> queryHistory() async {
    if (!await platform.isAvailable()) throw const SupporterStoreUnavailable();
    var cancelled = false;
    // Bound a broken/repeating remote pagination response; never infer a refund
    // from an incomplete history or an API error.
    for (var page = 1; page <= 100; page++) {
      final history = await queryPage(page);
      if (!history.success) throw const SupporterStoreUnavailable();
      for (final invoice in history.invoices) {
        if (invoice.productId != lifetimeUnlockProductId) continue;
        if (invoice.cancelled) {
          cancelled = true;
        } else if (invoice.invoiceId.isNotEmpty && await verifyInvoice(invoice.invoiceId)) {
          return const SupporterHistory(SupporterOwnership.owned);
        } else {
          throw const SupporterStoreUnavailable();
        }
      }
      if (!history.hasNext) {
        return SupporterHistory(cancelled ? SupporterOwnership.revoked : SupporterOwnership.unknown);
      }
    }
    throw const SupporterStoreUnavailable();
  }

  @override
  Future<void> syncForRestore() async {
    // queryHistory directly reads the current Samsung account's invoices.
  }

  @override
  Future<bool> verifyPurchase(PurchaseDetails purchase) =>
      purchase.productID == lifetimeUnlockProductId && purchase.verificationData.serverVerificationData.isNotEmpty
      ? verifyInvoice(purchase.verificationData.serverVerificationData)
      : Future.value(false);

  @override
  bool isRevocation(PurchaseDetails purchase) => false;
}
