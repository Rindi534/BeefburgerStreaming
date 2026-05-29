import 'dart:io';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// Cross-platform fullscreen toggle for the player.
///
/// ## Why this is custom instead of `windowManager.setFullScreen(true)`
///
/// `window_manager.setFullScreen` on Windows changes the window
/// style flags (WS_OVERLAPPEDWINDOW → WS_POPUP) and triggers an
/// aggressive DXGI swapchain swap. That style change broke the
/// libmpv → ANGLE → D3D11 texture handle that Flutter's compositor
/// samples — symptom: video freezes on last frame while audio keeps
/// running.
///
/// Diagnosis pipeline (v1.5.36 / v1.5.37 / v1.5.38 logs):
///  - Position-delta detection was useless (mpv's position clock
///    is audio-driven, keeps advancing during video freeze).
///  - mpv's own log channel emits NOTHING during the freezes —
///    confirming the issue is between mpv's output texture and
///    Flutter's compositor, not in mpv proper.
///  - hwdec=no (software decoding) did not help — confirming the
///    issue isn't in the D3D11 decode path either.
///
/// We instead implement borderless fullscreen — the technique games
/// call "Fullscreen (Window)" / "Borderless Fullscreen":
///
///   1. Save current window bounds + always-on-top state for
///      restore on exit.
///   2. Hide the title bar (TitleBarStyle.hidden) and remove frame.
///   3. Query the display the window is currently on so multi-
///      monitor setups go fullscreen on the *right* monitor.
///   4. Resize the window to that display's FULL pixel bounds,
///      including the area Windows reserves for the taskbar.
///   5. setAlwaysOnTop(true) so the taskbar can't pop back in when
///      the user moves the cursor to the bottom edge.
///
/// Visual result: every pixel of the chosen monitor is our window.
/// No taskbar visible, no title bar. Identical-looking to what
/// `setFullScreen` produced — without the WS_POPUP style change
/// that nuked the video texture binding.
///
/// On macOS / Linux / mobile we delegate to the platform-native
/// path because (a) the swapchain freeze is Windows-specific and
/// (b) macOS's native fullscreen animation is what users expect on
/// that OS.
class FullscreenService {
  static bool _isFullscreen = false;

  /// Saved window state, restored on exit. `null` when not in
  /// fullscreen. Persists across the toggle so `exitFullscreen`
  /// knows exactly what to put back.
  static Rect? _savedBounds;
  static bool _savedAlwaysOnTop = false;

  static bool get isFullscreen => _isFullscreen;

  static Future<void> enterFullscreen() async {
    if (_isFullscreen) return;
    _isFullscreen = true;

    if (Platform.isWindows) {
      try {
        // 1. Snapshot state for restore on exit.
        _savedBounds = await windowManager.getBounds();
        _savedAlwaysOnTop = await windowManager.isAlwaysOnTop();

        // 2. Strip title bar so no chrome remains.
        await windowManager.setTitleBarStyle(
          TitleBarStyle.hidden,
          windowButtonVisibility: false,
        );

        // 3. Figure out which display the window is on. Fall back
        //    to the primary display on any lookup error — at worst
        //    the user lands on the main monitor.
        Display target;
        try {
          target = await _displayForCurrentWindow();
        } catch (_) {
          target = await screenRetriever.getPrimaryDisplay();
        }

        // 4. Cover the entire display in physical pixels.
        //
        // screen_retriever's Display gives us:
        //   - size           : full pixel dimensions of the monitor
        //   - visiblePosition: top-left of the WORK AREA (NOT
        //                      covered by the taskbar)
        //   - visibleSize    : work-area size
        //
        // We want the MONITOR's origin, not the work area's. Logic:
        //  - taskbar-at-bottom-or-right (the 99% case) →
        //    visiblePosition equals the monitor origin already.
        //  - taskbar-at-top-or-left → visiblePosition is shifted
        //    positively into the work area; we undo that shift
        //    when the corresponding inset is non-zero.
        // Multi-monitor with the player on a secondary screen still
        // works because we only treat positive offsets as taskbar
        // shifts when the inset on the same axis is non-zero.
        final hInset = target.size.width -
            (target.visibleSize?.width ?? target.size.width);
        final vInset = target.size.height -
            (target.visibleSize?.height ?? target.size.height);
        final vpX = target.visiblePosition?.dx ?? 0;
        final vpY = target.visiblePosition?.dy ?? 0;
        final monitorOriginX = (vpX > 0 && hInset > 0) ? 0.0 : vpX;
        final monitorOriginY = (vpY > 0 && vInset > 0) ? 0.0 : vpY;
        await windowManager.setBounds(
          Rect.fromLTWH(
            monitorOriginX,
            monitorOriginY,
            target.size.width,
            target.size.height,
          ),
        );

        // 5. The critical bit: keep us above the taskbar so it
        //    can't slide over the player when the cursor hits the
        //    bottom edge.
        await windowManager.setAlwaysOnTop(true);
      } catch (_) {
        // Hard failure → fall back to window_manager.setFullScreen
        // so the user at least gets *something* fullscreen-ish.
        await windowManager.setFullScreen(true);
      }
    } else if (Platform.isMacOS || Platform.isLinux) {
      await windowManager.setFullScreen(true);
    } else {
      // iOS / Android
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  static Future<void> exitFullscreen() async {
    if (!_isFullscreen) return;
    _isFullscreen = false;

    if (Platform.isWindows) {
      try {
        // Reverse order of enter: drop always-on-top first so the
        // window relinquishes its Z-order claim before bounds /
        // style changes start flying through Windows.
        await windowManager.setAlwaysOnTop(_savedAlwaysOnTop);
        await windowManager.setTitleBarStyle(
          TitleBarStyle.normal,
          windowButtonVisibility: true,
        );
        if (_savedBounds != null) {
          await windowManager.setBounds(_savedBounds);
        }
      } catch (_) {
        // If anything fails, force-exit via window_manager.
        await windowManager.setFullScreen(false);
      } finally {
        _savedBounds = null;
        _savedAlwaysOnTop = false;
      }
    } else if (Platform.isMacOS || Platform.isLinux) {
      await windowManager.setFullScreen(false);
    } else {
      await SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.manual,
        overlays: SystemUiOverlay.values,
      );
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  static Future<void> toggle() async {
    if (_isFullscreen) {
      await exitFullscreen();
    } else {
      await enterFullscreen();
    }
  }

  /// Picks the display whose bounds contain the current window's
  /// center. Falls back to the primary display when the lookup is
  /// inconclusive (window straddles two monitors, no display
  /// matches, screen_retriever returns nothing useful, …).
  static Future<Display> _displayForCurrentWindow() async {
    final bounds = await windowManager.getBounds();
    final centerX = bounds.left + bounds.width / 2;
    final centerY = bounds.top + bounds.height / 2;
    final displays = await screenRetriever.getAllDisplays();
    for (final d in displays) {
      final dx = d.visiblePosition?.dx ?? 0;
      final dy = d.visiblePosition?.dy ?? 0;
      final dw = d.size.width;
      final dh = d.size.height;
      if (centerX >= dx &&
          centerX < dx + dw &&
          centerY >= dy &&
          centerY < dy + dh) {
        return d;
      }
    }
    return screenRetriever.getPrimaryDisplay();
  }
}
