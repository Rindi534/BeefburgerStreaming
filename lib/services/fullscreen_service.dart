import 'dart:async';
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
  /// WindowListener der während Fullscreen den AlwaysOnTop-Status
  /// an den Focus-State koppelt: Window hat Fokus → AlwaysOnTop an
  /// (Taskleiste bleibt verdeckt); Window verliert Fokus → AlwaysOnTop
  /// aus (neue Fenster können sich nach vorn drängen).
  static _FullscreenFocusListener? _focusListener;
  /// Belt-and-Suspenders zum Focus-Listener: nicht jeder Focus-
  /// Verlust feuert zuverlässig onWindowBlur. Z. B. wenn ein User
  /// auf einer anderen Monitor-Taskleiste klickt und unser Player
  /// im Hintergrund "den Fokus behält" laut Win32-API. Der Timer
  /// pollt alle 300 ms den tatsächlichen Focus-Status und korrigiert
  /// AlwaysOnTop, falls nötig.
  static Timer? _focusPollTimer;
  static bool? _lastPolledFocused;

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

        // 3. Monitor-Daten in physikalischen Pixeln direkt via Win32
        //    MonitorFromWindow + GetMonitorInfo holen.
        //
        // v1.9.28 hat screen_retriever genutzt — auf Multi-Monitor-
        // Setups mit unterschiedlichen DPI-Faktoren landeten daraus
        // teils logische Pixel, teils physikalische, teils kaputt
        // skalierte Werte (User-Bericht: Vollbild nur ein Viertel
        // groß auf Laptop-Bildschirm, oder zur falschen Position
        // auf der mittleren externer). MonitorFromWindow ist
        // DPI-V2-bewusst und liefert in jedem Fall die wahren
        // physikalischen Bildschirm-Koordinaten im virtuellen
        // Screen-Coord-System (genau das was SetWindowPos auch
        // erwartet).
        final monRes = _Win32Monitor.getCurrentMonitor();
        Display? srTarget;
        try {
          srTarget = await _displayForCurrentWindow();
        } catch (_) {
          srTarget = null;
        }
        // Log BEIDE Quellen damit wir bei weiteren Bug-Reports
        // direkt sehen ob screen_retriever lügt.
        if (srTarget != null) {
          LogService.info('[fs] screen_retriever target: '
              'size=${srTarget.size.width}x${srTarget.size.height} '
              'visiblePos=${srTarget.visiblePosition?.dx},${srTarget.visiblePosition?.dy} '
              'visibleSize=${srTarget.visibleSize?.width}x${srTarget.visibleSize?.height}');
        } else {
          LogService.info('[fs] screen_retriever returned null');
        }
        if (monRes != null) {
          LogService.info('[fs] Win32 GetMonitorInfo: '
              'monitor=(${monRes.monitor.left},${monRes.monitor.top})-'
              '(${monRes.monitor.right},${monRes.monitor.bottom}) '
              'work=(${monRes.work.left},${monRes.work.top})-'
              '(${monRes.work.right},${monRes.work.bottom})');
        } else {
          LogService.info('[fs] Win32 GetMonitorInfo returned null');
        }

        // Werte für die Bounds-Berechnung: Win32 bevorzugt
        // (deterministisch DPI-korrekt), screen_retriever als
        // Fallback.
        final double monitorOriginX;
        final double monitorOriginY;
        final double monitorWidth;
        final double monitorHeight;
        if (monRes != null) {
          monitorOriginX = monRes.monitor.left.toDouble();
          monitorOriginY = monRes.monitor.top.toDouble();
          monitorWidth =
              (monRes.monitor.right - monRes.monitor.left).toDouble();
          monitorHeight =
              (monRes.monitor.bottom - monRes.monitor.top).toDouble();
        } else if (srTarget != null) {
          // Fallback auf screen_retriever-Logik (alte v1.9.28-Pfad).
          final hInset = srTarget.size.width -
              (srTarget.visibleSize?.width ?? srTarget.size.width);
          final vInset = srTarget.size.height -
              (srTarget.visibleSize?.height ?? srTarget.size.height);
          final vpX = srTarget.visiblePosition?.dx ?? 0;
          final vpY = srTarget.visiblePosition?.dy ?? 0;
          monitorOriginX = (vpX > 0 && hInset > 0) ? 0.0 : vpX;
          monitorOriginY = (vpY > 0 && vInset > 0) ? 0.0 : vpY;
          monitorWidth = srTarget.size.width;
          monitorHeight = srTarget.size.height;
        } else {
          // Letzte Notlösung: nichts tun, Player bleibt im
          // windowed-Modus. Anstatt mit Fallback-Werten die völlig
          // falsches Layout produzieren.
          LogService.warn('[fs] both monitor sources null — aborting fs');
          throw StateError('no monitor info available');
        }

        // 4. Compute the OUTER window rect so the CLIENT area
        //    covers exactly the monitor pixels.
        //
        // v1.5.48 used AdjustWindowRectEx which trusts the
        // window's STYLE FLAGS (WS_CAPTION etc.) — but Flutter
        // overrides WM_NCCALCSIZE when TitleBarStyle.hidden is
        // active, removing the title bar non-client zone at
        // runtime. AdjustWindowRectEx still assumed a 31 px top
        // inset, so the window was positioned 31 px too high
        // and Flutter's render ended up 31 px off-screen at top
        // / 30 px short at bottom — exactly the v1.5.48 report
        // ("Bild oben abgeschnitten, unten schwarz").
        //
        // Fix: measure the ACTUAL non-client insets from the
        // current window state — independent of what the style
        // flags claim. We do that via GetWindowRect, GetClientRect
        // and ClientToScreen which together tell us where the
        // client area actually lives inside the window. This
        // captures Flutter's NCCALCSIZE override.
        final insets = _Win11ClientSize.measureCurrentInsets();
        if (insets != null) {
          LogService.info('[fs] measured insets '
              'L=${insets.left} T=${insets.top} '
              'R=${insets.right} B=${insets.bottom}');
        }
        final leftInset = (insets?.left ?? 0).toDouble();
        final topInset = (insets?.top ?? 0).toDouble();
        final rightInset = (insets?.right ?? 0).toDouble();
        final bottomInset = (insets?.bottom ?? 0).toDouble();
        // Position window so that the CLIENT rect coincides with
        // the monitor pixel range. Outer extends LEFT by leftInset
        // and UP by topInset, plus grows by rightInset / bottomInset
        // on the other sides.
        final outerX = monitorOriginX - leftInset;
        final outerY = monitorOriginY - topInset;
        final outerW = monitorWidth + leftInset + rightInset;
        final outerH = monitorHeight + topInset + bottomInset;
        // PHYSICAL-Pixel SetWindowPos statt window_manager.setBounds.
        // Letzteres macht implizite DPI-Konvertierung basierend auf
        // dem aktuellen Window-Monitor — bei einem Multi-Monitor-
        // Setup mit unterschiedlichem Scaling-Faktor pro Monitor
        // (Laptop 200% + Externer 100%, etc.) wird das daneben
        // gerechnet und das Fenster ist nur ein Viertel groß.
        // screen_retriever's display.size sind physische Pixel
        // direkt aus MONITORINFO; SetWindowPos akzeptiert sie 1:1.
        final placed = _Win11FrameRefresh.setPhysicalBounds(
          outerX.toInt(),
          outerY.toInt(),
          outerW.toInt(),
          outerH.toInt(),
        );
        LogService.info('[fs] SetWindowPos physical placed=$placed '
            'x=${outerX.toInt()} y=${outerY.toInt()} '
            'w=${outerW.toInt()} h=${outerH.toInt()}');

        // 5. AlwaysOnTop dynamisch an Focus koppeln.
        //
        // Wir starten mit AlwaysOnTop=true damit die Taskleiste
        // verdeckt bleibt. Ein WindowListener droppt das beim
        // Focus-Loss (= neues Fenster bekommt Fokus → kann sich
        // nach vorn drängen) und reaktiviert es beim Focus-Gain
        // (User klickt zurück in den Player → Taskleiste wieder
        // verdeckt). Ohne das blieben neue Programmfenster hinter
        // dem Player versteckt — User-Beschwerde.
        await windowManager.setAlwaysOnTop(true);
        _focusListener = _FullscreenFocusListener();
        windowManager.addListener(_focusListener!);
        // Periodic-Poll als Sicherheitsnetz für Focus-Events die
        // window_manager nicht durchreicht. Vergleicht den IST-
        // Focus-Status mit dem zuletzt gepollten und korrigiert
        // AlwaysOnTop entsprechend. Auch fängt das Drag-Szenario
        // ab wo der User von einem anderen Monitor ein Fenster
        // herzieht ohne dass explizit Focus-Events feuern.
        _lastPolledFocused = true;
        _focusPollTimer?.cancel();
        _focusPollTimer = Timer.periodic(
          const Duration(milliseconds: 300),
          (_) async {
            if (!_isFullscreen) return;
            try {
              final isFocused = await windowManager.isFocused();
              if (isFocused != _lastPolledFocused) {
                _lastPolledFocused = isFocused;
                await windowManager.setAlwaysOnTop(isFocused);
              }
            } catch (_) {/* best-effort */}
          },
        );

        // 6. Suppress every visual "around the window" element DWM
        //    paints on Win11:
        //      - rounded corners       → DWMWCP_DONOTROUND
        //      - thin frame border     → DWMWA_BORDER_COLOR = NONE
        //      - non-rectangular clip  → SetWindowRgn(rect)
        //    Combined they nail the "gray border around the player"
        //    that was leftover after v1.5.43 (DWM frame border is
        //    painted OUTSIDE the window rect by the compositor —
        //    SetWindowRgn alone can't reach it).
        // 6. DWM rounded-corner kill (belt-and-suspenders for the
        //    edge case where AdjustWindowRectEx returns slightly
        //    different insets at runtime than expected).
        final dwmOk = _Win11Corners.setRoundingEnabled(false);
        LogService.info('[fs] corner-rounding DWM result=$dwmOk');

        // 7. Clip the visible region to the on-screen part of the
        //    window in WINDOW-LOCAL coordinates.
        //
        // Window-local origin (0,0) sits at screen (outerX, outerY)
        // = (monitorX - leftInset, monitorY - topInset). The MONITOR's
        // pixel range in window-local coords is therefore:
        //   start_x = monitorX - outerX = monitorX - (monitorX - leftInset)
        //           = leftInset  (POSITIVE!)
        //   start_y = topInset
        //   end_x   = leftInset + monitorW
        //   end_y   = topInset  + monitorH
        //
        // v1.5.49 had this with a sign flip (`-leftInset` instead of
        // `+leftInset`), so the region clipped 16 px off the right
        // edge + 2 px off the bottom of the client — exactly the
        // "rechts großer transparenter Rahmen, unten ganz schmaler"
        // the user reported.
        final rgnX1 = leftInset.toInt();
        final rgnY1 = topInset.toInt();
        final rgnX2 = (leftInset + monitorWidth).toInt();
        final rgnY2 = (topInset + monitorHeight).toInt();
        final rgnOk =
            _Win11WindowRegion.setRectangularAt(rgnX1, rgnY1, rgnX2, rgnY2);
        LogService.info(
            '[fs] SetWindowRgn result=$rgnOk rect=($rgnX1,$rgnY1)-($rgnX2,$rgnY2)');

        // 8. Force DWM frame revalidation after all chrome calls
        //    so they take visible effect in one repaint.
        final framedOk = _Win11FrameRefresh.forceFrameChanged();
        LogService.info('[fs] SWP_FRAMECHANGED result=$framedOk');

        // Diagnostic — log BOTH the outer window rect AND the
        // client rect. If the client rect is smaller than the
        // window rect we have unreached non-client area = the
        // "border" the user sees. The DwmExtendFrameIntoClientArea
        // call above is meant to close that gap. After the
        // extend, the visual rendering should cover client rect
        // = window rect.
        final rect = _Win11Diag.getWindowRect();
        if (rect != null) {
          LogService.info('[fs] GetWindowRect → '
              'left=${rect.left} top=${rect.top} '
              'right=${rect.right} bottom=${rect.bottom} '
              '(${rect.right - rect.left}x${rect.bottom - rect.top})');
        }
        final crect = _Win11Diag.getClientRect();
        if (crect != null) {
          LogService.info('[fs] GetClientRect → '
              'left=${crect.left} top=${crect.top} '
              'right=${crect.right} bottom=${crect.bottom} '
              '(${crect.right - crect.left}x${crect.bottom - crect.top})');
        }
        LogService.info('[fs] monitor finalized '
            '${monitorWidth.toInt()}x${monitorHeight.toInt()} '
            'origin=$monitorOriginX,$monitorOriginY');
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

        // 0a. Focus-Listener UND Poll-Timer wieder abklemmen damit
        //     der gespeicherte AlwaysOnTop-Restore nicht direkt vom
        //     Listener oder Timer überschrieben wird wenn der Fokus
        //     während des Pop-Animationen mal kurz hin- und herwandert.
        _focusPollTimer?.cancel();
        _focusPollTimer = null;
        _lastPolledFocused = null;
        if (_focusListener != null) {
          windowManager.removeListener(_focusListener!);
          _focusListener = null;
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

  /// Setzt das Fenster über Win32 SetWindowPos mit ECHTEN
  /// PHYSICAL Pixeln. Notwendig auf Multi-Monitor-Setups mit
  /// unterschiedlichen DPI-Faktoren: window_manager.setBounds
  /// macht implizite DPI-Konversion basierend auf dem aktuellen
  /// Fenster-Monitor, was bei einem Wechsel auf einen anders
  /// skalierten Monitor (z. B. Laptop 200% vs externer 100%)
  /// schief geht — das Fenster landet nur ein Viertel groß.
  ///
  /// screen_retriever liefert PHYSICAL Pixel direkt aus
  /// MONITORINFO.rcMonitor; SetWindowPos akzeptiert PHYSICAL
  /// Pixel direkt. 1:1, kein Faktor dazwischen.
  static bool setPhysicalBounds(int x, int y, int w, int h) {
    if (!Platform.isWindows) return false;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final hwnd = _Win11Corners._findFlutterHwnd(user32);
      if (hwnd == 0) return false;
      final setWindowPos = user32
          .lookupFunction<_SetWindowPosNative, _SetWindowPosDart>(
              'SetWindowPos');
      // hwndInsertAfter = 0 (HWND_TOP via SWP_NOZORDER ignoriert),
      // SWP_NOZORDER + SWP_NOACTIVATE = Position + Größe setzen,
      // nichts anderes anfassen.
      final result = setWindowPos(
        hwnd,
        0,
        x, y, w, h,
        _SWP_NOZORDER | _SWP_NOACTIVATE,
      );
      return result != 0;
    } catch (e, st) {
      LogService.warn('[fs] _Win11FrameRefresh.setPhysicalBounds threw',
          error: e, stack: st);
      return false;
    }
  }

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

