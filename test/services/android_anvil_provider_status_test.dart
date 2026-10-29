import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/services/android_anvil_provider_status.dart';

void main() {
  group('androidAnvilProviderState', () {
    test('keeps missing and initializing providers pending', () {
      expect(androidAnvilProviderState(null), AndroidAnvilProviderState.initializing);
      expect(androidAnvilProviderState(''), AndroidAnvilProviderState.initializing);
      expect(androidAnvilProviderState('initializing'), AndroidAnvilProviderState.initializing);
    });

    test('distinguishes initialized sessions from successful inference', () {
      expect(androidAnvilProviderState('qnn-htp-v73-ready'), AndroidAnvilProviderState.ready);
      expect(androidAnvilProviderState('litert-npu-ready'), AndroidAnvilProviderState.ready);
      expect(androidAnvilProviderState('litert-gpu-ready'), AndroidAnvilProviderState.ready);
      expect(androidAnvilProviderState('qnn-htp-v73'), AndroidAnvilProviderState.active);
      expect(androidAnvilProviderState('litert-npu'), AndroidAnvilProviderState.active);
    });

    test('marks unavailable and CPU providers failed', () {
      expect(androidAnvilProviderState('unavailable'), AndroidAnvilProviderState.failed);
      expect(androidAnvilProviderState('litert-npu-failed'), AndroidAnvilProviderState.failed);
      expect(androidAnvilProviderState('error'), AndroidAnvilProviderState.failed);
      expect(androidAnvilProviderState('cpu-fallback'), AndroidAnvilProviderState.failed);
    });
  });
}
