import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/apod_entry.dart';
import '../ui/app_theme.dart';
import 'space_loading.dart';

/// Hero-style APOD media surface used as the centerpiece on the home screen.
class ApodCard extends StatelessWidget {
  const ApodCard({
    super.key,
    required this.entry,
    this.onTap,
    this.showInfoPanel = true,
  });

  final ApodEntry entry;
  final VoidCallback? onTap;
  final bool showInfoPanel;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          colors: [Color(0xFF121D35), Color(0xFF0C1428)],
        ),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.18)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(24),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isWide = constraints.maxWidth >= 900;

                if (!showInfoPanel) {
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      _buildMedia(context),
                      Positioned(
                        right: 14,
                        bottom: 12,
                        child: _titleBadge(context),
                      ),
                    ],
                  );
                }

                if (isWide) {
                  return Row(
                    children: [
                      Expanded(flex: 6, child: _buildMedia(context)),
                      Expanded(flex: 5, child: _buildInfoPanel(context, true)),
                    ],
                  );
                }

                return Column(
                  children: [
                    Expanded(flex: 6, child: _buildMedia(context)),
                    Expanded(flex: 5, child: _buildInfoPanel(context, false)),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Draws image media or a video thumbnail with "Open Video" CTA.
  Widget _buildMedia(BuildContext context) {
    if (entry.shouldRenderAsImage && entry.bestImageUrl != null) {
      return _networkImage(
        entry.bestImageUrl!,
        fit: BoxFit.cover,
        placeholder: const SpaceImagePlaceholder(
          message: 'Loading image...',
          indicatorSize: SpaceIndicatorSize.small,
        ),
        errorWidget: const Center(child: Icon(Icons.broken_image_outlined)),
      );
    }

    final thumb = entry.thumbnailUrl;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (thumb != null)
          _networkImage(
            thumb,
            fit: BoxFit.cover,
            placeholder: const SpaceImagePlaceholder(showIndicator: false),
            errorWidget: const SpaceImagePlaceholder(showIndicator: false),
          )
        else
          const ColoredBox(color: AppTheme.panel),
        Container(color: Colors.black.withValues(alpha: 0.32)),
        Center(
          child: ElevatedButton.icon(
            onPressed: entry.launchUrl == null
                ? null
                : () => launchUrl(Uri.parse(entry.launchUrl!)),
            icon: Icon(
              entry.shouldRenderAsAudio ? Icons.graphic_eq : Icons.open_in_new,
            ),
            label: Text(
              entry.shouldRenderAsAudio ? 'Open Audio' : 'Open Media',
            ),
          ),
        ),
      ],
    );
  }

  /// Glass panel with title, metadata, and explanation text.
  Widget _buildInfoPanel(BuildContext context, bool isWide) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
      decoration: BoxDecoration(
        color: const Color(0xE4132240),
        border: Border(
          left: isWide
              ? BorderSide(color: AppTheme.accent.withValues(alpha: 0.2))
              : BorderSide.none,
          top: isWide
              ? BorderSide.none
              : BorderSide(color: AppTheme.accent.withValues(alpha: 0.2)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.title,
            maxLines: isWide ? 2 : 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            entry.date.toIso8601String().split('T').first,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppTheme.accentSoft),
          ),
          const SizedBox(height: 6),
          Text(
            'Media: ${entry.mediaType.toUpperCase()}',
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(color: AppTheme.accentSoft),
          ),
          if (entry.copyright != null) ...[
            const SizedBox(height: 6),
            Text(
              'Copyright: ${entry.copyright}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
            ),
          ],
          const SizedBox(height: 10),
          Expanded(
            child: SingleChildScrollView(
              child: Text(
                entry.explanation,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.white70,
                  height: 1.35,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Always-visible title chip for immersive media-only mode.
  Widget _titleBadge(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.46),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.accent.withValues(alpha: 0.24)),
        ),
        child: Text(
          entry.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Colors.white,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _networkImage(
    String imageUrl, {
    required BoxFit fit,
    required Widget placeholder,
    required Widget errorWidget,
  }) {
    return CachedNetworkImage(
      imageUrl: imageUrl,
      fit: fit,
      placeholder: (_, _) => placeholder,
      errorWidget: (_, _, _) => errorWidget,
    );
  }
}
