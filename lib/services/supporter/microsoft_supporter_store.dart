import 'package:clock/clock.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_msstore/in_app_purchase_msstore.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';

import 'supporter_store.dart';

/// The Microsoft Store's online add-on collection is authoritative. Cached or
/// failed reads must not grant a new entitlement or erase our saved ownership.
class MicrosoftSupporterStore extends SupporterStore {
  MicrosoftSupporterStore(super.platform, {required this.productId, required this.readLicenses});

  final String productId;
  final Future<MsStoreAddOnLicenses> Function() readLicenses;

  @override
  bool acceptsProduct(ProductDetails product) =>
      product is MsStoreProductDetails && product.productKind == 'Durable' && !product.isSubscription;

  static MicrosoftSupporterStore? configured() {
    // Partner Center assigns a Store ID, unlike the product names on Apple,
    // Play and Amazon. An ordinary direct-download build has no such ID.
    if (!const bool.fromEnvironment('MSSTORE_BUILD') || !RegExp(r'^[A-Z0-9]{12}$').hasMatch(lifetimeUnlockProductId)) {
      return null;
    }
    final iap = InAppPurchase.instance;
    return MicrosoftSupporterStore(
      InAppPurchasePlatform.instance,
      productId: lifetimeUnlockProductId,
      readLicenses: iap.getPlatformAddition<InAppPurchaseMsStorePlatformAddition>().getAddOnLicenses,
    );
  }

  @override
  Future<SupporterHistory> queryHistory() async {
    if (!await platform.isAvailable()) throw const SupporterStoreUnavailable();
    final result = await readLicenses();
    if (!result.verifiedOnline || result.message != null) throw const SupporterStoreUnavailable();
    final licenses = result.licenses.where((license) => license.storeId == productId).toList();
    // A missing expiry is not evidence of a perpetual licence. Likewise, do
    // not treat malformed matching licence data as a confirmed revocation.
    if (licenses.any((license) => license.expirationDate == null)) throw const SupporterStoreUnavailable();
    final now = clock.now().toUtc();
    if (licenses.any((license) => license.isOwnedAt(now))) return const SupporterHistory(SupporterOwnership.owned);
    // The plugin reports verifiedOnline only for a complete online collection.
    // An absent/expired add-on in that collection confirms no current licence.
    return const SupporterHistory(SupporterOwnership.revoked);
  }

  @override
  Future<void> syncForRestore() async {
    // queryHistory reads the current Store account. Avoid replaying cached
    // restore-stream events as proof of a newly verified purchase.
  }

  @override
  bool isRevocation(PurchaseDetails purchase) => false;

  @override
  Future<bool> verifyPurchase(PurchaseDetails purchase) async =>
      purchase.productID == productId && (await queryHistory()).ownership == SupporterOwnership.owned;
}
