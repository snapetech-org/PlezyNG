// Only the source-pinned CMsgClientSettings.cloud_enabled field (10000).
export function decodeCloud(buffer) {
  const bytes = new Uint8Array(buffer);
  if (bytes.length > 65536) throw Error('settings too large');
  let offset = 0, found;
  function varint() {
    let n = 0n;
    for (let i = 0; i < 10 && offset < bytes.length; i++) {
      const b = bytes[offset++];
      n |= BigInt(b & 127) << BigInt(i * 7);
      if (!(b & 128)) return n;
    }
    throw Error('invalid varint');
  }
  while (offset < bytes.length) {
    const tag = varint(), field = tag >> 3n, wire = Number(tag & 7n);
    if (field === 0n) throw Error('invalid field');
    if (field === 10000n) {
      if (wire !== 0 || found !== undefined) throw Error('invalid cloud field');
      const value = varint();
      if (value > 1n) throw Error('invalid boolean');
      found = value === 1n;
    } else if (wire === 0) varint();
    else if (wire === 1) offset += 8;
    else if (wire === 5) offset += 4;
    else if (wire === 2) {
      const length = varint();
      if (length > 65536n) throw Error('invalid length');
      offset += Number(length);
    } else throw Error('unsupported field');
    if (offset > bytes.length) throw Error('truncated settings');
  }
  return found; // Missing is unknown, never false.
}

export function createCloudController(steam, timeoutMs = 4000) {
  if (typeof steam?.User?.RegisterForCurrentUserChanges !== 'function' ||
      typeof steam?.User?.RegisterForLoginStateChange !== 'function' ||
      typeof steam?.Settings?.RegisterForSettingsArrayChanges !== 'function' ||
      typeof steam?.Settings?.SetSetting !== 'function') {
    return {supported: false, async execute() { return {status: 'unavailable'}; }, dispose() {}};
  }
  let account, value, epoch = 0, sequence = 0, disposed = false, busy = false;
  let subscription, wake;
  const invalidate = () => {
    epoch++; value = undefined;
    subscription?.unregister(); subscription = undefined;
    wake?.();
  };
  const loginSubscription = steam.User.RegisterForLoginStateChange((_name, state) => {
    // Source-pinned ELoginState.Success = 7; progress/logout invalidates identity.
    if (!disposed && state !== 7) { invalidate(); account = undefined; }
  });
  steam.User.RegisterForCurrentUserChanges(user => {
    if (disposed) return;
    const next = /^7656119\d{10}$/.test(user?.strSteamID ?? '') && !user.bIsOfflineMode ? user.strSteamID : undefined;
    if (next === account) return;
    invalidate(); account = next;
    if (!account) return;
    const generation = epoch;
    subscription = steam.Settings.RegisterForSettingsArrayChanges(data => {
      if (disposed || generation !== epoch) return;
      try { value = decodeCloud(data); } catch { value = undefined; }
      sequence++; wake?.();
    });
  });
  return {
    supported: true,
    async execute(request, claim, allowed) {
      const valid = () => !disposed && allowed() && account === request.steamId && typeof value === 'boolean';
      if (busy || !valid()) return {status: 'unavailable'};
      busy = true;
      const generation = epoch;
      try {
        if (!await claim() || !valid() || generation !== epoch) return {status: 'unavailable'};
        if (request.op === 'read') return {status: 'observed', steamId: account, enabled: value};
        if (request.op !== 'set' || typeof request.expected !== 'boolean' || typeof request.enabled !== 'boolean') return {status: 'denied'};
        if (value !== request.expected) return {status: 'stale'};
        if (value === request.enabled) return {status: 'observed', steamId: account, enabled: value};
        const before = sequence;
        let timer, check, expire;
        const expired = new Promise(resolve => { expire = () => resolve(undefined); });
        const observed = new Promise(resolve => {
          check = () => {
            if (!valid() || epoch !== generation) resolve(false);
            else if (sequence > before && value === request.enabled) resolve(true);
          };
          wake = check;
          timer = setTimeout(() => { expire(); resolve(false); }, timeoutMs);
        });
        try {
          // Varint field key 80000 = 80 f1 04; only the requested boolean follows.
          const accepted = await Promise.race([
            steam.Settings.SetSetting(request.enabled ? 'gPEEAQ==' : 'gPEEAA=='),
            expired,
          ]);
          check();
          if (accepted !== true || !await observed || !valid() || epoch !== generation) return {status: 'unknown'};
          return {status: 'observed', steamId: account, enabled: value};
        } catch { return {status: 'unknown'}; }
        finally { clearTimeout(timer); wake = undefined; }
      } finally { busy = false; }
    },
    dispose() { disposed = true; invalidate(); loginSubscription?.unregister(); },
  };
}
