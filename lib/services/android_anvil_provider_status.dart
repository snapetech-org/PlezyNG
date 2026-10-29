enum AndroidAnvilProviderState { initializing, ready, active, failed }

AndroidAnvilProviderState androidAnvilProviderState(String? provider) {
  final status = provider?.trim().toLowerCase();
  if (status == null || status.isEmpty || status == 'initializing') {
    return AndroidAnvilProviderState.initializing;
  }

  if (const {'off', 'unavailable', 'failed', 'error', 'cpu', 'cpu-fallback', 'cpuexecutionprovider'}.contains(status) ||
      status.endsWith('-unavailable') ||
      status.endsWith('-failed') ||
      status.endsWith('-error') ||
      status.endsWith('-cpu')) {
    return AndroidAnvilProviderState.failed;
  }

  if (status == 'ready' || status.endsWith('-ready')) {
    return AndroidAnvilProviderState.ready;
  }

  if (status == 'active' ||
      RegExp(r'^qnn-htp-v\d+$').hasMatch(status) ||
      const {'litert-npu', 'litert-gpu'}.contains(status)) {
    return AndroidAnvilProviderState.active;
  }

  return AndroidAnvilProviderState.initializing;
}
