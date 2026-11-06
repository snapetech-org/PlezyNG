import 'package:flutter_test/flutter_test.dart';
import 'package:in_app_purchase_platform_interface/in_app_purchase_platform_interface.dart';
import 'package:plezy/services/supporter/samsung_supporter_store.dart';
import 'package:plezy/services/supporter/supporter_mode.dart';
import 'package:plezy/services/supporter/supporter_service.dart';
import 'package:plezy/services/supporter/supporter_store.dart';

import '../../test_helpers/prefs.dart';
import '../../test_helpers/supporter_store_fakes.dart';

const owned = SamsungInvoice(productId: lifetimeUnlockProductId, invoiceId: 'invoice-1', cancelled: false);
const cancelled = SamsungInvoice(productId: lifetimeUnlockProductId, invoiceId: 'invoice-1', cancelled: true);

void main() {
  setUp(resetSharedPreferencesForTest);
  late FakeInAppPurchasePlatform platform;
  setUp(() {
    platform = FakeInAppPurchasePlatform();
    addTearDown(platform.close);
  });

  SamsungSupporterStore store(List<SamsungInvoice> invoices, {bool verified = true, bool success = true}) =>
      SamsungSupporterStore(
        platform,
        queryPage: (_) async => SamsungPurchasePage(success: success, hasNext: false, invoices: invoices),
        verifyInvoice: (_) async => verified,
      );

  test('only a verified active lifetime invoice grants ownership', () async {
    expect((await store([owned]).queryHistory()).ownership, SupporterOwnership.owned);
    await expectLater(store([owned], verified: false).queryHistory(), throwsA(isA<SupporterStoreUnavailable>()));
  });

  test('explicit cancellation revokes but empty account history is unknown', () async {
    expect((await store([cancelled]).queryHistory()).ownership, SupporterOwnership.revoked);
    expect((await store([]).queryHistory()).ownership, SupporterOwnership.unknown);
  });

  test('a failed or unavailable store query is never a refund', () async {
    await expectLater(store([], success: false).queryHistory(), throwsA(isA<SupporterStoreUnavailable>()));
    platform.available = false;
    await expectLater(store([cancelled]).queryHistory(), throwsA(isA<SupporterStoreUnavailable>()));
  });

  test('a newer active purchase on a later page overrides a cancelled invoice', () async {
    final pages = <int>[];
    final samsung = SamsungSupporterStore(
      platform,
      queryPage: (page) async {
        pages.add(page);
        return SamsungPurchasePage(success: true, hasNext: page == 1, invoices: page == 1 ? [cancelled] : [owned]);
      },
      verifyInvoice: (_) async => true,
    );
    expect((await samsung.queryHistory()).ownership, SupporterOwnership.owned);
    expect(pages, [1, 2]);
  });

  test('incomplete repeating history fails without revoking', () async {
    final samsung = SamsungSupporterStore(
      platform,
      queryPage: (_) async => const SamsungPurchasePage(success: true, hasNext: true, invoices: [cancelled]),
      verifyInvoice: (_) async => false,
    );
    await expectLater(samsung.queryHistory(), throwsA(isA<SupporterStoreUnavailable>()));
  });

  test('a purchase stream event cannot unlock before Samsung verifies its invoice', () async {
    final service = SupporterService.forTesting(
      availability: SupporterAvailability.purchasable,
      purchased: false,
      store: store([], verified: false),
    );
    addTearDown(service.dispose);
    await service.init();
    platform.deliver([
      PurchaseDetails(
        productID: lifetimeUnlockProductId,
        verificationData: PurchaseVerificationData(
          localVerificationData: '',
          serverVerificationData: 'invalid-invoice',
          source: 'samsung_checkout',
        ),
        transactionDate: null,
        status: PurchaseStatus.purchased,
      ),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(service.hasLifetimeUnlock, isFalse);
    expect(platform.completed, isEmpty);
  });
}
