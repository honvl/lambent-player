/// Switches for Moonfin-owned surfaces that Lambent does not ship.
///
/// Flip a value to `true` to bring the surface back. Both default to off
/// because they point at the original Moonfin project (its donation page,
/// Discord, issue tracker and GitHub releases), not at Lambent.
class LambentBrand {
  const LambentBrand._();

  /// About screen rows that send the user to Moonfin's developer: "Join the
  /// Discord", "Support Moonfin" (Buy Me a Coffee) and "Report an issue"
  /// (Moonfin-Client issue tracker). Also hides the privacy policy row, which
  /// opens moonfin.io/privacy; point it at a Lambent policy before re-enabling
  /// it for Lambent.
  static const bool showMoonfinDeveloperLinks = false;

  /// The in-app update check (startup banner, About "Check for updates" row,
  /// settings search entry). It reads Moonfin-Client's GitHub releases, so it
  /// would offer Moonfin builds over Lambent ones.
  static const bool enableAppUpdateCheck = false;
}