typedef _GetClientRectNative = Int32 Function(
    IntPtr hwnd, Pointer<_WindowsRectStruct> rect);
typedef _GetClientRectDart = int Function(
    int hwnd, Pointer<_WindowsRectStruct> rect);

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

  /// Returns the window's client rect (the area Flutter renders
  /// into) in window-local coordinates. If this is smaller than
  /// the window rect we have non-client area unreached by Flutter
  /// — which is exactly the "border" the user sees.
  static _Win32Rect? getClientRect() {
    if (!Platform.isWindows) return null;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final hwnd = _Win11Corners._findFlutterHwnd(user32);
      if (hwnd == 0) return null;
      final getClientRect = user32
          .lookupFunction<_GetClientRectNative, _GetClientRectDart>(
              'GetClientRect');
      final rectPtr = calloc<_WindowsRectStruct>();
      try {
        final ok = getClientRect(hwnd, rectPtr);
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
// DWM frame extension
// ─────────────────────────────────────────────────────────────────────
//
// DwmExtendFrameIntoClientArea tells DWM how much of the window's
// non-client frame (title bar + borders) should "extend" into the
// client area. Passing margins of (-1,-1,-1,-1) is the documented
// special value that means "extend across the ENTIRE client area"
// — the so-called "sheet of glass" mode used by apps that want
// full custom chrome (Edge, Spotify, etc.). With this set, the
// reserved non-client zones effectively vanish and Flutter's
// client area covers the whole window.

@Packed(1)
final class _MarginsStruct extends Struct {
  @Int32() external int cxLeftWidth;
  @Int32() external int cxRightWidth;
  @Int32() external int cyTopHeight;
  @Int32() external int cyBottomHeight;
}

typedef _DwmExtendFrameNative = Int32 Function(
    IntPtr hwnd, Pointer<_MarginsStruct> margins);
typedef _DwmExtendFrameDart = int Function(
    int hwnd, Pointer<_MarginsStruct> margins);

class _Win11FrameExtend {
  /// Extend the frame across the entire client area. Removes the
  /// visual "non-client border" without changing any window style
  /// flag (so no risk of triggering the swapchain freeze).
  static bool extendIntoFullClient() {
    return _setMargins(-1, -1, -1, -1);
  }

  /// Reset to default — DWM goes back to reserving normal
  /// non-client area for title bar + resize border.
  static bool resetToDefault() {
    return _setMargins(0, 0, 0, 0);
  }

  static bool _setMargins(int l, int r, int t, int b) {
    if (!Platform.isWindows) return false;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final dwmapi = DynamicLibrary.open('dwmapi.dll');
      final hwnd = _Win11Corners._findFlutterHwnd(user32);
      if (hwnd == 0) return false;
      final dwmExtend = dwmapi.lookupFunction<
          _DwmExtendFrameNative,
          _DwmExtendFrameDart>('DwmExtendFrameIntoClientArea');
      final ptr = calloc<_MarginsStruct>();
      try {
        ptr.ref
          ..cxLeftWidth = l
          ..cxRightWidth = r
          ..cyTopHeight = t
          ..cyBottomHeight = b;
        final hr = dwmExtend(hwnd, ptr);
        LogService.info('[fs] DwmExtendFrameIntoClientArea '
            'margins=($l,$r,$t,$b) hr=0x${hr.toRadixString(16)}');
        return hr == 0;
      } finally {
        calloc.free(ptr);
      }
    } catch (e, st) {
      LogService.warn('[fs] _Win11FrameExtend._setMargins threw',
          error: e, stack: st);
      return false;
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
  /// Apply a rectangular clipping region of (0,0,width,height) —
  /// kept for compatibility but [setRectangularAt] is preferred
  /// when the visible area doesn't start at window-local (0,0).
  static bool setRectangular(int width, int height) =>
      setRectangularAt(0, 0, width, height);

  /// Apply a rectangular clipping region in window-local
  /// coordinates. Used when the window overshoots the monitor
  /// so the on-screen portion (where the client is visible)
  /// doesn't start at (0,0) of window-local space.
  static bool setRectangularAt(int x1, int y1, int x2, int y2) {
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
      final rgn = createRectRgn(x1, y1, x2, y2);
      if (rgn == 0) {
        LogService.warn('[fs] CreateRectRgn returned 0');
        return false;
      }
      // bRedraw=1 forces a repaint of the now-clipped window.
      final result = setWindowRgn(hwnd, rgn, 1);
      return result != 0;
    } catch (e, st) {
      LogService.warn('[fs] _Win11WindowRegion.setRectangularAt threw',
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

// ─────────────────────────────────────────────────────────────────────
// AdjustWindowRectEx — client-area size calculator
// ─────────────────────────────────────────────────────────────────────
//
// Given a desired CLIENT-area size, AdjustWindowRectEx returns the
// outer-window rect required to produce that client size with the
// window's current style/extended-style flags. The returned rect has:
//   - left   ≤ 0  (negative magnitude = left non-client inset)
//   - top    ≤ 0  (negative magnitude = top non-client inset)
//   - right  ≥ clientWidth  (extra width  = right inset)
//   - bottom ≥ clientHeight (extra height = bottom inset)
//
// We use this so the borderless-fullscreen window can be positioned
// such that its CLIENT — not OUTER — area precisely covers the
// monitor pixels. The non-client strip sits off-screen and never
// shows.

typedef _AdjustWindowRectExNative = Int32 Function(
    Pointer<_WindowsRectStruct> rect, Uint32 style, Int32 menu, Uint32 exStyle);
typedef _AdjustWindowRectExDart = int Function(
    Pointer<_WindowsRectStruct> rect, int style, int menu, int exStyle);

// ClientToScreen converts a point in window-local coordinates to
// screen coordinates — used so we can locate where the client
// area actually sits inside the window outer (which captures
// Flutter's WM_NCCALCSIZE override, unlike AdjustWindowRectEx
// which only consults style flags).

@Packed(1)
final class _Win32Point extends Struct {
  @Int32() external int x;
  @Int32() external int y;
}

typedef _ClientToScreenNative = Int32 Function(
    IntPtr hwnd, Pointer<_Win32Point> point);
typedef _ClientToScreenDart = int Function(
    int hwnd, Pointer<_Win32Point> point);

/// Container for the four non-client insets a window has at the
/// moment of measurement.
class _NonClientInsets {
  final int left;
  final int top;
  final int right;
  final int bottom;
  const _NonClientInsets(this.left, this.top, this.right, this.bottom);
}

class _Win11ClientSize {
  static const int _GWL_STYLE = -16;
  static const int _GWL_EXSTYLE = -20;

  /// Measure the actual non-client insets of the Flutter window
  /// AS THEY ARE RIGHT NOW.
  ///
  /// Why not [adjustForClientSize] / AdjustWindowRectEx? Because
  /// that API computes insets from the window's STYLE FLAGS
  /// (WS_CAPTION etc.) — but Flutter overrides WM_NCCALCSIZE
  /// when TitleBarStyle.hidden is active and effectively removes
  /// the title bar non-client zone at runtime. AdjustWindowRectEx
  /// doesn't know about the override and returns a stale ~31 px
  /// top inset that doesn't match reality. The v1.5.48 logs proved
  /// this: it returned `top=-31` while GetClientRect showed the
  /// client extending to the full window height.
  ///
  /// This method instead measures the live insets by combining
  /// GetWindowRect (outer rect in screen coords), GetClientRect
  /// (client size in window-local coords) and ClientToScreen
  /// (client-origin → screen coords). The relationship:
  ///
  ///   leftInset   = clientScreenX - windowOuter.left
  ///   topInset    = clientScreenY - windowOuter.top
  ///   rightInset  = windowOuter.right - clientScreenX - clientWidth
  ///   bottomInset = windowOuter.bottom - clientScreenY - clientHeight
  ///
  /// Captures whatever the OS reports, including Flutter's
  /// override. Caller MUST invoke this AFTER any title-bar style
  /// change that might affect the non-client layout, so the
  /// reading reflects the final state.
  static _NonClientInsets? measureCurrentInsets() {
    if (!Platform.isWindows) return null;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final hwnd = _Win11Corners._findFlutterHwnd(user32);
      if (hwnd == 0) return null;

      final getWindowRect = user32
          .lookupFunction<_GetWindowRectNative, _GetWindowRectDart>(
              'GetWindowRect');
      final getClientRect = user32
          .lookupFunction<_GetClientRectNative, _GetClientRectDart>(
              'GetClientRect');
      final clientToScreen = user32
          .lookupFunction<_ClientToScreenNative, _ClientToScreenDart>(
              'ClientToScreen');

      final wPtr = calloc<_WindowsRectStruct>();
      final cPtr = calloc<_WindowsRectStruct>();
      final ptPtr = calloc<_Win32Point>();
      try {
        if (getWindowRect(hwnd, wPtr) == 0) return null;
        if (getClientRect(hwnd, cPtr) == 0) return null;
        ptPtr.ref
          ..x = 0
          ..y = 0;
        if (clientToScreen(hwnd, ptPtr) == 0) return null;

        final w = wPtr.ref;
        final c = cPtr.ref;
        final p = ptPtr.ref;
        final clientWidth = c.right - c.left;
        final clientHeight = c.bottom - c.top;
        return _NonClientInsets(
          p.x - w.left,
          p.y - w.top,
          w.right - (p.x + clientWidth),
          w.bottom - (p.y + clientHeight),
        );
      } finally {
        calloc.free(wPtr);
        calloc.free(cPtr);
        calloc.free(ptPtr);
      }
    } catch (e, st) {
      LogService.warn('[fs] _Win11ClientSize.measureCurrentInsets threw',
          error: e, stack: st);
      return null;
    }
  }

  /// Kept for archival / debugging — returns the outer rect needed
  /// per AdjustWindowRectEx (style-based, not state-based). NOT
  /// used by the live fullscreen path anymore because Flutter's
  /// runtime WM_NCCALCSIZE override makes this inaccurate.
  static _Win32Rect? adjustForClientSize(int clientWidth, int clientHeight) {
    if (!Platform.isWindows) return null;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final hwnd = _Win11Corners._findFlutterHwnd(user32);
      if (hwnd == 0) return null;
      final getWindowLongPtr = user32.lookupFunction<
          _GetWindowLongPtrNative, _GetWindowLongPtrDart>('GetWindowLongPtrW');
      final adjustWindowRectEx = user32.lookupFunction<
          _AdjustWindowRectExNative,
          _AdjustWindowRectExDart>('AdjustWindowRectEx');
      final style = getWindowLongPtr(hwnd, _GWL_STYLE);
      final exStyle = getWindowLongPtr(hwnd, _GWL_EXSTYLE);
      final rectPtr = calloc<_WindowsRectStruct>();
      try {
        rectPtr.ref
          ..left = 0
          ..top = 0
          ..right = clientWidth
          ..bottom = clientHeight;
        final ok = adjustWindowRectEx(rectPtr, style, 0, exStyle);
        if (ok == 0) return null;
        final r = rectPtr.ref;
        return _Win32Rect(r.left, r.top, r.right, r.bottom);
      } finally {
        calloc.free(rectPtr);
      }
    } catch (e, st) {
      LogService.warn('[fs] _Win11ClientSize.adjustForClientSize threw',
          error: e, stack: st);
      return null;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// Direct Win32 MonitorFromWindow / GetMonitorInfo
// ─────────────────────────────────────────────────────────────────────
//
// screen_retriever liefert auf Multi-Monitor-Setups mit gemischten
// DPI-Faktoren teils logische, teils physische Pixel — der Code im
// Plugin macht keine konsistente DPI-Konversion. Wir nutzen direkt
// die Win32-API; auf einem PER_MONITOR_AWARE_V2-Prozess (was
// Flutter Windows ist) liefert GetMonitorInfo garantiert raw
// physische Pixel im virtuellen Bildschirm-Coord-System — exakt
// das was SetWindowPos erwartet. 1:1, kein Faktor dazwischen.

@Packed(1)
final class _MonitorInfoStruct extends Struct {
  @Uint32() external int cbSize;
  // RECT rcMonitor inline as 4 Int32
  @Int32() external int monLeft;
  @Int32() external int monTop;
  @Int32() external int monRight;
  @Int32() external int monBottom;
  // RECT rcWork inline as 4 Int32
  @Int32() external int workLeft;
  @Int32() external int workTop;
  @Int32() external int workRight;
  @Int32() external int workBottom;
  @Uint32() external int dwFlags;
}

typedef _MonitorFromWindowNative = IntPtr Function(
    IntPtr hwnd, Uint32 flags);
typedef _MonitorFromWindowDart = int Function(int hwnd, int flags);

typedef _GetMonitorInfoWNative = Int32 Function(
    IntPtr hMonitor, Pointer<_MonitorInfoStruct> mi);
typedef _GetMonitorInfoWDart = int Function(
    int hMonitor, Pointer<_MonitorInfoStruct> mi);

class _MonitorRects {
  final _Win32Rect monitor;
  final _Win32Rect work;
  const _MonitorRects(this.monitor, this.work);
}

class _Win32Monitor {
  static const int _MONITOR_DEFAULTTONEAREST = 0x00000002;

  /// Finds the monitor under the Flutter window and returns BOTH
  /// the full monitor rect and the work area rect — both in
  /// physical pixels in the virtual screen coord system.
  static _MonitorRects? getCurrentMonitor() {
    if (!Platform.isWindows) return null;
    try {
      final user32 = DynamicLibrary.open('user32.dll');
      final hwnd = _Win11Corners._findFlutterHwnd(user32);
      if (hwnd == 0) {
        LogService.warn('[fs] _Win32Monitor: hwnd lookup returned 0');
        return null;
      }
      final monitorFromWindow = user32.lookupFunction<
          _MonitorFromWindowNative,
          _MonitorFromWindowDart>('MonitorFromWindow');
      final getMonitorInfo = user32.lookupFunction<
          _GetMonitorInfoWNative,
          _GetMonitorInfoWDart>('GetMonitorInfoW');
      final hMonitor = monitorFromWindow(hwnd, _MONITOR_DEFAULTTONEAREST);
      if (hMonitor == 0) {
        LogService.warn('[fs] MonitorFromWindow returned 0');
        return null;
      }
      final miPtr = calloc<_MonitorInfoStruct>();
      try {
        miPtr.ref.cbSize = sizeOf<_MonitorInfoStruct>();
        final ok = getMonitorInfo(hMonitor, miPtr);
        if (ok == 0) {
          LogService.warn('[fs] GetMonitorInfoW returned 0');
          return null;
        }
        final mi = miPtr.ref;
        return _MonitorRects(
          _Win32Rect(mi.monLeft, mi.monTop, mi.monRight, mi.monBottom),
          _Win32Rect(mi.workLeft, mi.workTop, mi.workRight, mi.workBottom),
        );
      } finally {
        calloc.free(miPtr);
      }
    } catch (e, st) {
      LogService.warn('[fs] _Win32Monitor.getCurrentMonitor threw',
          error: e, stack: st);
      return null;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// Focus-coupled AlwaysOnTop listener
// ─────────────────────────────────────────────────────────────────────
//
// Während Fullscreen darf der Player NICHT permanent AlwaysOnTop sein:
// Ein neues App-Fenster (z. B. ein Browser-Popup, ein anderer Player,
// eine Notification mit Dialog) würde sonst hinter unserem Player
// hängen und unzugänglich werden. User-Wunsch: neue Fenster sollen
// nach vorn kommen, sobald sie Fokus stehlen.
//
// Strategie: AlwaysOnTop koppeln an unseren Focus-State. Solange wir
// Fokus haben, bleibt es an (Taskleisten-Suppress wirkt); sobald der
// Fokus zu einem anderen Fenster wandert (= das andere Fenster
// will sich nach vorn drängen), droppen wir AlwaysOnTop und das
// andere Fenster gewinnt natürlich den Z-Order. Klickt der User
// zurück in unsere App, kommt AlwaysOnTop sofort wieder.
class _FullscreenFocusListener with WindowListener {
  @override
  void onWindowFocus() {
    // Best-effort — wenn wir nicht mehr im Fullscreen sind, ist's egal.
    if (!FullscreenService.isFullscreen) return;
    windowManager.setAlwaysOnTop(true);
  }

  @override
  void onWindowBlur() {
    if (!FullscreenService.isFullscreen) return;
    windowManager.setAlwaysOnTop(false);
  }
}
