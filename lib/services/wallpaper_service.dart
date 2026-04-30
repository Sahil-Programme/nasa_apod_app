import 'dart:io';

import 'package:gal/gal.dart';

/// Wallpaper abstraction.
///
/// iOS does not support programmatic wallpaper assignment; we save to Photos
/// so users can set wallpaper manually.
class WallpaperService {
  /// Applies wallpaper behavior based on platform capability.
  Future<String> setImageWallpaper(String path) async {
    if (Platform.isIOS) {
      await Gal.putImage(path);
      return 'Saved image to Photos on iOS. Set wallpaper manually from Photos.';
    }
    if (Platform.isAndroid) {
      return 'Wallpaper operation is currently unavailable with this plugin build.';
    }
    return 'Wallpaper operation is unsupported on this platform.';
  }
}
