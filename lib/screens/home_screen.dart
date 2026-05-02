import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/apod_entry.dart';
import '../models/slideshow_config.dart';
import '../providers/app_providers.dart';
import '../services/nasa_api_service.dart';
import '../services/wallpaper_service.dart';
import '../ui/app_theme.dart';
import '../ui/cosmic_scaffold.dart';
import '../widgets/space_loading.dart';
import 'detail_screen.dart';
import 'settings_screen.dart';
import 'slideshow_screen.dart';

/// Main immersive screen for APOD exploration and slideshow launching.
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  static final DateTime _firstApodDate = DateTime(1995, 6, 16);
  // APOD allows 1000 requests/hour, but slideshow playback uses range fetches.
  // This cap prevents oversized range payloads and keeps startup responsive.
  static const _maxSlideshowItems = 1000; // APOD API limit
  static const _startupImageRollbackDays = 7;

  bool _infoPanelVisible = true;
  bool _startupLoadScheduled = false;
  bool _startupGateComplete = false;
  bool _startupGateFinalizing = false;
  bool _railExpanded = false;
  bool _portraitActionsOpen = false;
  int _homeLoadToken = 0;
  DateTime? _progressiveImageDate;
  String? _progressiveImageUrl;

  DateTime get _maxApodDate {
    final nowUtc = DateTime.now().toUtc();
    return DateTime(nowUtc.year, nowUtc.month, nowUtc.day);
  }

  @override
  Widget build(BuildContext context) {
    final key = ref.watch(apiKeyProvider);
    final current = ref.watch(currentEntryProvider);
    final usePhonePortraitLayout = _shouldUsePhonePortraitLayout(context);

    if (key == null) {
      return const CosmicScaffold(
        child: Center(
          child: SpaceLoadingIndicator(
            size: SpaceIndicatorSize.small,
            semanticLabel: 'Loading home screen',
          ),
        ),
      );
    }

    _ensureStartupEntryLoaded(key, current);
    if (!_startupGateComplete) {
      return CosmicScaffold(child: _buildStartupSplash(current));
    }

    if (usePhonePortraitLayout) {
      return CosmicScaffold(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 12),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Positioned.fill(
              child: _buildHomeWorkspace(
                context,
                current,
                keyId: const ValueKey('home_workspace_phone_portrait'),
              ),
            ),
            if (_portraitActionsOpen)
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() => _portraitActionsOpen = false),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.16),
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: -22,
              child: _buildPortraitActionBar(context, key, current.valueOrNull),
            ),
          ],
        ),
      );
    }

    return CosmicScaffold(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildLeftRail(context, key, current.valueOrNull),
          const SizedBox(width: 12),
          Expanded(
            child: _buildHomeWorkspace(
              context,
              current,
              keyId: const ValueKey('home_workspace'),
            ),
          ),
        ],
      ),
    );
  }

  bool _shouldUsePhonePortraitLayout(BuildContext context) {
    if (kIsWeb || (!Platform.isAndroid && !Platform.isIOS)) return false;
    final media = MediaQuery.of(context);
    return media.orientation == Orientation.portrait &&
        media.size.shortestSide < 600;
  }

  Widget _buildPortraitActionBar(
    BuildContext context,
    String apiKey,
    ApodEntry? currentEntry,
  ) {
    final actions =
        <({IconData icon, String label, FutureOr<void> Function() onTap})>[
          (
            icon: Icons.today_outlined,
            label: 'Today',
            onTap: () => _load(
              () => ref.read(nasaApiServiceProvider).fetchToday(apiKey),
            ),
          ),
          (
            icon: Icons.calendar_month_outlined,
            label: 'Date',
            onTap: () => _pickAndLoadDate(context, apiKey),
          ),
          (
            icon: Icons.shuffle,
            label: 'Random',
            onTap: () => _load(
              () => ref.read(nasaApiServiceProvider).fetchRandom(apiKey),
              progressiveImageUpgrade: true,
            ),
          ),
          (
            icon: Icons.slideshow_outlined,
            label: 'Slideshow',
            onTap: () => _launchDirectionalSlideshow(context, apiKey),
          ),
          if (currentEntry?.shouldRenderAsImage == true &&
              currentEntry?.bestImageUrl != null)
            (
              icon: Icons.wallpaper_outlined,
              label: 'Wallpaper',
              onTap: () => _setCurrentAsWallpaper(context, currentEntry!),
            ),
          (
            icon: _infoPanelVisible
                ? Icons.visibility_off_outlined
                : Icons.visibility_outlined,
            label: _infoPanelVisible ? 'Hide Info' : 'Show Info',
            onTap: () {
              setState(() => _infoPanelVisible = !_infoPanelVisible);
            },
          ),
          (
            icon: Icons.tune,
            label: 'Settings',
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              );
            },
          ),
        ];

    final gridRows = actions.length <= 3 ? 1 : (actions.length <= 6 ? 2 : 3);
    final panelHeight = 40.0 + (gridRows * 74.0);
    final bottomInset = max(8.0, MediaQuery.of(context).padding.bottom);

    return SizedBox(
      height: panelHeight + 58 + bottomInset,
      child: Padding(
        padding: EdgeInsets.only(bottom: bottomInset),
        child: Stack(
          alignment: Alignment.bottomCenter,
          children: [
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              height: panelHeight,
              child: IgnorePointer(
                ignoring: !_portraitActionsOpen,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 1000),
                  curve: Curves.easeInOutCubic,
                  opacity: _portraitActionsOpen ? 1 : 0,
                  child: AnimatedSlide(
                    duration: const Duration(milliseconds: 1000),
                    curve: Curves.easeInOutCubic,
                    offset: _portraitActionsOpen
                        ? Offset.zero
                        : const Offset(0, 0.16),
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppTheme.card.withValues(alpha: 0.94),
                        borderRadius: BorderRadius.circular(22),
                        border: Border.all(
                          color: AppTheme.accent.withValues(alpha: 0.2),
                        ),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x42000000),
                            blurRadius: 18,
                            offset: Offset(0, 10),
                          ),
                        ],
                      ),
                      padding: const EdgeInsets.fromLTRB(10, 26, 10, 10),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          return _buildPortraitDockGrid(
                            actions: actions,
                            maxWidth: constraints.maxWidth,
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
            AnimatedAlign(
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeInOutCubic,
              alignment: _portraitActionsOpen
                  ? Alignment.topCenter
                  : Alignment.bottomCenter,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(26),
                  onTap: () {
                    setState(
                      () => _portraitActionsOpen = !_portraitActionsOpen,
                    );
                  },
                  child: Ink(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppTheme.accent,
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.accent.withValues(alpha: 0.35),
                          blurRadius: 14,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      child: Icon(
                        _portraitActionsOpen ? Icons.close : Icons.add,
                        key: ValueKey(_portraitActionsOpen),
                        color: AppTheme.bg,
                        size: 24,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPortraitDockGrid({
    required List<
      ({IconData icon, String label, FutureOr<void> Function() onTap})
    >
    actions,
    required double maxWidth,
  }) {
    const spacing = 8.0;
    final tileWidth = (maxWidth - spacing * 2) / 3;

    if (actions.length == 7) {
      final firstRow = actions.sublist(0, 3);
      final secondRow = actions.sublist(3, 6);
      final last = actions[6];
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              for (var i = 0; i < firstRow.length; i++) ...[
                if (i > 0) const SizedBox(width: spacing),
                SizedBox(
                  width: tileWidth,
                  child: _portraitDockActionTile(
                    icon: firstRow[i].icon,
                    label: firstRow[i].label,
                    onTap: () async {
                      setState(() => _portraitActionsOpen = false);
                      await firstRow[i].onTap();
                    },
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: spacing),
          Row(
            children: [
              for (var i = 0; i < secondRow.length; i++) ...[
                if (i > 0) const SizedBox(width: spacing),
                SizedBox(
                  width: tileWidth,
                  child: _portraitDockActionTile(
                    icon: secondRow[i].icon,
                    label: secondRow[i].label,
                    onTap: () async {
                      setState(() => _portraitActionsOpen = false);
                      await secondRow[i].onTap();
                    },
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: spacing),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              SizedBox(
                width: tileWidth,
                child: _portraitDockActionTile(
                  icon: last.icon,
                  label: last.label,
                  onTap: () async {
                    setState(() => _portraitActionsOpen = false);
                    await last.onTap();
                  },
                ),
              ),
            ],
          ),
        ],
      );
    }

    return SingleChildScrollView(
      child: Wrap(
        spacing: spacing,
        runSpacing: spacing,
        children: [
          for (final action in actions)
            SizedBox(
              width: tileWidth,
              child: _portraitDockActionTile(
                icon: action.icon,
                label: action.label,
                onTap: () async {
                  setState(() => _portraitActionsOpen = false);
                  await action.onTap();
                },
              ),
            ),
        ],
      ),
    );
  }

  Widget _portraitDockActionTile({
    required IconData icon,
    required String label,
    required Future<void> Function() onTap,
  }) {
    return FilledButton(
      onPressed: () {
        unawaited(onTap());
      },
      style: FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(66),
        backgroundColor: AppTheme.panel.withValues(alpha: 0.5),
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: AppTheme.accent.withValues(alpha: 0.16)),
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: AppTheme.accentSoft),
          const SizedBox(height: 6),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  Widget _buildLeftRail(
    BuildContext context,
    String apiKey,
    ApodEntry? currentEntry,
  ) {
    final width = _railExpanded ? 178.0 : 76.0;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: width,
      decoration: BoxDecoration(
        color: AppTheme.card.withValues(alpha: 0.78),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.14)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 20,
            offset: Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: Column(
          children: [
            IconButton(
              tooltip: _railExpanded ? 'Collapse rail' : 'Expand rail',
              onPressed: () => setState(() => _railExpanded = !_railExpanded),
              icon: Icon(
                _railExpanded ? Icons.menu_open : Icons.menu,
                color: AppTheme.accentSoft,
              ),
            ),
            const SizedBox(height: 8),

            const SizedBox(height: 8),
            _railItem(
              icon: Icons.today_outlined,
              label: 'Today',
              onTap: () => _load(
                () => ref.read(nasaApiServiceProvider).fetchToday(apiKey),
              ),
            ),
            const SizedBox(height: 8),
            _railItem(
              icon: Icons.calendar_month_outlined,
              label: 'Date',
              onTap: () => _pickAndLoadDate(context, apiKey),
            ),
            const SizedBox(height: 8),
            _railItem(
              icon: Icons.shuffle,
              label: 'Random',
              onTap: () => _load(
                () => ref.read(nasaApiServiceProvider).fetchRandom(apiKey),
                progressiveImageUpgrade: true,
              ),
            ),
            const SizedBox(height: 8),
            _railItem(
              icon: Icons.slideshow_outlined,
              label: 'Slideshow',
              onTap: () => _launchDirectionalSlideshow(context, apiKey),
            ),
            if (currentEntry?.shouldRenderAsImage == true &&
                currentEntry?.bestImageUrl != null) ...[
              const SizedBox(height: 8),
              _railItem(
                icon: Icons.wallpaper_outlined,
                label: 'Wallpaper',
                onTap: () => _setCurrentAsWallpaper(context, currentEntry!),
              ),
            ],
            const Spacer(),
            _railItem(
              icon: _infoPanelVisible
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              label: _infoPanelVisible ? 'Hide Info' : 'Show Info',
              onTap: () =>
                  setState(() => _infoPanelVisible = !_infoPanelVisible),
            ),
            const SizedBox(height: 8),
            _railItem(
              icon: Icons.tune,
              label: 'Settings',
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _railItem({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool selected = false,
  }) {
    final iconWidget = Icon(
      icon,
      size: 21,
      color: selected ? AppTheme.bg : AppTheme.accentSoft,
    );
    final textWidget = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        color: selected ? AppTheme.bg : Colors.white,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
    );

    return Tooltip(
      message: label,
      waitDuration: const Duration(milliseconds: 320),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Ink(
          height: 46,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            color: selected
                ? AppTheme.accent.withValues(alpha: 0.95)
                : AppTheme.panel.withValues(alpha: 0.46),
            border: Border.all(
              color: selected
                  ? Colors.transparent
                  : AppTheme.accent.withValues(alpha: 0.16),
            ),
          ),
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: _railExpanded ? 12 : 0),
            child: _railExpanded
                ? Row(
                    children: [
                      iconWidget,
                      const SizedBox(width: 10),
                      Expanded(child: textWidget),
                    ],
                  )
                : Center(child: iconWidget),
          ),
        ),
      ),
    );
  }

  Widget _buildHomeWorkspace(
    BuildContext context,
    AsyncValue<ApodEntry?> current, {
    required Key keyId,
  }) {
    return Container(
      key: keyId,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: AppTheme.card.withValues(alpha: 0.55),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.12)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            Expanded(
              child: current.when(
                data: (entry) => entry == null
                    ? _emptyPanel(context)
                    : _buildHomeEntryPanel(context, entry),
                loading: () => const Center(
                  child: SpaceLoadingIndicator(
                    semanticLabel: 'Loading APOD entry',
                  ),
                ),
                error: (e, _) => _errorPanel(context, e.toString()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHomeEntryPanel(BuildContext context, ApodEntry entry) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 1080;
        final isPortrait = constraints.maxHeight > constraints.maxWidth;
        final mediaCard = _buildHomeMediaPanel(context, entry);

        if (!_infoPanelVisible) {
          return mediaCard;
        }

        final infoCard = _buildHomeInfoPanel(context, entry);
        if (isWide) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(flex: 7, child: mediaCard),
              const SizedBox(width: 12),
              Expanded(flex: 4, child: infoCard),
            ],
          );
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: isPortrait ? 5 : 6, child: mediaCard),
            const SizedBox(height: 12),
            Expanded(flex: isPortrait ? 6 : 5, child: infoCard),
          ],
        );
      },
    );
  }

  Widget _buildHomeMediaPanel(BuildContext context, ApodEntry entry) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: const Color(0xC40A1121),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.16)),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => DetailScreen(entry: entry)),
              );
            },
            child: _buildEntryMediaSurface(entry),
          ),
        ),
      ),
    );
  }

  Widget _buildEntryMediaSurface(ApodEntry entry) {
    final imageUrl = _effectiveHomeImageUrl(entry);
    if (entry.shouldRenderAsImage && imageUrl != null && imageUrl.isNotEmpty) {
      return LayoutBuilder(
        builder: (context, constraints) {
          return SizedBox(
            width: constraints.maxWidth,
            height: constraints.maxHeight,
            child: Center(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 420),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: CachedNetworkImage(
                  key: ValueKey(
                    'home_img_${entry.date.toIso8601String()}_$imageUrl',
                  ),
                  imageUrl: imageUrl,
                  fit: BoxFit.contain,
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                  placeholder: (_, _) => const Center(
                    child: SpaceLoadingIndicator(
                      size: SpaceIndicatorSize.small,
                      semanticLabel: 'Loading image',
                    ),
                  ),
                  errorWidget: (_, _, _) => const Icon(
                    Icons.broken_image_outlined,
                    color: Colors.white70,
                    size: 38,
                  ),
                ),
              ),
            ),
          );
        },
      );
    }

    final thumbnail = entry.thumbnailUrl;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (thumbnail != null)
          CachedNetworkImage(
            imageUrl: thumbnail,
            fit: BoxFit.cover,
            placeholder: (_, _) =>
                const SpaceImagePlaceholder(showIndicator: false),
            errorWidget: (_, _, _) =>
                const SpaceImagePlaceholder(showIndicator: false),
          )
        else
          const SpaceImagePlaceholder(showIndicator: false),
        Container(color: Colors.black.withValues(alpha: 0.38)),
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

  Widget _buildHomeInfoPanel(BuildContext context, ApodEntry entry) {
    final dateText = _formatDate(entry.date);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: const Color(0xAA11213E),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.14)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              entry.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              dateText,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppTheme.accentSoft),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: SingleChildScrollView(
                child: Text(
                  entry.explanation,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white70,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _ensureStartupEntryLoaded(
    String apiKey,
    AsyncValue<ApodEntry?> current,
  ) {
    if (_startupLoadScheduled) return;
    if (current.isLoading) return;
    if (current.valueOrNull != null) {
      _startupLoadScheduled = true;
      Future.microtask(() => _finalizeStartupGate(entry: current.valueOrNull));
      return;
    }
    _startupLoadScheduled = true;
    Future.microtask(() => _loadLatestDisplayableImage(apiKey));
  }

  Future<void> _loadLatestDisplayableImage(String apiKey) async {
    ref.read(currentEntryProvider.notifier).state = const AsyncLoading();
    try {
      final latestAvailableDate = await _resolveLatestAvailableDate(apiKey);
      for (var offset = 0; offset < _startupImageRollbackDays; offset++) {
        final date = latestAvailableDate.subtract(Duration(days: offset));
        try {
          final entry = offset == 0
              ? await ref.read(nasaApiServiceProvider).fetchToday(apiKey)
              : await ref
                    .read(nasaApiServiceProvider)
                    .fetchByDate(apiKey, date);
          if (_isDisplayableStartupImage(entry)) {
            ref.read(currentEntryProvider.notifier).state = AsyncData(entry);
            unawaited(
              ref
                  .read(cacheServiceProvider)
                  .warmEntry(entry, reason: 'home_startup'),
            );
            await _finalizeStartupGate(entry: entry);
            return;
          }
        } catch (_) {
          // Keep searching previous days for a displayable image.
        }
      }
      ref.read(currentEntryProvider.notifier).state = AsyncError(
        StateError(
          'No displayable APOD image found in the last $_startupImageRollbackDays day(s). Try Date or Random.',
        ),
        StackTrace.current,
      );
    } catch (e, st) {
      ref.read(currentEntryProvider.notifier).state = AsyncError(e, st);
    }
    await _finalizeStartupGate();
  }

  Future<void> _finalizeStartupGate({ApodEntry? entry}) async {
    if (_startupGateComplete || _startupGateFinalizing) return;
    _startupGateFinalizing = true;
    final imageUrl = entry?.bestImageUrl;
    if (entry != null &&
        entry.shouldRenderAsImage &&
        imageUrl != null &&
        imageUrl.trim().isNotEmpty) {
      try {
        await precacheImage(CachedNetworkImageProvider(imageUrl), context);
      } catch (_) {
        // Startup should proceed even if image decoding/network fails.
      }
    }
    if (!mounted) return;
    setState(() {
      _startupGateComplete = true;
      _startupGateFinalizing = false;
    });
  }

  bool _isDisplayableStartupImage(ApodEntry entry) {
    final url = entry.bestImageUrl;
    if (!entry.shouldRenderAsImage || url == null || url.trim().isEmpty) {
      return false;
    }
    final lower = Uri.tryParse(url)?.path.toLowerCase() ?? url.toLowerCase();
    const blocked = <String>{
      '.mp4',
      '.mov',
      '.m4v',
      '.webm',
      '.mkv',
      '.avi',
      '.mp3',
      '.wav',
      '.ogg',
      '.m4a',
      '.flac',
      '.aac',
      '.html',
      '.htm',
      '.pdf',
    };
    return !blocked.any(lower.endsWith);
  }

  Widget _buildStartupSplash(AsyncValue<ApodEntry?> current) {
    final status = current.when(
      data: (_) => 'Preparing your first APOD frame...',
      loading: () => 'Loading today\'s space image...',
      error: (_, _) => 'Could not preload image. Opening explorer...',
    );

    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF040814), Color(0xFF0A1230), Color(0xFF130E2A)],
            ),
          ),
        ),
        Positioned(
          top: -90,
          left: -30,
          child: _splashGlow(220, const Color(0x3348A8FF)),
        ),
        Positioned(
          bottom: -120,
          right: -60,
          child: _splashGlow(260, const Color(0x446D3BFF)),
        ),
        Positioned.fill(child: CustomPaint(painter: _StarfieldPainter())),
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 104,
                height: 104,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const RadialGradient(
                    colors: [
                      Color(0xFF7FCBFF),
                      Color(0xFF1D4D9E),
                      Color(0x00234C94),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF5B8CFF).withValues(alpha: 0.32),
                      blurRadius: 34,
                      spreadRadius: 6,
                    ),
                  ],
                ),
                child: const Icon(Icons.public, size: 48, color: Colors.white),
              ),
              const SizedBox(height: 22),
              Text(
                'NASA APOD Explorer',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                status,
                textAlign: TextAlign.center,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
              ),
              const SizedBox(height: 18),
              const SizedBox(
                width: 26,
                height: 26,
                child: SpaceLoadingIndicator(
                  size: SpaceIndicatorSize.small,
                  semanticLabel: 'Loading startup data',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _splashGlow(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: color, blurRadius: 80, spreadRadius: 30)],
      ),
    );
  }

  Future<void> _pickAndLoadDate(BuildContext context, String apiKey) async {
    final date = await showDatePicker(
      context: context,
      firstDate: _firstApodDate,
      lastDate: _maxApodDate,
      initialDate: _maxApodDate,
    );
    if (date == null) return;

    await _load(
      () => ref
          .read(nasaApiServiceProvider)
          .fetchNearestAvailableByDate(
            apiKey,
            date,
            direction: ApodDateSearchDirection.backward,
            maxSearchDays: 60,
            minDate: _firstApodDate,
            maxDate: _maxApodDate,
          ),
      progressiveImageUpgrade: true,
    );

    if (!context.mounted) return;
    final loaded = ref.read(currentEntryProvider).valueOrNull;
    if (loaded != null && !_isSameDay(loaded.date, date)) {
      final requested = date.toIso8601String().split('T').first;
      final resolved = loaded.date.toIso8601String().split('T').first;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'No APOD found on $requested. Loaded nearest available date: $resolved.',
          ),
        ),
      );
    }
  }

  Future<DateTime?> _resolveSlideshowAnchorDate(
    String apiKey,
    DateTime target,
    SlideshowDirection direction,
    DateTime latestAvailableDate,
  ) async {
    try {
      final entry = await ref
          .read(nasaApiServiceProvider)
          .fetchNearestAvailableByDate(
            apiKey,
            target,
            direction: direction == SlideshowDirection.forward
                ? ApodDateSearchDirection.forward
                : ApodDateSearchDirection.backward,
            maxSearchDays: 120,
            minDate: _firstApodDate,
            maxDate: latestAvailableDate,
          );
      return DateTime(entry.date.year, entry.date.month, entry.date.day);
    } catch (_) {
      return null;
    }
  }

  Future<void> _launchDirectionalSlideshow(
    BuildContext context,
    String apiKey,
  ) async {
    final previousEntryState = ref.read(currentEntryProvider);
    final latestAvailableDate = await _resolveLatestAvailableDate(apiKey);
    if (!context.mounted) return;
    final config = await _pickSlideshowConfig(
      context,
      latestAvailableDate: latestAvailableDate,
    );
    if (!context.mounted || config == null) return;

    final intervalSeconds = ref.read(slideshowIntervalProvider).clamp(8, 300);
    // Runtime is translated to an estimated number of APOD dates to request.
    final requestedSlides = max(
      1,
      config.runDuration.inSeconds ~/ intervalSeconds,
    );
    final slideCount = min(requestedSlides, _maxSlideshowItems);
    final requestedDate = config.startDate.isAfter(latestAvailableDate)
        ? latestAvailableDate
        : config.startDate;
    final safeSelectedDate = await _resolveSlideshowAnchorDate(
      apiKey,
      requestedDate,
      config.direction,
      latestAvailableDate,
    );
    if (safeSelectedDate == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No APOD entry found near that start date in the chosen direction.',
          ),
        ),
      );
      return;
    }

    if (!_isSameDay(safeSelectedDate, requestedDate) && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'Adjusted slideshow start date to ${safeSelectedDate.toIso8601String().split('T').first} (nearest available APOD).',
          ),
        ),
      );
    }

    if (config.direction == SlideshowDirection.forward &&
        _isSameDay(safeSelectedDate, latestAvailableDate)) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No forward slideshow is available from the latest APOD date.',
          ),
        ),
      );
      return;
    }

    DateTime start = safeSelectedDate;
    DateTime end = safeSelectedDate;

    final availableWindow = config.direction == SlideshowDirection.forward
        ? latestAvailableDate.difference(safeSelectedDate).inDays + 1
        : safeSelectedDate.difference(_firstApodDate).inDays + 1;
    if (availableWindow < 2) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No additional APOD entries are available in that direction.',
          ),
        ),
      );
      return;
    }
    final effectiveSlideCount = min(slideCount, max(0, availableWindow));
    if (effectiveSlideCount <= 0) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No APOD entries are available for that slideshow date.',
          ),
        ),
      );
      return;
    }
    final days = max(0, effectiveSlideCount - 1);

    if (config.direction == SlideshowDirection.forward) {
      end = safeSelectedDate.add(Duration(days: days));
      if (end.isAfter(latestAvailableDate)) end = latestAvailableDate;
    } else {
      start = safeSelectedDate.subtract(Duration(days: days));
      if (start.isBefore(_firstApodDate)) start = _firstApodDate;
    }

    ref.read(currentEntryProvider.notifier).state = const AsyncLoading();
    try {
      List<ApodEntry> items;
      try {
        items = await ref
            .read(nasaApiServiceProvider)
            .fetchRange(apiKey, start, end);
      } catch (e) {
        // If NASA rejects the range boundary (common near timezone edges),
        // retry once with an end date shifted back by one day.
        if (end.isAfter(start)) {
          items = await ref
              .read(nasaApiServiceProvider)
              .fetchRange(apiKey, start, end.subtract(const Duration(days: 1)));
        } else {
          rethrow;
        }
      }
      if (items.isEmpty) {
        throw StateError(
          'No APOD entries were returned for slideshow settings.',
        );
      }

      final sanitized = items
          .where(
            (e) =>
                !e.date.isAfter(latestAvailableDate) &&
                !e.date.isBefore(_firstApodDate) &&
                (e.shouldRenderAsImage
                    ? e.bestImageUrl != null
                    : (e.launchUrl != null || e.thumbnailUrl != null)),
          )
          .toList(growable: false);
      if (sanitized.isEmpty) {
        throw StateError(
          'No valid slideshow media found in the selected window.',
        );
      }

      final sorted = [...sanitized]..sort((a, b) => a.date.compareTo(b.date));
      final ordered = config.direction == SlideshowDirection.forward
          ? sorted
          : sorted.reversed.toList(growable: false);
      if (ordered.length < 2) {
        throw StateError(
          'No additional APOD entries are available in that direction.',
        );
      }

      ref.read(slideshowEntriesProvider.notifier).state = ordered;
      ref.read(currentEntryProvider.notifier).state = AsyncData(ordered.first);
      unawaited(
        ref
            .read(cacheServiceProvider)
            .warmEntry(ordered.first, reason: 'slideshow_start'),
      );

      if ((requestedSlides > _maxSlideshowItems ||
              effectiveSlideCount < requestedSlides) &&
          context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Slideshow was trimmed to ${ordered.length} item(s) due to API/date limits.',
            ),
          ),
        );
      }

      if (!context.mounted) return;
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SlideshowScreen(
            runDuration: config.runDuration,
            direction: config.direction,
            startDate: safeSelectedDate,
          ),
        ),
      );
    } catch (e) {
      ref.read(currentEntryProvider.notifier).state = previousEntryState;
      if (!context.mounted) return;
      final message = e.toString().trim().isEmpty
          ? 'Failed to start slideshow.'
          : e.toString();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<SlideshowLaunchConfig?> _pickSlideshowConfig(
    BuildContext context, {
    required DateTime latestAvailableDate,
  }) async {
    final intervalSeconds = ref.read(slideshowIntervalProvider).clamp(8, 300);
    DateTime selectedDate = latestAvailableDate;
    SlideshowDirection direction = SlideshowDirection.forward;
    double durationMinutes = 10;

    return showDialog<SlideshowLaunchConfig>(
      context: context,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setLocalState) {
            final estimatedSlides = max(
              1,
              ((durationMinutes * 60) ~/ intervalSeconds),
            );
            return AlertDialog(
              title: const Text('Start Slideshow'),
              content: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pick one date, a direction, and total runtime.',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                    const SizedBox(height: 14),
                    TextButton.icon(
                      onPressed: () async {
                        final picked = await showDatePicker(
                          context: context,
                          firstDate: _firstApodDate,
                          lastDate: latestAvailableDate,
                          initialDate: selectedDate,
                        );
                        if (picked != null) {
                          setLocalState(() => selectedDate = picked);
                        }
                      },
                      icon: const Icon(Icons.calendar_month),
                      label: Text(
                        'Start date: ${selectedDate.toIso8601String().split('T').first}',
                      ),
                    ),
                    const SizedBox(height: 8),
                    SegmentedButton<SlideshowDirection>(
                      segments: const [
                        ButtonSegment(
                          value: SlideshowDirection.forward,
                          icon: Icon(Icons.arrow_forward),
                          label: Text('Forward'),
                        ),
                        ButtonSegment(
                          value: SlideshowDirection.backward,
                          icon: Icon(Icons.arrow_back),
                          label: Text('Backward'),
                        ),
                      ],
                      selected: {direction},
                      onSelectionChanged: (selection) {
                        setLocalState(() => direction = selection.first);
                      },
                    ),
                    const SizedBox(height: 12),
                    Text('Runtime: ${durationMinutes.round()} minute(s)'),
                    Slider(
                      value: durationMinutes,
                      min: 1,
                      max: 60,
                      divisions: 59,
                      onChanged: (value) =>
                          setLocalState(() => durationMinutes = value),
                    ),
                    Text(
                      'Estimated slides: $estimatedSlides at ${intervalSeconds}s per slide',
                      style: Theme.of(context).textTheme.bodyMedium,
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(
                      context,
                      SlideshowLaunchConfig(
                        startDate: selectedDate,
                        direction: direction,
                        runDuration: Duration(minutes: durationMinutes.round()),
                      ),
                    );
                  },
                  child: const Text('Start'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<DateTime> _resolveLatestAvailableDate(String apiKey) async {
    try {
      final latest = await ref.read(nasaApiServiceProvider).fetchToday(apiKey);
      return DateTime(latest.date.year, latest.date.month, latest.date.day);
    } catch (_) {
      return _maxApodDate;
    }
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> _load(
    Future<ApodEntry> Function() loader, {
    bool progressiveImageUpgrade = false,
  }) async {
    _homeLoadToken++;
    _clearProgressiveImageOverride();
    ref.read(currentEntryProvider.notifier).state = const AsyncLoading();
    try {
      final entry = await loader();
      ref.read(currentEntryProvider.notifier).state = AsyncData(entry);
      if (progressiveImageUpgrade && entry.shouldRenderAsImage) {
        final lowUrl = _lowestQualityImageUrl(entry);
        if (lowUrl != null && lowUrl.trim().isNotEmpty) {
          _setProgressiveImageOverride(entry.date, lowUrl);
          final highUrl = entry.bestImageUrl;
          final token = _homeLoadToken;
          if (highUrl != null &&
              highUrl.trim().isNotEmpty &&
              highUrl != lowUrl) {
            unawaited(
              _upgradeProgressiveHomeImage(
                entry: entry,
                highUrl: highUrl,
                token: token,
              ),
            );
          }
        }
      }
      unawaited(
        ref.read(cacheServiceProvider).warmEntry(entry, reason: 'home'),
      );
    } catch (e) {
      ref.read(currentEntryProvider.notifier).state = AsyncError(
        e,
        StackTrace.current,
      );
    }
  }

  String? _effectiveHomeImageUrl(ApodEntry entry) {
    final override = _progressiveImageUrl;
    final date = _progressiveImageDate;
    if (override != null &&
        date != null &&
        entry.shouldRenderAsImage &&
        _isSameDay(entry.date, date)) {
      return override;
    }
    return entry.bestImageUrl;
  }

  String? _lowestQualityImageUrl(ApodEntry entry) {
    final candidate = entry.thumbnailUrl ?? entry.url ?? entry.hdurl;
    if (candidate == null || candidate.trim().isEmpty) {
      return entry.bestImageUrl;
    }
    return candidate;
  }

  void _setProgressiveImageOverride(DateTime date, String url) {
    if (_progressiveImageUrl == url &&
        _progressiveImageDate != null &&
        _isSameDay(_progressiveImageDate!, date)) {
      return;
    }
    if (!mounted) return;
    setState(() {
      _progressiveImageDate = date;
      _progressiveImageUrl = url;
    });
  }

  void _clearProgressiveImageOverride() {
    if (_progressiveImageDate == null && _progressiveImageUrl == null) return;
    if (!mounted) return;
    setState(() {
      _progressiveImageDate = null;
      _progressiveImageUrl = null;
    });
  }

  Future<void> _upgradeProgressiveHomeImage({
    required ApodEntry entry,
    required String highUrl,
    required int token,
  }) async {
    try {
      await precacheImage(CachedNetworkImageProvider(highUrl), context);
    } catch (_) {
      return;
    }
    if (!mounted || token != _homeLoadToken) return;
    final current = ref.read(currentEntryProvider).valueOrNull;
    if (current == null || !_isSameDay(current.date, entry.date)) return;
    _setProgressiveImageOverride(entry.date, highUrl);
  }

  Future<void> _setCurrentAsWallpaper(
    BuildContext context,
    ApodEntry entry,
  ) async {
    final imageUrl = entry.bestImageUrl;
    if (imageUrl == null) return;

    WallpaperFit style = WallpaperFit.fill;
    if (Platform.isWindows) {
      final picked = await _pickWindowsWallpaperStyle(context);
      if (picked == null) return;
      style = picked;
    }

    final file = await ref
        .read(cacheServiceProvider)
        .imageCache
        .getSingleFile(imageUrl);
    final msg = await ref
        .read(wallpaperServiceProvider)
        .setImageWallpaper(file.path, style: style);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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

  String _formatDate(DateTime date) => date.toIso8601String().split('T').first;

  Widget _emptyPanel(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.16)),
        gradient: const LinearGradient(
          colors: [Color(0x66203A63), Color(0x33131A2B)],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'Load an APOD item using Today, Date, or Random.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
      ),
    );
  }

  Widget _errorPanel(BuildContext context, String msg) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: const Color(0x66A62323),
      ),
      padding: const EdgeInsets.all(16),
      child: Text(
        msg,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: Colors.white),
      ),
    );
  }
}

class _StarfieldPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = Colors.white.withValues(alpha: 0.78);
    final dimPaint = Paint()..color = Colors.white.withValues(alpha: 0.35);
    final maxX = size.width;
    final maxY = size.height;
    if (maxX <= 0 || maxY <= 0) return;

    for (var i = 0; i < 120; i++) {
      final seed = i * 97;
      final x = (seed * 73 % 1000) / 1000 * maxX;
      final y = (seed * 37 % 1000) / 1000 * maxY;
      final radius = i % 7 == 0 ? 1.7 : 1.0;
      canvas.drawCircle(Offset(x, y), radius, i.isEven ? paint : dimPaint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
