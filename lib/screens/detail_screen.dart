import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/apod_entry.dart';
import '../providers/app_providers.dart';
import '../services/wallpaper_service.dart';
import '../ui/app_theme.dart';
import '../ui/cosmic_scaffold.dart';

/// Full-detail APOD page with zoomable media and metadata panel.
class DetailScreen extends ConsumerWidget {
  const DetailScreen({super.key, required this.entry});

  final ApodEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CosmicScaffold(
      appBar: AppBar(
        title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      child: ListView(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(22),
            child: AspectRatio(
              aspectRatio: 16 / 10,
              child: entry.shouldRenderAsImage
                  ? _imageContent(context)
                  : _videoFallback(context),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: AppTheme.card.withValues(alpha: 0.86),
              border: Border.all(
                color: AppTheme.accent.withValues(alpha: 0.16),
              ),
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.title,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(entry.date.toIso8601String().split('T').first),
                const SizedBox(height: 6),
                Text(
                  'Media: ${entry.mediaType}',
                  style: const TextStyle(color: AppTheme.accentSoft),
                ),
                if (entry.copyright != null) ...[
                  const SizedBox(height: 6),
                  Text('Copyright: ${entry.copyright}'),
                ],
                const SizedBox(height: 12),
                Text(
                  entry.explanation,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
          if (entry.shouldRenderAsImage && entry.bestImageUrl != null) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  var style = WallpaperFit.fill;
                  if (Platform.isWindows) {
                    final picked = await _pickWindowsWallpaperStyle(context);
                    if (picked == null) return;
                    style = picked;
                  }
                  final file = await ref
                      .read(cacheServiceProvider)
                      .imageCache
                      .getSingleFile(entry.bestImageUrl!);
                  final msg = await ref
                      .read(wallpaperServiceProvider)
                      .setImageWallpaper(file.path, style: style);
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(msg)));
                  }
                },
                icon: Icon(Platform.isIOS ? Icons.download : Icons.wallpaper),
                label: Text(
                  Platform.isIOS
                      ? 'Save Image for Wallpaper'
                      : 'Set as Wallpaper',
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _imageContent(BuildContext context) {
    final imageUrl = entry.bestImageUrl;
    if (imageUrl == null) {
      return Container(
        color: const Color(0xFF101A2E),
        alignment: Alignment.center,
        child: const Text(
          'This APOD image is unavailable.',
          style: TextStyle(color: Colors.white70),
        ),
      );
    }
    return PhotoView(
      minScale: PhotoViewComputedScale.contained,
      imageProvider: CachedNetworkImageProvider(imageUrl),
      backgroundDecoration: const BoxDecoration(color: Colors.transparent),
    );
  }

  Future<WallpaperFit?> _pickWindowsWallpaperStyle(BuildContext context) {
    return showModalBottomSheet<WallpaperFit>(
      context: context,
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(title: Text('Wallpaper Style')),
              ListTile(
                title: const Text('Fill'),
                onTap: () => Navigator.pop(context, WallpaperFit.fill),
              ),
              ListTile(
                title: const Text('Stretch'),
                onTap: () => Navigator.pop(context, WallpaperFit.stretch),
              ),
              ListTile(
                title: const Text('Fit'),
                onTap: () => Navigator.pop(context, WallpaperFit.fit),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _videoFallback(BuildContext context) {
    // External player flow keeps video integration lightweight and robust.
    final launch = entry.launchUrl;
    return Container(
      color: const Color(0xFF101A2E),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.ondemand_video,
              size: 46,
              color: AppTheme.accentSoft,
            ),
            const SizedBox(height: 10),
            ElevatedButton(
              onPressed: launch == null
                  ? null
                  : () => launchUrl(Uri.parse(launch)),
              child: Text(
                entry.shouldRenderAsAudio ? 'Open Audio' : 'Open Media',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
