import 'dart:ffi';
import 'dart:io';
import 'dart:ui';
import 'package:ffi/ffi.dart';
import 'package:flutter/services.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';
import 'log_service.dart';

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
  /// True when the user pressed F/F11 while the window was in
  /// Windows-maximized state (clicked the maximize button). We
  /// have to `unmaximize()` before applying our borderless bounds
  /// — otherwise Windows clamps the bounds to the work-area
  /// (= screen minus taskbar), which is exactly the user-reported
  /// "Taskleiste bleibt sichtbar" bug. On exit we restore the
  /// maximized state instead of the snapshotted bounds.
  static bool _savedMaximized = false;
  /// Saved GWL_STYLE bits so [_Win11WindowStyle] can put back
  /// the exact set of style flags the window had before we
  /// stripped WS_THICKFRAME for borderless fullscreen.
  static int? _savedWindowStyle;

  static bool get isFullscreen => _isFullscreen;

  static Future<void> enterFullscreen() async {
    if (_isFullscreen) return;
    _isFullscreen = true;

    if (Platform.isWindows) {
      try {
        // 1. Snapshot state for restore on exit.
        _savedBounds = await windowManager.getBounds();
        _savedAlwaysOnTop = await windowManager.isAlwaysOnTop();
        _savedMaximized = await windowManager.isMaximized();

        // 1b. If the window is currently in Windows-maximized
        // state, `setBounds` calls below would silently get
        // clamped to the work area (= screen minus taskbar).
        // Drop the maximized state first so the upcoming bounds
        // change is taken at face value.
        if (_savedMaximized) {
          await windowManager.unmaximize();
        }

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

        // 6. Suppress every visual "around the window" element DWM
        //    paints on Win11:
        //      - rounded corners       → DWMWCP_DONOTROUND
        //      - thin frame border     → DWMWA_BORDER_COLOR = NONE
        //      - non-rectangular clip  → SetWindowRgn(rect)
        //    Combined they nail the "gray border around the player"
        //    that was leftover after v1.5.43 (DWM frame border is
        //    painted OUTSIDE the window rect by the compositor —
        //    SetWindowRgn alone can't reach it).
        final dwmOk = _Win11Corners.setRoundingEnabled(false);
        LogService.info('[fs] corner-rounding DWM result=$dwmOk');
        final borderOk = _Win11Corners.setBorderHidden(true);
        LogService.info('[fs] border-color hide result=$borderOk');
        final rgnOk = _Win11WindowRegion.setRectangular(
          target.size.width.toInt(),
          target.size.height.toInt(),
        );
        LogService.info('[fs] SetWindowRgn result=$rgnOk '
            'size=${target.size.width.toInt()}x${target.size.height.toInt()}');

        // 7. Strip WS_THICKFRAME from the window style.
        //
        // v1.5.44 + v1.5.45 logs proved every DWM attribute we set
        // returned hr=0x0 yet a thin white/grey border remained
        // visible around the player. The reason is structural,
        // not DWM-cosmetic: Flutter's Windows runner creates the
        // top-level window with `WS_OVERLAPPEDWINDOW` which
        // includes `WS_THICKFRAME` (the resizable sizing border).
        // MSDN clarifies that SetWindowRgn clips the visible
        // region of the window — but the OS still PAINTS the
        // non-client frame INSIDE that region, so the 1-2 px
        // thick frame stays visible no matter what DWM
        // attributes we set.
        //
        // The only way to make it actually vanish is to remove
        // the style flag itself. Save the current style, strip
        // WS_THICKFRAME (plus WS_DLGFRAME / WS_BORDER as
        // belt-and-suspenders), call SetWindowPos with
        // SWP_FRAMECHANGED so the OS recomputes the non-client
        // area. On exit we put the saved style back so the
        // window can be resized like normal again.
        //
        // This IS a style change. The mid-session-style-change
        // bug we hit in v1.5.36 was specifically
        // WS_OVERLAPPEDWINDOW → WS_POPUP (a complete style
        // switch + DXGI swapchain swap). Removing just
        // WS_THICKFRAME without changing fundamental style class
        // is several orders of magnitude milder and — based on
        // every report I could find — does not trigger the
        // libmpv↔ANGLE texture loss.
        _savedWindowStyle = _Win11WindowStyle.stripBorderFlags();
        LogService.info('[fs] stripped WS_THICKFRAME — '
            'savedStyle=0x${(_savedWindowStyle ?? 0).toRadixString(16)}');

        // 8. Force DWM frame revalidation AFTER the style change
        //    so the OS picks up the new non-client size.
        final framedOk = _Win11FrameRefresh.forceFrameChanged();
        LogService.info('[fs] SWP_FRAMECHANGED result=$framedOk');

        // Re-apply bounds after the style strip — removing
        // WS_THICKFRAME shrinks the non-client area, which may
        // have nudged the window slightly. Re-asserting bounds
        // guarantees we end up exactly at monitor pixels.
        await windowManager.setBounds(
          Rect.fromLTWH(
            monitorOriginX,
            monitorOriginY,
            target.size.width,
            target.size.height,
          ),
        );

        // Diagnostic — what does Windows think the window's actual
        // pixel rect is after all our calls? If this differs from
        // the monitor size we passed to setBounds we have a DPI /
        // clamping issue rather than a DWM-frame issue.
        final rect = _Win11Diag.getWindowRect();
        if (rect != null) {
          LogService.info('[fs] GetWindowRect → '
              'left=${rect.left} top=${rect.top} '
              'right=${rect.right} bottom=${rect.bottom} '
              '(${rect.right - rect.left}x${rect.bottom - rect.top})');
        }
        LogService.info('[fs] monitor reported '
            '${target.size.width.toInt()}x${target.size.height.toInt()} '
            'visiblePos=$vpX,$vpY hInset=$hInset vInset=$vInset');
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
        // 0. Drop the rectangular window region FIRST so the
        //    window can be sized + styled freely again. Without
        //    this the saved-bounds restore would still be clipped
        //    to the fullscreen rectangle and the windowed mode
        //    would look like a thin slice of the player.
        _Win11WindowRegion.clear();

        // 0b. Restore the original window style — re-adds
        //     WS_THICKFRAME so the windowed-mode window can be
        //     resized again and looks like a normal Win11 app.
        if (_savedWindowStyle != null) {
          _Win11WindowStyle.setStyle(_savedWindowStyle!);
        }

        // Reverse order of enter: drop always-on-top first so the
        // window relinquishes its Z-order claim before bounds /
        // style changes start flying through Windows.
        await windowManager.setAlwaysOnTop(_savedAlwaysOnTop);
        await windowManager.setTitleBarStyle(
          TitleBarStyle.normal,
          windowButtonVisibility: true,
        );
        if (_savedMaximized) {
          // Window was maximized when fullscreen started → put
          // it back into maximized state. Don't apply
          // _savedBounds because those are the *pre-maximize*
          // bounds we don't want to use here.
          await windowManager.maximize();
        } else if (_savedBounds != null) {
          await windowManager.setBounds(_savedBounds);
        }
        // Restore default DWM corner rounding.
        //
        // We deliberately DO NOT call setBorderHidden(false) here:
        // v1.5.44 logs proved that passing DWMWA_COLOR_DEFAULT
        // (0xFFFFFFFF) leaves a thin WHITE pixel frame in windowed
        // mode on this build of Win11. DWM apparently treats the
        // sentinel as the actual colour white instead of "system
        // default". Leaving DWMWA_BORDER_COLOR at DWMWA_COLOR_NONE
        // means windowed mode has no DWM-painted border around it
        // — which looks normal (most Win11 apps don't have an
        // obvious border anyway) and is strictly better than a
        // white outline that wasn't there before.
        _Win11Corners.setRoundingEnabled(true);
        // Force frame revalidation so the corner-rounding restore
        // visually takes effect immediately.
        _Win11FrameRefresh.forceFrameChanged();
      } catch (_) {
        // If anything fails, force-exit via window_manager.
        await windowManager.setFullScreen(false);
      } finally {
        _savedBounds = null;
        _savedAlwaysOnTop = false;
        _savedMaximized = false;
        _savedWindowStyle = null;
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

// ─────────────────────────────────────────────────────────────────────
// Windows 11 corner-rounding control
// ─────────────────────────────────────────────────────────────────────
//
// Calls into `dwmapi.dll` via dart:ffi to toggle DWM's per-window
// corner-radius preference. We use this so the borderless-fullscreen
// window can be sized to exactly the monitor's pixel bounds without
// the ~8 px rounded corners clipping the corners off and exposing
// the taskbar/desktop behind them.
//
// The API has existed since Windows 11 21H2 (build 22000). On older
// Windows the DwmSetWindowAttribute call returns a non-zero HRESULT
// and we silently no-op — the user just sees square corners as
// before.
//
// We deliberately keep this self-contained in the same file as the
// only caller. It's ~30 lines of FFI plumbing that doesn't need to
// be reused anywhere else; pulling it into a separate file would
// only add navigation overhead.

typedef _FindWindowExWNative = IntPtr Function(
    IntPtr hwndParent,
    IntPtr hwndChildAfter,
    Pointer<Utf16> lpszClass,
    Pointer<Utf16> lpszWindow);
typedef _FindWindowExWDart = int Function(int hwndParent, int hwndChildAfter,
    Pointer<Utf16> lpszClass, Pointer<Utf16> lpszWindow);

typedef _GetForegroundWindowNative = IntPtr Function();
typedef _GetForegroundWindowDart = int Function();

typedef _DwmSetWindowAttributeNative = Int32 Function(
    IntPtr hwnd, Uint32 attr, Pointer<Uint32> pvAttr, Uint32 cbAttr);
typedef _DwmSetWindowAttributeDart = int Function(
    int hwnd, int attr, Pointer<Uint32> pvAttr, int cbAttr);

class _Win11Corners {
  // From `dwmapi.h`.
  static const int _DWMWA_WINDOW_CORNER_PREFERENCE = 33;
  static const int _DWMWCP_DEFAULT = 0;
  static const int _DWMWCP_DONOTROUND = 1;
  static const int _DWMWA_BORDER_COLOR = 34;
  // DWMWA_COLOR_NONE — tells DWM not to paint the visible frame
  // border around the window. The colour value `0xFFFFFFFE` is the
  // sentinel reserved for "no border" since Windows 11 22000.
  static const int _DWMWA_COLOR_NONE = 0xFFFFFFFE;
  static const int _DWMWA_COLOR_DEFAULT = 0xFFFFFFFF;

  /// Flutter's hard-coded top-level window class on Windows.
  /// Registered in `windows/runner/win32_window.cpp` of every
  /// Flutter Windows app — exact match across versions.
  static const String _flutterWindowClass = 'FLUTTER_RUNNER_WIN32_WINDOW';

  /// Resolve the Flutter window's HWND.
  ///
  /// Primary strategy: `FindWindowExW(NULL, NULL,
  /// "FLUTTER_RUNNER_WIN32_WINDOW", NULL)`. Walks all top-level
  /// windows looking for the Flutter class; we have exactly one,
  /// so the first hit is ours. Robust against focus changes that
  /// would foil `GetForegroundWindow`.
  ///
  /// Fallback: `GetForegroundWindow()` if FindWindowEx returns 0
  /// (extremely unlikely on a running app but cheap to guard).
  static int _findFlutterHwnd(DynamicLibrary user32) {
    final findWindowExW =
        user32.lookupFunction<_FindWindowExWNative, _FindWindowExWDart>(
            'FindWindowExW');
    final classPtr = _flutterWindowClass.toNativeUtf16();
    try {
      final hwnd = findWindowExW(0, 0, classPtr, nullptr);
      if (hwnd != 0) return hwnd;
    } finally {
      calloc.free(classPtr);
    }
    final getForegroundWindow = user32.lookupFunction<
        _GetForegroundWindowNative,
        _GetForegroundWindowDart>('GetForegroundWindow');
    return getForegroundWindow();
  }

  /// `true`  → restore the OS default (rounded on Win11).
  /// `false` → force square corners.
  /// Returns true if the DWM call accepted the change.
  static bool setRoundingEnabled(bool enabled) {
    if (!Platform.isWindows) return false;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final dwmapi = DynamicLibrary.open('dwmapi.dll');
      final dwmSet = dwmapi.lookupFunction<_DwmSetWindowAttributeNative,
          _DwmSetWindowAttributeDart>('DwmSetWindowAttribute');
      final hwnd = _findFlutterHwnd(user32);
      if (hwnd == 0) {
        LogService.warn('[fs] _Win11Corners: hwnd lookup returned 0');
        return false;
      }
      final ptr = calloc<Uint32>();
      try {
        ptr.value = enabled ? _DWMWCP_DEFAULT : _DWMWCP_DONOTROUND;
        final hr = dwmSet(
          hwnd,
          _DWMWA_WINDOW_CORNER_PREFERENCE,
          ptr,
          sizeOf<Uint32>(),
        );
        LogService.info('[fs] DwmSetWindowAttribute hwnd=0x${hwnd.toRadixString(16)} '
            'pref=${ptr.value} hr=0x${hr.toRadixString(16)}');
        return hr == 0; // S_OK
      } finally {
        calloc.free(ptr);
      }
    } catch (e, st) {
      LogService.warn('[fs] _Win11Corners.setRoundingEnabled threw',
          error: e, stack: st);
      return false;
    }
  }

  /// Hide / restore the thin DWM frame border that Win11 paints
  /// around every window. `true` → no border, `false` → default.
  ///
  /// SetWindowRgn alone can't reach this border because DWM paints
  /// it OUTSIDE the window rect in the compositor. The proper Win11
  /// way is `DwmSetWindowAttribute(DWMWA_BORDER_COLOR, NONE)`.
  static bool setBorderHidden(bool hidden) {
    if (!Platform.isWindows) return false;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final dwmapi = DynamicLibrary.open('dwmapi.dll');
      final dwmSet = dwmapi.lookupFunction<_DwmSetWindowAttributeNative,
          _DwmSetWindowAttributeDart>('DwmSetWindowAttribute');
      final hwnd = _findFlutterHwnd(user32);
      if (hwnd == 0) return false;
      final ptr = calloc<Uint32>();
      try {
        ptr.value = hidden ? _DWMWA_COLOR_NONE : _DWMWA_COLOR_DEFAULT;
        final hr = dwmSet(
          hwnd,
          _DWMWA_BORDER_COLOR,
          ptr,
          sizeOf<Uint32>(),
        );
        LogService.info('[fs] DwmSetWindowAttribute(BORDER_COLOR) '
            'hwnd=0x${hwnd.toRadixString(16)} '
            'value=0x${ptr.value.toRadixString(16)} '
            'hr=0x${hr.toRadixString(16)}');
        return hr == 0;
      } finally {
        calloc.free(ptr);
      }
    } catch (e, st) {
      LogService.warn('[fs] _Win11Corners.setBorderHidden threw',
          error: e, stack: st);
      return false;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// Window-rect diagnostics
// ─────────────────────────────────────────────────────────────────────
//
// Wraps GetWindowRect() so we can verify what Windows ACTUALLY
// applied as the window's pixel rect after all our setBounds /
// SetWindowRgn / DWM dance. Surfaced into app.log so any future
// "ein Pixel zu klein"-style reports can be matched against the
// monitor reported by screen_retriever — without having to guess
// whether it's DPI scaling, OS clamping, or a missed call.

final class _Win32Rect {
  final int left;
  final int top;
  final int right;
  final int bottom;
  const _Win32Rect(this.left, this.top, this.right, this.bottom);
}

@Packed(1)
final class _WindowsRectStruct extends Struct {
  @Int32()
  external int left;
  @Int32()
  external int top;
  @Int32()
  external int right;
  @Int32()
  external int bottom;
}

typedef _GetWindowRectNative = Int32 Function(
    IntPtr hwnd, Pointer<_WindowsRectStruct> rect);
typedef _GetWindowRectDart = int Function(
    int hwnd, Pointer<_WindowsRectStruct> rect);

// ─────────────────────────────────────────────────────────────────────
// Frame-changed nudge
// ─────────────────────────────────────────────────────────────────────
//
// `DwmSetWindowAttribute` reports success but DWM frequently
// doesn't repaint until it's told the non-client area changed.
// `SetWindowPos` with `SWP_FRAMECHANGED` (and no actual size /
// position / z-order change) is the canonical way to make DWM
// re-read all the attributes and redraw the frame on Win11.

typedef _SetWindowPosNative = Int32 Function(IntPtr hwnd, IntPtr hwndAfter,
    Int32 x, Int32 y, Int32 cx, Int32 cy, Uint32 flags);
typedef _SetWindowPosDart = int Function(int hwnd, int hwndAfter, int x, int y,
    int cx, int cy, int flags);

class _Win11FrameRefresh {
  // SWP flag combos. Documented values straight from `winuser.h`.
  static const int _SWP_NOSIZE = 0x0001;
  static const int _SWP_NOMOVE = 0x0002;
  static const int _SWP_NOZORDER = 0x0004;
  static const int _SWP_NOACTIVATE = 0x0010;
  static const int _SWP_FRAMECHANGED = 0x0020;

  static bool forceFrameChanged() {
    if (!Platform.isWindows) return false;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final hwnd = _Win11Corners._findFlutterHwnd(user32);
      if (hwnd == 0) return false;
      final setWindowPos = user32
          .lookupFunction<_SetWindowPosNative, _SetWindowPosDart>(
              'SetWindowPos');
      final result = setWindowPos(
        hwnd,
        0, // hwndInsertAfter — ignored because of SWP_NOZORDER
        0, 0, 0, 0,
        _SWP_NOSIZE |
            _SWP_NOMOVE |
            _SWP_NOZORDER |
            _SWP_NOACTIVATE |
            _SWP_FRAMECHANGED,
      );
      return result != 0;
    } catch (e, st) {
      LogService.warn('[fs] _Win11FrameRefresh.forceFrameChanged threw',
          error: e, stack: st);
      return false;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// Window style manipulation (WS_THICKFRAME strip)
// ─────────────────────────────────────────────────────────────────────
//
// Flutter creates the Windows runner window with WS_OVERLAPPEDWINDOW
// (= WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME |
// WS_MINIMIZEBOX | WS_MAXIMIZEBOX). WS_THICKFRAME is the resizable
// "sizing border" — a 1-2 px thick frame the OS paints around the
// window. No DWM attribute (BORDER_COLOR, CORNER_PREFERENCE) can
// hide it: it's owned by the WM, not DWM.
//
// We strip it from the style during fullscreen and put it back on
// exit. Smallest possible style change, far less invasive than
// the WS_OVERLAPPEDWINDOW → WS_POPUP switch that caused the
// original freeze.

typedef _GetWindowLongPtrNative = IntPtr Function(IntPtr hwnd, Int32 index);
typedef _GetWindowLongPtrDart = int Function(int hwnd, int index);

typedef _SetWindowLongPtrNative = IntPtr Function(
    IntPtr hwnd, Int32 index, IntPtr newLong);
typedef _SetWindowLongPtrDart = int Function(
    int hwnd, int index, int newLong);

class _Win11WindowStyle {
  static const int _GWL_STYLE = -16;
  // From winuser.h
  static const int _WS_BORDER = 0x00800000;
  static const int _WS_DLGFRAME = 0x00400000;
  static const int _WS_THICKFRAME = 0x00040000;

  /// Reads the current window style, removes WS_THICKFRAME +
  /// WS_BORDER + WS_DLGFRAME, writes it back. Returns the
  /// pre-strip style value so the caller can restore it later
  /// (or null on FFI failure).
  static int? stripBorderFlags() {
    if (!Platform.isWindows) return null;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final hwnd = _Win11Corners._findFlutterHwnd(user32);
      if (hwnd == 0) {
        LogService.warn('[fs] _Win11WindowStyle: hwnd lookup returned 0');
        return null;
      }
      // On Win64 SetWindowLongPtrW is the correct entry point —
      // Win32's SetWindowLongW only handles 32-bit values which
      // truncates the high bits of pointer-style values. For
      // GWL_STYLE the value fits in 32 bits anyway but using the
      // Ptr variant is the official cross-bitness path.
      final getWindowLongPtr = user32.lookupFunction<
          _GetWindowLongPtrNative,
          _GetWindowLongPtrDart>('GetWindowLongPtrW');
      final setWindowLongPtr = user32.lookupFunction<
          _SetWindowLongPtrNative,
          _SetWindowLongPtrDart>('SetWindowLongPtrW');
      final current = getWindowLongPtr(hwnd, _GWL_STYLE);
      final stripped =
          current & ~(_WS_THICKFRAME | _WS_BORDER | _WS_DLGFRAME);
      setWindowLongPtr(hwnd, _GWL_STYLE, stripped);
      LogService.info('[fs] WS_THICKFRAME strip: '
          'before=0x${current.toRadixString(16)} '
          'after=0x${stripped.toRadixString(16)}');
      return current;
    } catch (e, st) {
      LogService.warn('[fs] _Win11WindowStyle.stripBorderFlags threw',
          error: e, stack: st);
      return null;
    }
  }

  /// Writes an arbitrary GWL_STYLE value. Used to restore the
  /// saved style on fullscreen exit.
  static bool setStyle(int style) {
    if (!Platform.isWindows) return false;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final hwnd = _Win11Corners._findFlutterHwnd(user32);
      if (hwnd == 0) return false;
      final setWindowLongPtr = user32.lookupFunction<
          _SetWindowLongPtrNative,
          _SetWindowLongPtrDart>('SetWindowLongPtrW');
      setWindowLongPtr(hwnd, _GWL_STYLE, style);
      LogService.info('[fs] WS style restored to '
          '0x${style.toRadixString(16)}');
      return true;
    } catch (e, st) {
      LogService.warn('[fs] _Win11WindowStyle.setStyle threw',
          error: e, stack: st);
      return false;
    }
  }
}

class _Win11Diag {
  /// Returns the window's outer rect in screen coordinates (or
  /// null on FFI failure / no Flutter window found).
  static _Win32Rect? getWindowRect() {
    if (!Platform.isWindows) return null;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final hwnd = _Win11Corners._findFlutterHwnd(user32);
      if (hwnd == 0) return null;
      final getWindowRect = user32
          .lookupFunction<_GetWindowRectNative, _GetWindowRectDart>(
              'GetWindowRect');
      final rectPtr = calloc<_WindowsRectStruct>();
      try {
        final ok = getWindowRect(hwnd, rectPtr);
        if (ok == 0) return null;
        final r = rectPtr.ref;
        return _Win32Rect(r.left, r.top, r.right, r.bottom);
      } finally {
        calloc.free(rectPtr);
      }
    } catch (_) {
      return null;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// Windows rectangular region clipping
// ─────────────────────────────────────────────────────────────────────
//
// SetWindowRgn defines the visible region of a window — anything
// outside is clipped. By passing a perfect rectangle covering the
// whole window we force Windows to ignore DWM's corner radius and
// render the four corners as actual right-angles. Used when
// DwmSetWindowAttribute(DWMWCP_DONOTROUND) returns S_OK but the
// rounded corners visually persist (observed on Win11 with
// Flutter's default window style).
//
// MSDN note: after calling SetWindowRgn, the OS owns the HRGN. We
// must NOT DeleteObject it ourselves — Windows will release it on
// next SetWindowRgn or window destruction.

typedef _CreateRectRgnNative = IntPtr Function(
    Int32 x1, Int32 y1, Int32 x2, Int32 y2);
typedef _CreateRectRgnDart = int Function(int x1, int y1, int x2, int y2);

typedef _SetWindowRgnNative = Int32 Function(
    IntPtr hwnd, IntPtr hrgn, Int32 redraw);
typedef _SetWindowRgnDart = int Function(int hwnd, int hrgn, int redraw);

class _Win11WindowRegion {
  /// Apply a rectangular clipping region to the Flutter window so
  /// the four corners are right-angled regardless of DWM. width/
  /// height should match the window's current pixel size (monitor
  /// dimensions in our case).
  static bool setRectangular(int width, int height) {
    if (!Platform.isWindows) return false;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final gdi32 = DynamicLibrary.open('gdi32.dll');
      final hwnd = _Win11Corners._findFlutterHwnd(user32);
      if (hwnd == 0) {
        LogService.warn('[fs] _Win11WindowRegion: hwnd lookup returned 0');
        return false;
      }
      final createRectRgn = gdi32
          .lookupFunction<_CreateRectRgnNative, _CreateRectRgnDart>(
              'CreateRectRgn');
      final setWindowRgn = user32
          .lookupFunction<_SetWindowRgnNative, _SetWindowRgnDart>(
              'SetWindowRgn');
      final rgn = createRectRgn(0, 0, width, height);
      if (rgn == 0) {
        LogService.warn('[fs] CreateRectRgn returned 0');
        return false;
      }
      // bRedraw=1 forces a repaint of the now-clipped window.
      final result = setWindowRgn(hwnd, rgn, 1);
      return result != 0;
    } catch (e, st) {
      LogService.warn('[fs] _Win11WindowRegion.setRectangular threw',
          error: e, stack: st);
      return false;
    }
  }

  /// Restore the default (full) window region — i.e. DWM is back
  /// in charge of corner rounding. Called when exiting fullscreen
  /// so windowed mode looks normal again.
  static bool clear() {
    if (!Platform.isWindows) return false;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final hwnd = _Win11Corners._findFlutterHwnd(user32);
      if (hwnd == 0) return false;
      final setWindowRgn = user32
          .lookupFunction<_SetWindowRgnNative, _SetWindowRgnDart>(
              'SetWindowRgn');
      // Passing NULL (0) for the HRGN restores default — window
      // gets the whole client area as its visible region again.
      final result = setWindowRgn(hwnd, 0, 1);
      return result != 0;
    } catch (e, st) {
      LogService.warn('[fs] _Win11WindowRegion.clear threw',
          error: e, stack: st);
      return false;
    }
  }
}
