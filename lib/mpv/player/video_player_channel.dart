const int nativeVideoPlayerSlotCount = 4;

String videoPlayerChannelBase(String channelBase, int slot) {
  if (slot < 0 || slot >= nativeVideoPlayerSlotCount) {
    throw RangeError.range(slot, 0, nativeVideoPlayerSlotCount - 1, 'videoPlayerSlot');
  }
  return switch (slot) {
    0 => channelBase,
    1 => '$channelBase/workspace',
    _ => '$channelBase/workspace/$slot',
  };
}
