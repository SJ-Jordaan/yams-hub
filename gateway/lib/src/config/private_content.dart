/// The optional "private content" settings (ARCHITECTURE §5.2): Jellyfin
/// libraries and users, qBittorrent categories and a Prowlarr tag the hub
/// never shows to anyone, admins included.
library;

/// `PRIVATE_JELLYFIN_LIBRARIES`, `PRIVATE_JELLYFIN_USERS`,
/// `PRIVATE_QBIT_CATEGORIES` and `PRIVATE_PROWLARR_TAG`. Every name is
/// compared case-insensitively; the sets hold lower-case, trimmed names.
final class PrivateContentSettings {
  const PrivateContentSettings({
    this.jellyfinLibraries = const {},
    this.jellyfinUsers = const {},
    this.qbitCategories = const {},
    this.prowlarrTag,
  });

  /// Parses the comma-separated variables (null or empty: none).
  factory PrivateContentSettings.parse({
    String? jellyfinLibraries,
    String? jellyfinUsers,
    String? qbitCategories,
    String? prowlarrTag,
  }) {
    final tag = prowlarrTag?.trim().toLowerCase() ?? '';
    return PrivateContentSettings(
      jellyfinLibraries: _names(jellyfinLibraries),
      jellyfinUsers: _names(jellyfinUsers),
      qbitCategories: _names(qbitCategories),
      prowlarrTag: tag.isEmpty ? null : tag,
    );
  }

  /// Nothing is private (every setting unset).
  static const none = PrivateContentSettings();

  /// Lower-case Jellyfin library (virtual folder) names.
  final Set<String> jellyfinLibraries;

  /// Lower-case Jellyfin user names.
  final Set<String> jellyfinUsers;

  /// Lower-case qBittorrent categories.
  final Set<String> qbitCategories;

  /// Lower-case Prowlarr tag label.
  final String? prowlarrTag;

  bool get hasLibraries => jellyfinLibraries.isNotEmpty;
  bool get hasUsers => jellyfinUsers.isNotEmpty;
  bool get hasCategories => qbitCategories.isNotEmpty;
  bool get hasProwlarrTag => prowlarrTag != null;

  /// Any setting is in use.
  bool get any => hasLibraries || hasUsers || hasCategories || hasProwlarrTag;

  bool isPrivateLibrary(String? name) =>
      name != null && jellyfinLibraries.contains(name.trim().toLowerCase());

  bool isPrivateUser(String? name) =>
      name != null && jellyfinUsers.contains(name.trim().toLowerCase());

  bool isPrivateCategory(String? category) =>
      category != null &&
      qbitCategories.contains(category.trim().toLowerCase());

  bool isPrivateTag(String? label) =>
      prowlarrTag != null &&
      label != null &&
      label.trim().toLowerCase() == prowlarrTag;

  static Set<String> _names(String? text) => {
    for (final n in (text ?? '').split(','))
      if (n.trim().isNotEmpty) n.trim().toLowerCase(),
  };
}
