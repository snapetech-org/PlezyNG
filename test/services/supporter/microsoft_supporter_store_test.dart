import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_msstore/in_app_purchase_msstore.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';
import 'package:plezy/services/supporter/microsoft_supporter_store.dart';
import 'package:plezy/services/supporter/supporter_store.dart';

import '../../test_helpers/supporter_store_fakes.dart';

void main() {
  const id = '9TESTPRODUCT';
  final now = DateTime.utc(2026, 11, 5);
  late FakeInAppPurchasePlatform platform;
  late MicrosoftSupporterStore store;
  late MsStoreAddOnLicenses licenses;
  setUp(() {
    platform = FakeInAppPurchasePlatform();
    licenses = const MsStoreAddOnLicenses(licenses: [], verifiedOnline: true);
    store = MicrosoftSupporterStore(platform, productId: id, readLicenses: () async => licenses);
  });
  tearDown(() async => platform.close());

  MsStoreAddOnLicense license({String productId = id, DateTime? expiry}) =>
      MsStoreAddOnLicense(storeId: productId, isActive: true, expirationDate: expiry);

  test('only matching unexpired online ownership grants lifetime access', () async {
    licenses = MsStoreAddOnLicenses(
      licenses: [license(productId: '9OTHERPRODUCT', expiry: now.add(const Duration(days: 100)))],
      verifiedOnline: true,
    );
    expect((await store.queryHistory()).ownership, SupporterOwnership.revoked);
    licenses = MsStoreAddOnLicenses(
      licenses: [license(expiry: now.add(const Duration(days: 100)))],
      verifiedOnline: true,
    );
    await withClock(Clock.fixed(now), () async {
      expect((await store.queryHistory()).ownership, SupporterOwnership.owned);
    });
  });

  test('expired online license is revoked even when Store IsActive is true', () async {
    licenses = MsStoreAddOnLicenses(
      licenses: [license(expiry: now.subtract(const Duration(seconds: 1)))],
      verifiedOnline: true,
    );
    await withClock(Clock.fixed(now), () async {
      expect((await store.queryHistory()).ownership, SupporterOwnership.revoked);
    });
  });

  test('cached, incomplete, malformed and failed histories do not erase ownership', () async {
    for (final answer in [
      const MsStoreAddOnLicenses(licenses: [], verifiedOnline: false),
      const MsStoreAddOnLicenses(licenses: [], verifiedOnline: true, message: 'Incomplete collection'),
      MsStoreAddOnLicenses(licenses: [license()], verifiedOnline: true),
    ]) {
      licenses = answer;
      await expectLater(store.queryHistory(), throwsA(isA<SupporterStoreUnavailable>()));
    }
    platform.available = false;
    await expectLater(store.queryHistory(), throwsA(isA<SupporterStoreUnavailable>()));
  });

  test('purchase stream success alone cannot unlock the app', () async {
    final purchase = MsStorePurchaseDetails(productID: id, transactionDate: null, status: PurchaseStatus.purchased);
    expect(await store.verifyPurchase(purchase), isFalse);
    licenses = MsStoreAddOnLicenses(
      licenses: [license(expiry: now.add(const Duration(days: 100)))],
      verifiedOnline: true,
    );
    await withClock(Clock.fixed(now), () async {
      expect(await store.verifyPurchase(purchase), isTrue);
      expect(
        await store.verifyPurchase(
          MsStorePurchaseDetails(productID: 'wrong', transactionDate: null, status: PurchaseStatus.purchased),
        ),
        isFalse,
      );
    });
  });

  test('lifetime product rejects consumables and subscriptions', () {
    MsStoreProductDetails product(String kind, {bool subscription = false}) => MsStoreProductDetails(
      id: id,
      title: 'Lifetime',
      description: 'All features',
      price: r'$2.99',
      rawPrice: 2.99,
      currencyCode: 'USD',
      productKind: kind,
      isSubscription: subscription,
    );
    expect(store.acceptsProduct(product('Durable')), isTrue);
    expect(store.acceptsProduct(product('Consumable')), isFalse);
    expect(store.acceptsProduct(product('Durable', subscription: true)), isFalse);
  });
}
