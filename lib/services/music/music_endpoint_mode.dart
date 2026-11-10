/// Linux music receiver process. The same profile, queue, player and paired
/// command channel are used as in the normal app; the Linux runner hides its
/// Flutter window while the profile gate still decides whether it can host.
class MusicEndpointMode {
  MusicEndpointMode._();

  static bool enabled = false;

  static bool shouldStartHost({required bool offline, required bool enabledBySetting}) =>
      (enabledBySetting || enabled) && (!offline || enabled);
}
