import 'dart:io';

import 'package:flutter/services.dart';
import 'package:gal/gal.dart';

class WallpaperTargetSize {
  const WallpaperTargetSize({required this.widthPx, required this.heightPx});

  final int widthPx;
  final int heightPx;
}

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
  WallpaperService({
    bool? isAndroid,
    bool? isWindows,
    bool? isIOS,
    bool? isMacOS,
  }) : _isAndroid = isAndroid ?? Platform.isAndroid,
       _isWindows = isWindows ?? Platform.isWindows,
       _isIOS = isIOS ?? Platform.isIOS,
       _isMacOS = isMacOS ?? Platform.isMacOS;

  final bool _isAndroid;
  final bool _isWindows;
  final bool _isIOS;
  final bool _isMacOS;

  static const MethodChannel _windowsWallpaperChannel = MethodChannel(
    'nasa_apod_app/wallpaper',
  );
  static const MethodChannel _androidWallpaperChannel = MethodChannel(
    'nasa_apod_app/wallpaper_android',
  );

  /// Applies wallpaper behavior based on platform capability.
  Future<String> setImageWallpaper(
    String path, {
    WallpaperFit style = WallpaperFit.fill,
  }) async {
    if (_isAndroid) {
      return openAndroidSystemWallpaperPicker(path);
    }
    if (_isWindows) {
      final ok = await setWindowsWallpaper(path, style: style);
      return ok
          ? 'Wallpaper set on Windows (${style.label}).'
          : 'Unable to set wallpaper on Windows.';
    }
    if (_isIOS || _isMacOS) {
      await Gal.putImage(path);
      return 'Saved image to Photos. Set wallpaper manually from Photos.';
    }
    return 'Wallpaper operation is unsupported on this platform.';
  }

  Future<String> openAndroidSystemWallpaperPicker(String path) async {
    if (!_isAndroid) {
      return 'Wallpaper operation is unsupported on this platform.';
    }
    try {
      final ok = await _androidWallpaperChannel.invokeMethod<bool>(
        'openSystemWallpaperPicker',
        <String, Object>{'path': path},
      );
      return (ok ?? false)
          ? 'Opened Android wallpaper picker.'
          : 'Unable to open Android wallpaper picker.';
    } on PlatformException {
      return 'Unable to open Android wallpaper picker.';
    }
  }

  Future<WallpaperTargetSize?> getAndroidWallpaperTargetSize() async {
    if (!_isAndroid) return null;
    try {
      return await _getAndroidWallpaperTargetSize();
    } on PlatformException {
      return null;
    }
  }

  Future<WallpaperTargetSize?> getPlatformWallpaperTargetSize() async {
    if (_isAndroid) {
      return getAndroidWallpaperTargetSize();
    }
    if (_isWindows) {
      return _getWindowsWallpaperTargetSize();
    }
    return null;
  }

  Future<WallpaperTargetSize> _getAndroidWallpaperTargetSize() async {
    final raw = await _androidWallpaperChannel.invokeMethod<Object?>(
      'getWallpaperTargetSize',
    );
    if (raw is Map) {
      final width = raw['widthPx'];
      final height = raw['heightPx'];
      if (width is num && height is num) {
        return WallpaperTargetSize(
          widthPx: width.round(),
          heightPx: height.round(),
        );
      }
    }
    throw PlatformException(
      code: 'BAD_TARGET_SIZE',
      message: 'Invalid Android wallpaper target size response.',
    );
  }

  Future<WallpaperTargetSize?> _getWindowsWallpaperTargetSize() async {
    try {
      final raw = await _windowsWallpaperChannel.invokeMethod<Object?>(
        'getWallpaperTargetSize',
      );
      if (raw is Map) {
        final width = raw['widthPx'];
        final height = raw['heightPx'];
        if (width is num && height is num) {
          return WallpaperTargetSize(
            widthPx: width.round(),
            heightPx: height.round(),
          );
        }
      }
    } on PlatformException {
      return null;
    }
    return null;
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
