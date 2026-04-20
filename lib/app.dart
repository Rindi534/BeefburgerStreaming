import 'dart:io';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';
import 'services/thumbnail_service.dart';

class HomeStreamingApp extends StatefulWidget {
  const HomeStreamingApp({super.key});

  @override
  State<HomeStreamingApp> createState() => _HomeStreamingAppState();
}

class _HomeStreamingAppState extends State<HomeStreamingApp> with WindowListener {
  @override
  void initState() {
    super.initState();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.addListener(this);
      // NOTE: we intentionally do NOT call `setPreventClose(true)`.
      // Preventing the close to await cleanup made shutdown feel
      // laggy (several seconds on Windows). The close-cleanup we do
      // here is purely best-effort "try to not leave ffmpeg zombies
      // behind" — everything we touch on disk (thumbnail `.done`
      // markers with flush:true, Hive watch-progress writes) is
      // already crash-safe, so if the process dies before this
      // handler finishes the next launch still recovers cleanly.
    }
  }

  @override
  void dispose() {
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void onWindowClose() {
    // Fire-and-forget: kill any in-flight ffmpeg children so they
    // don't keep grinding on the drive after the window is gone.
    // We do NOT await — the OS is allowed to tear the process down
    // at its own pace. p.kill() is synchronous/instant anyway.
    // ignore: discarded_futures
    ThumbnailService.instance.killAllInFlight().catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HomeStreaming',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const HomeScreen(),
    );
  }
}
