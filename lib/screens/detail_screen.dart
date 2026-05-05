import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:photo_view/photo_view.dart';

import '../models/apod_entry.dart';
import '../providers/app_providers.dart';
import '../ui/cosmic_scaffold.dart';
import '../widgets/apod_inline_media.dart';

/// Full-detail APOD page with zoomable media and metadata panel.
class DetailScreen extends ConsumerWidget {
  const DetailScreen({super.key, required this.entry});

  final ApodEntry entry;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lowInternetUsage = ref.watch(lowInternetUsageModeProvider);
    return CosmicScaffold(
      padding: EdgeInsets.zero,
      appBar: AppBar(
        title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      child: Center(
        child: entry.shouldRenderAsImage
            ? _imageContent(context, lowInternetUsage: lowInternetUsage)
            : ApodInlineMedia(
                key: ValueKey(
                  'detail_inline_media_${entry.date.toIso8601String()}',
                ),
                entry: entry,
                autoplayMuted: true,
                showPlaybackControls: true,
                interactive: true,
                fit: BoxFit.contain,
              ),
      ),
    );
  }

  Widget _imageContent(BuildContext context, {required bool lowInternetUsage}) {
    final imageUrl = entry.imageUrlFor(lowInternetUsage: lowInternetUsage);
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
      tightMode: true,
      initialScale: PhotoViewComputedScale.contained,
      minScale: PhotoViewComputedScale.contained,
      maxScale: PhotoViewComputedScale.contained * 4,
      imageProvider: CachedNetworkImageProvider(imageUrl),
      backgroundDecoration: const BoxDecoration(color: Colors.transparent),
    );
  }
}
