import 'dart:io';

import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:wallpaper_manager_flutter/wallpaper_manager_flutter.dart';

enum WallpaperFit { fill, stretch, fit }

extension WallpaperFitValue on WallpaperFit {
  String get value => switch (this) {
    WallpaperFit.fill => 'fill',
    WallpaperFit.stretch => 'stretch',
    WallpaperFit.fit => 'fit',
  };

  String get label => switch (this) {
    WallpaperFit.fill => 'Fill',
    WallpaperFit.stretch => 'Stretch',
    WallpaperFit.fit => 'Fit',
  };
}

/// Wallpaper abstraction.
///
/// iOS does not support programmatic wallpaper assignment; we save to Photos
/// so users can set wallpaper manually.
class WallpaperService {
  static const MethodChannel _windowsWallpaperChannel = MethodChannel(
    'nasa_apod_app/wallpaper',
  );

  /// Applies wallpaper behavior based on platform capability.
  Future<String> setImageWallpaper(
    String path, {
    WallpaperFit style = WallpaperFit.fill,
  }) async {
    if (Platform.isAndroid) {
      final manager = WallpaperManagerFlutter();
      final success = await manager.setWallpaper(
        File(path),
        WallpaperManagerFlutter.homeScreen,
      );
      return success
          ? 'Wallpaper set on Android.'
          : 'Unable to set wallpaper on Android.';
    }
    if (Platform.isWindows) {
      final ok = await setWindowsWallpaper(path, style: style);
      return ok
          ? 'Wallpaper set on Windows (${style.label}).'
          : 'Unable to set wallpaper on Windows.';
    }
    if (Platform.isIOS || Platform.isMacOS) {
      await Gal.putImage(path);
      return 'Saved image to Photos. Set wallpaper manually from Photos.';
    }
    return 'Wallpaper operation is unsupported on this platform.';
  }

  /// Sends a native request to set Windows wallpaper with explicit fit style.
  Future<bool> setWindowsWallpaper(
    String path, {
    WallpaperFit style = WallpaperFit.fill,
  }) async {
    try {
      final ok = await _windowsWallpaperChannel.invokeMethod<bool>(
        'setWallpaper',
        <String, Object?>{'path': path, 'style': style.value},
      );
      return ok ?? false;
    } on PlatformException {
      return false;
    }
  }
}
