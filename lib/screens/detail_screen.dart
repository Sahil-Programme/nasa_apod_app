import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/apod_entry.dart';
import '../providers/app_providers.dart';
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
              child: entry.isImage
                  ? PhotoView(
                      minScale: PhotoViewComputedScale.contained,
                      imageProvider: CachedNetworkImageProvider(
                        entry.bestImageUrl!,
                      ),
                      backgroundDecoration: const BoxDecoration(
                        color: Colors.transparent,
                      ),
                    )
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
          if (entry.isImage) ...[
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: () async {
                  final file = await ref
                      .read(cacheServiceProvider)
                      .imageCache
                      .getSingleFile(entry.bestImageUrl!);
                  final msg = await ref
                      .read(wallpaperServiceProvider)
                      .setImageWallpaper(file.path);
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

  Widget _videoFallback(BuildContext context) {
    // External player flow keeps video integration lightweight and robust.
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
              onPressed: () => launchUrl(Uri.parse(entry.url!)),
              child: const Text('Open Video'),
            ),
          ],
        ),
      ),
    );
  }
}
