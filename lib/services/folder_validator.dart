import 'dart:io';
import 'package:path/path.dart' as p;

/// Validates user-picked folders before the app commits to using them for
/// media scanning or exports.
///
/// The crash case this defends against: Windows presents OneDrive / Dropbox
/// / iCloud / Google Drive folders as ordinary directories, but:
///   * they can be "online-only" placeholders (0 bytes on disk, streamed
///     lazily), which makes `Directory.list()` throw on first access
///   * the native file_picker plugin occasionally crashes the whole process
///     when the user backs out of a cloud-synced directory dialog
///   * writing an export there triggers a cloud upload that can fail in
///     subtle ways (quota, offline)
///
/// None of this is recoverable in-app, and a hard crash is the worst
/// possible UX. We just refuse cloud paths upfront with a clear message.
class FolderValidator {
  FolderValidator._();

  /// Returns `null` if the folder is safe to use. Otherwise returns a
  /// user-facing German error message explaining why.
  static String? validate(String path) {
    // Basic existence check — if the picker returned something that no
    // longer exists (drive unmounted between pick and validate), tell the
    // user instead of letting the next `Directory.list` blow up.
    if (!Directory(path).existsSync()) {
      return 'Ordner existiert nicht (mehr):\n$path';
    }

    // Cloud-sync detection and the Windows-path hint are desktop-only.
    // On iOS the path is always the sandboxed Documents directory,
    // which lives under /var/mobile/... — we trust it implicitly.
    if (Platform.isIOS) return null;

    final cloudProvider = _detectCloudProvider(path);
    if (cloudProvider != null) {
      return 'Dieser Ordner liegt in $cloudProvider.\n\n'
          'BeefburgerStreaming unterstützt nur lokale Ordner — Cloud-Ordner '
          'werden unzuverlässig gelesen (Dateien können "online-only" sein) '
          'und können bei großen Bibliotheken die App abstürzen lassen.\n\n'
          'Bitte einen Ordner auf einer lokalen Festplatte wählen '
          '(z. B. C:\\Videos oder D:\\Medien).';
    }

    return null;
  }

  /// Detects common consumer cloud-sync folders by looking for their
  /// signature segment in the absolute path. We match case-insensitively
  /// because Windows filesystems are.
  ///
  /// Not exhaustive (corporate SharePoint mounts, Box, Mega, pCloud, …) but
  /// catches 99 % of the cases that actually bite home users.
  static String? _detectCloudProvider(String path) {
    // Normalize to forward slashes + lowercase for matching, but keep the
    // original path intact for error reporting elsewhere.
    final normalized =
        p.normalize(path).replaceAll('\\', '/').toLowerCase();
    final segments = normalized.split('/');

    // Match against path segments rather than substring so a folder called
    // "my-onedrive-backup" on a local disk isn't falsely flagged.
    bool hasSegment(Pattern needle) {
      if (needle is RegExp) {
        return segments.any(needle.hasMatch);
      }
      return segments.any((s) => s == needle);
    }

    // OneDrive: "OneDrive", "OneDrive - Company", "OneDriveTemp"
    if (hasSegment(RegExp(r'^onedrive( - .+)?$'))) return 'OneDrive';
    // Dropbox: plain "Dropbox" or "Dropbox (Company)"
    if (hasSegment(RegExp(r'^dropbox( \(.+\))?$'))) return 'Dropbox';
    // Google Drive: "Google Drive" or "GoogleDrive" or "My Drive"
    if (hasSegment('google drive') ||
        hasSegment('googledrive') ||
        hasSegment('my drive')) {
      return 'Google Drive';
    }
    // iCloud (Windows app): "iCloudDrive" or "iCloud Drive"
    if (hasSegment('icloud drive') || hasSegment('iclouddrive')) {
      return 'iCloud Drive';
    }
    // Box / pCloud / Mega (less common but quick to add)
    if (hasSegment('box')) return 'Box';
    if (hasSegment('pcloud')) return 'pCloud';
    if (hasSegment('mega')) return 'MEGA';

    return null;
  }
}
