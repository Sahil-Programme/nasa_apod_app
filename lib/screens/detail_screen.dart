import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/apod_entry.dart';
import '../ui/app_theme.dart';
import '../ui/cosmic_scaffold.dart';

/// Full-detail APOD page with zoomable media and metadata panel.
class DetailScreen extends StatelessWidget {
  const DetailScreen({super.key, required this.entry});

  final ApodEntry entry;

  @override
  Widget build(BuildContext context) {
    return CosmicScaffold(
      padding: EdgeInsets.zero,
      appBar: AppBar(
        title: Text(entry.title, maxLines: 1, overflow: TextOverflow.ellipsis),
      ),
      child: Center(
        child: entry.shouldRenderAsImage
            ? _imageContent(context)
            : _videoFallback(context),
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
      tightMode: true,
      initialScale: PhotoViewComputedScale.contained,
      minScale: PhotoViewComputedScale.contained,
      maxScale: PhotoViewComputedScale.contained * 4,
      imageProvider: CachedNetworkImageProvider(imageUrl),
      backgroundDecoration: const BoxDecoration(color: Colors.transparent),
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
