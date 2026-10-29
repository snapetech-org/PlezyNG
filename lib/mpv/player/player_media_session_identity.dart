/// Optional identity for player backends that can detect media replacement.
///
/// Long-running subtitle and analysis work can finish after the player has
/// opened another item. Consumers snapshot this generation before starting and
/// compare it again before attaching results to the player.
abstract interface class PlayerMediaSessionIdentity {
  int get mediaSessionGeneration;
}
