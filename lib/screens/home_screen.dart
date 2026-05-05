import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/apod_entry.dart';
import '../models/slideshow_config.dart';
import '../providers/app_providers.dart';
import '../services/nasa_api_service.dart';
import '../ui/app_theme.dart';
import '../ui/cosmic_scaffold.dart';
import '../widgets/apod_inline_media.dart';
import '../widgets/space_loading.dart';
import 'detail_screen.dart';
import 'settings_screen.dart';
import 'slideshow_screen.dart';
import 'wallpaper_setup_overlay.dart';

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
  static const _initialSlideshowFetchTarget = 14;
  static const _minSlideshowDurationMinutes = 5.0;
  static const _maxSlideshowDurationMinutes = 300.0;

  bool _startupLoadScheduled = false;
  bool _railExpanded = false;
  bool _portraitActionsOpen = false;
  bool _slideshowConfigOpen = false;
  bool _slideshowStartInProgress = false;
  int _homeLoadToken = 0;
  int _slideshowLaunchToken = 0;
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
    final lowInternetUsage = ref.watch(lowInternetUsageModeProvider);
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
              child: _buildPortraitActionBar(
                context,
                key,
                current.valueOrNull,
                lowInternetUsage: lowInternetUsage,
              ),
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
          _buildLeftRail(
            context,
            key,
            current.valueOrNull,
            lowInternetUsage: lowInternetUsage,
          ),
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

  String? _imageUrlForEntry(ApodEntry entry, {bool? lowInternetUsage}) =>
      entry.imageUrlFor(
        lowInternetUsage:
            lowInternetUsage ?? ref.read(lowInternetUsageModeProvider),
      );

  bool _hasDisplayableImage(ApodEntry? entry, {bool? lowInternetUsage}) =>
      entry != null &&
      entry.shouldRenderAsImage &&
      (_imageUrlForEntry(
            entry,
            lowInternetUsage: lowInternetUsage,
          )?.trim().isNotEmpty ??
          false);

  Widget _buildPortraitActionBar(
    BuildContext context,
    String apiKey,
    ApodEntry? currentEntry, {
    required bool lowInternetUsage,
  }) {
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
          if (_hasDisplayableImage(
            currentEntry,
            lowInternetUsage: lowInternetUsage,
          ))
            (
              icon: Icons.wallpaper_outlined,
              label: 'Wallpaper',
              onTap: () => _setCurrentAsWallpaper(context, currentEntry!),
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
    ApodEntry? currentEntry, {
    required bool lowInternetUsage,
  }) {
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
            if (_hasDisplayableImage(
              currentEntry,
              lowInternetUsage: lowInternetUsage,
            )) ...[
              const SizedBox(height: 8),
              _railItem(
                icon: Icons.wallpaper_outlined,
                label: 'Wallpaper',
                onTap: () => _setCurrentAsWallpaper(context, currentEntry!),
              ),
            ],
            const Spacer(),
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

    return ApodInlineMedia(
      key: ValueKey('home_inline_media_${entry.date.toIso8601String()}'),
      entry: entry,
      autoplayMuted: true,
      interactive: false,
      showPlaybackControls: false,
      fit: BoxFit.cover,
      fallbackBuilder: buildInlineMediaFallbackCard,
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
    _startupLoadScheduled = true;
    Future.microtask(
      () => _loadLatestDisplayableImage(
        apiKey,
        showCachedEntry: current.valueOrNull == null,
      ),
    );
  }

  Future<void> _loadLatestDisplayableImage(
    String apiKey, {
    required bool showCachedEntry,
  }) async {
    final token = ++_homeLoadToken;
    _clearProgressiveImageOverride();
    if (ref.read(currentEntryProvider).valueOrNull == null) {
      ref.read(currentEntryProvider.notifier).state = const AsyncLoading();
    }

    if (showCachedEntry) {
      final cached = await ref.read(cacheServiceProvider).readLastHomeEntry();
      if (!mounted || token != _homeLoadToken) return;
      if (cached != null) {
        ref.read(currentEntryProvider.notifier).state = AsyncData(cached);
        _setStartupFirstPaintImage(cached, token);
      }
    }

    try {
      final entry = await _fetchStartupEntryPreferTodayThenYesterday(apiKey);
      if (!mounted || token != _homeLoadToken) return;
      ref.read(currentEntryProvider.notifier).state = AsyncData(entry);
      _setStartupFirstPaintImage(entry, token);
      unawaited(ref.read(cacheServiceProvider).saveLastHomeEntry(entry));
      unawaited(
        ref
            .read(cacheServiceProvider)
            .warmEntry(entry, reason: 'home_startup', lowInternetUsage: true),
      );
    } catch (e, st) {
      if (!mounted || token != _homeLoadToken) return;
      if (ref.read(currentEntryProvider).valueOrNull == null) {
        ref.read(currentEntryProvider.notifier).state = AsyncError(e, st);
      }
    }
  }

  Future<ApodEntry> _fetchStartupEntryPreferTodayThenYesterday(
    String apiKey,
  ) async {
    final api = ref.read(nasaApiServiceProvider);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    try {
      return await api.fetchByDate(apiKey, today);
    } on NasaApiException catch (e) {
      if (!_isNoApodDataYetForDate(e)) rethrow;
      return api.fetchByDate(apiKey, yesterday);
    }
  }

  bool _isNoApodDataYetForDate(NasaApiException error) {
    final message = error.message.toLowerCase();
    return message.contains('no data available') ||
        message.contains('no data for date') ||
        message.contains('date must be between');
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
    } on NasaApiException catch (e) {
      if (_isRecoverableNasaIssue(e)) {
        final clamped = target.isAfter(latestAvailableDate)
            ? latestAvailableDate
            : target;
        return clamped.isBefore(_firstApodDate) ? _firstApodDate : clamped;
      }
      if (e.shouldAbortDateSearch) rethrow;
      return null;
    } catch (_) {
      return null;
    }
  }

  ({DateTime start, DateTime end}) _slideshowRangeForCount({
    required DateTime anchor,
    required SlideshowDirection direction,
    required int count,
    required DateTime latestAvailableDate,
  }) {
    final days = max(0, count - 1);
    var start = anchor;
    var end = anchor;

    if (direction == SlideshowDirection.forward) {
      end = anchor.add(Duration(days: days));
      if (end.isAfter(latestAvailableDate)) end = latestAvailableDate;
    } else {
      start = anchor.subtract(Duration(days: days));
      if (start.isBefore(_firstApodDate)) start = _firstApodDate;
    }

    return (start: start, end: end);
  }

  Future<List<ApodEntry>> _fetchSlideshowRange(
    String apiKey,
    DateTime start,
    DateTime end, {
    int maxDateFallbacks = 0,
  }) async {
    try {
      return await ref
          .read(nasaApiServiceProvider)
          .fetchRange(apiKey, start, end);
    } catch (e) {
      // If NASA rejects the range boundary (common near timezone edges),
      // retry once with an end date shifted back by one day.
      if (end.isAfter(start)) {
        try {
          return await ref
              .read(nasaApiServiceProvider)
              .fetchRange(apiKey, start, end.subtract(const Duration(days: 1)));
        } catch (retryError) {
          if (maxDateFallbacks > 0 &&
              _isRecoverableSlideshowFetchError(retryError)) {
            return _fetchSlideshowDatesIndividually(
              apiKey,
              start,
              end,
              maxDates: maxDateFallbacks,
            );
          }
          rethrow;
        }
      }
      if (maxDateFallbacks > 0 && _isRecoverableSlideshowFetchError(e)) {
        return _fetchSlideshowDatesIndividually(
          apiKey,
          start,
          end,
          maxDates: maxDateFallbacks,
        );
      }
      rethrow;
    }
  }

  Future<List<ApodEntry>> _fetchSlideshowDatesIndividually(
    String apiKey,
    DateTime start,
    DateTime end, {
    required int maxDates,
  }) async {
    final api = ref.read(nasaApiServiceProvider);
    final items = <ApodEntry>[];
    final startDay = DateTime(start.year, start.month, start.day);
    final endDay = DateTime(end.year, end.month, end.day);
    final totalDays = endDay.difference(startDay).inDays + 1;
    final safeCount = min(max(0, totalDays), maxDates);
    Object? lastError;

    for (var offset = 0; offset < safeCount; offset++) {
      final date = startDay.add(Duration(days: offset));
      try {
        items.add(await api.fetchByDate(apiKey, date));
      } on NasaApiException catch (e) {
        if (!_isRecoverableNasaIssue(e) && e.shouldAbortDateSearch) rethrow;
        lastError = e;
      } catch (e) {
        lastError = e;
      }
    }

    if (items.isNotEmpty) return items;
    if (lastError is Exception) throw lastError;
    throw StateError('No APOD entries were available for slideshow fallback.');
  }

  bool _isRecoverableSlideshowFetchError(Object error) =>
      error is NasaApiException && _isRecoverableNasaIssue(error);

  bool _isRecoverableNasaIssue(NasaApiException error) =>
      error.kind == NasaApiFailureKind.server ||
      error.kind == NasaApiFailureKind.network;

  bool _isValidSlideshowEntry(
    ApodEntry entry, {
    required DateTime latestAvailableDate,
  }) {
    if (entry.date.isAfter(latestAvailableDate) ||
        entry.date.isBefore(_firstApodDate)) {
      return false;
    }
    if (entry.shouldRenderAsVideo) return false;
    if (entry.shouldRenderAsImage) {
      return entry
              .imageUrlFor(
                lowInternetUsage: ref.read(lowInternetUsageModeProvider),
              )
              ?.trim()
              .isNotEmpty ??
          false;
    }
    return entry.launchUrl != null || entry.thumbnailUrl != null;
  }

  List<ApodEntry> _sanitizeAndOrderSlideshowItems(
    List<ApodEntry> items, {
    required SlideshowDirection direction,
    required DateTime latestAvailableDate,
  }) {
    final sanitized = items
        .where(
          (entry) => _isValidSlideshowEntry(
            entry,
            latestAvailableDate: latestAvailableDate,
          ),
        )
        .toList(growable: false);
    final sorted = [...sanitized]..sort((a, b) => a.date.compareTo(b.date));
    return direction == SlideshowDirection.forward
        ? sorted
        : sorted.reversed.toList(growable: false);
  }

  Future<void> _loadRemainingSlideshowItems({
    required String apiKey,
    required int token,
    required DateTime start,
    required DateTime end,
    required SlideshowDirection direction,
    required DateTime latestAvailableDate,
  }) async {
    try {
      final items = await _fetchSlideshowRange(apiKey, start, end);
      if (!mounted || token != _slideshowLaunchToken) return;
      final ordered = _sanitizeAndOrderSlideshowItems(
        items,
        direction: direction,
        latestAvailableDate: latestAvailableDate,
      );
      if (ordered.length <= ref.read(slideshowEntriesProvider).length) return;
      ref.read(slideshowEntriesProvider.notifier).state = ordered;
    } catch (_) {
      // The slideshow can continue with the already loaded launch window.
    }
  }

  void _showSlideshowStartingDialog(BuildContext context) {
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: false,
      barrierLabel: 'Starting slideshow',
      barrierColor: Colors.black.withValues(alpha: 0.72),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (context, _, _) {
        return const PopScope(
          canPop: false,
          child: Material(
            type: MaterialType.transparency,
            child: SpaceLoadingSurface(
              message: 'Preparing the next cosmic view...',
              size: SpaceIndicatorSize.large,
            ),
          ),
        );
      },
      transitionBuilder: (context, animation, _, child) {
        return FadeTransition(opacity: animation, child: child);
      },
    );
  }

  void _showSlideshowStartupIssue(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message, maxLines: 2, overflow: TextOverflow.ellipsis),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.panel.withValues(alpha: 0.96),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _launchDirectionalSlideshow(
    BuildContext context,
    String apiKey,
  ) async {
    if (_slideshowConfigOpen || _slideshowStartInProgress) return;

    _slideshowConfigOpen = true;
    final config = await _pickSlideshowConfig(
      context,
      latestAvailableDate: _maxApodDate,
    );
    _slideshowConfigOpen = false;
    if (!context.mounted || config == null) return;

    _slideshowStartInProgress = true;
    final launchToken = ++_slideshowLaunchToken;
    final previousEntryState = ref.read(currentEntryProvider);
    var startingDialogVisible = false;

    final startingDialogTimer = Timer(const Duration(milliseconds: 250), () {
      if (!context.mounted ||
          !_slideshowStartInProgress ||
          launchToken != _slideshowLaunchToken) {
        return;
      }
      startingDialogVisible = true;
      _showSlideshowStartingDialog(context);
    });

    void dismissStartingDialog() {
      startingDialogTimer.cancel();
      if (!startingDialogVisible || !context.mounted) return;
      Navigator.of(context, rootNavigator: true).pop();
      startingDialogVisible = false;
    }

    late final DateTime latestAvailableDate;
    try {
      latestAvailableDate = await _resolveLatestAvailableDate(apiKey);
    } catch (e) {
      if (!context.mounted) return;
      _showSlideshowStartupIssue(
        context,
        'Could not reach NASA APOD. Slideshow was not started.',
      );
      dismissStartingDialog();
      _slideshowStartInProgress = false;
      return;
    }
    if (!context.mounted) {
      _slideshowStartInProgress = false;
      startingDialogTimer.cancel();
      return;
    }

    final requestedDate = config.startDate.isAfter(latestAvailableDate)
        ? latestAvailableDate
        : config.startDate;
    late final DateTime? safeSelectedDate;
    try {
      safeSelectedDate = await _resolveSlideshowAnchorDate(
        apiKey,
        requestedDate,
        config.direction,
        latestAvailableDate,
      );
    } catch (e) {
      if (!context.mounted) return;
      _showSlideshowStartupIssue(
        context,
        'Could not verify that APOD date. Trying again later should work.',
      );
      dismissStartingDialog();
      _slideshowStartInProgress = false;
      return;
    }
    if (safeSelectedDate == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'No APOD entry found near that start date in the chosen direction.',
          ),
        ),
      );
      dismissStartingDialog();
      _slideshowStartInProgress = false;
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

    ref.read(currentEntryProvider.notifier).state = const AsyncLoading();
    try {
      final initialEntry = await _resolveInitialSlideshowEntry(
        apiKey: apiKey,
        startDate: safeSelectedDate,
        direction: config.direction,
        latestAvailableDate: latestAvailableDate,
      );
      if (initialEntry == null) {
        if (!context.mounted) return;
        dismissStartingDialog();
        _showSlideshowStartupIssue(
          context,
          'No valid slideshow media found from that start date in the chosen direction.',
        );
        _slideshowStartInProgress = false;
        return;
      }
      final resolvedInitialDate = DateTime(
        initialEntry.date.year,
        initialEntry.date.month,
        initialEntry.date.day,
      );
      if (!_isSameDay(resolvedInitialDate, safeSelectedDate) &&
          context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Adjusted first slideshow slide to ${resolvedInitialDate.toIso8601String().split('T').first} (first available media).',
            ),
          ),
        );
      }

      ref.read(slideshowEntriesProvider.notifier).state = [initialEntry];
      ref.read(currentEntryProvider.notifier).state = AsyncData(initialEntry);
      unawaited(
        ref
            .read(cacheServiceProvider)
            .warmEntry(
              initialEntry,
              reason: 'slideshow_start',
              lowInternetUsage: ref.read(lowInternetUsageModeProvider),
            ),
      );

      if (!context.mounted) return;
      dismissStartingDialog();
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => SlideshowScreen(
            runDuration: config.runDuration,
            direction: config.direction,
            startDate: safeSelectedDate!,
            latestAvailableDate: latestAvailableDate,
            initialEntry: initialEntry,
          ),
        ),
      );
    } catch (e) {
      ref.read(currentEntryProvider.notifier).state = previousEntryState;
      if (!context.mounted) return;
      dismissStartingDialog();
      _showSlideshowStartupIssue(
        context,
        'NASA APOD is having trouble. Slideshow could not recover.',
      );
    } finally {
      startingDialogTimer.cancel();
      if (startingDialogVisible && context.mounted) {
        Navigator.of(context, rootNavigator: true).pop();
      }
      if (launchToken == _slideshowLaunchToken) {
        _slideshowStartInProgress = false;
      }
    }
  }

  Future<ApodEntry?> _resolveInitialSlideshowEntry({
    required String apiKey,
    required DateTime startDate,
    required SlideshowDirection direction,
    required DateTime latestAvailableDate,
  }) async {
    final step = direction == SlideshowDirection.forward ? 1 : -1;
    var cursor = DateTime(startDate.year, startDate.month, startDate.day);
    final maxHops = direction == SlideshowDirection.forward
        ? latestAvailableDate.difference(cursor).inDays
        : cursor.difference(_firstApodDate).inDays;
    final api = ref.read(nasaApiServiceProvider);

    for (var hop = 0; hop <= max(0, maxHops); hop++) {
      if (cursor.isBefore(_firstApodDate) ||
          cursor.isAfter(latestAvailableDate)) {
        break;
      }
      try {
        final entry = await api.fetchByDate(apiKey, cursor);
        if (_isValidSlideshowEntry(
          entry,
          latestAvailableDate: latestAvailableDate,
        )) {
          return entry;
        }
      } on NasaApiException catch (e) {
        if (e.shouldAbortDateSearch) rethrow;
      } catch (_) {
        // Keep scanning along the chosen direction.
      }
      cursor = cursor.add(Duration(days: step));
    }
    return null;
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
                    Text(
                      'Runtime: ${_formatSlideshowRuntime(durationMinutes)}',
                    ),
                    Slider(
                      value: durationMinutes,
                      min: _minSlideshowDurationMinutes,
                      max: _maxSlideshowDurationMinutes,
                      divisions:
                          (_maxSlideshowDurationMinutes -
                                  _minSlideshowDurationMinutes)
                              .round(),
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
    } on NasaApiException catch (e) {
      if (!_isRecoverableNasaIssue(e) && e.shouldAbortDateSearch) rethrow;
      return _maxApodDate;
    } catch (_) {
      return _maxApodDate;
    }
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  String _formatSlideshowRuntime(double minutesValue) {
    final minutes = minutesValue.round();
    if (minutes < 60) return '$minutes minute(s)';
    final hours = minutes ~/ 60;
    final remainder = minutes % 60;
    if (remainder == 0) return '$hours hour(s)';
    return '$hours hour(s) $remainder minute(s)';
  }

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
      if (progressiveImageUpgrade &&
          entry.shouldRenderAsImage &&
          !ref.read(lowInternetUsageModeProvider)) {
        final lowUrl = _lowestQualityImageUrl(entry);
        if (lowUrl != null && lowUrl.trim().isNotEmpty) {
          _setProgressiveImageOverride(entry.date, lowUrl);
          final highUrl = entry.imageUrlFor(lowInternetUsage: false);
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
        ref
            .read(cacheServiceProvider)
            .warmEntry(
              entry,
              reason: 'home',
              lowInternetUsage: ref.read(lowInternetUsageModeProvider),
            ),
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
    if (!ref.read(lowInternetUsageModeProvider) &&
        override != null &&
        date != null &&
        entry.shouldRenderAsImage &&
        _isSameDay(entry.date, date)) {
      return override;
    }
    return _imageUrlForEntry(entry);
  }

  String? _lowestQualityImageUrl(ApodEntry entry) {
    final candidate = entry.thumbnailUrl ?? entry.url ?? entry.hdurl;
    if (candidate == null || candidate.trim().isEmpty) {
      return entry.imageUrlFor(lowInternetUsage: false);
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

  String? _startupFirstPaintImageUrl(ApodEntry entry) {
    final candidate = entry.standardImageUrl ?? entry.bestImageUrl;
    if (candidate == null || candidate.trim().isEmpty) return null;
    return candidate;
  }

  void _setStartupFirstPaintImage(ApodEntry entry, int token) {
    if (ref.read(lowInternetUsageModeProvider) || !entry.shouldRenderAsImage) {
      return;
    }

    final lowUrl = _startupFirstPaintImageUrl(entry);
    if (lowUrl == null) return;
    _setProgressiveImageOverride(entry.date, lowUrl);

    final highUrl = entry.imageUrlFor(lowInternetUsage: false);
    if (highUrl == null || highUrl.trim().isEmpty || highUrl == lowUrl) {
      return;
    }
    unawaited(
      _upgradeProgressiveHomeImage(
        entry: entry,
        highUrl: highUrl,
        token: token,
      ),
    );
  }

  Future<void> _setCurrentAsWallpaper(
    BuildContext context,
    ApodEntry entry,
  ) async {
    final imageUrl = _imageUrlForEntry(entry);
    if (imageUrl == null) return;

    final wallpaperService = ref.read(wallpaperServiceProvider);
    final file = await ref
        .read(cacheServiceProvider)
        .imageCache
        .getSingleFile(imageUrl);
    if (!context.mounted) return;
    if (Platform.isAndroid) {
      final confirm = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('Set wallpaper?'),
          content: const Text(
            'Open Android wallpaper settings for this image?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (!context.mounted || confirm != true) return;
      final msg = await wallpaperService.openAndroidSystemWallpaperPicker(
        file.path,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      return;
    }
    final platformTargetSize = await wallpaperService
        .getPlatformWallpaperTargetSize();
    if (!context.mounted) return;
    final setup = await showWallpaperSetupOverlay(
      context,
      sourcePath: file.path,
      title: entry.title,
      platformTargetSize: platformTargetSize,
    );
    if (!context.mounted || setup == null || !setup.applied) return;
    final outputPath = setup.outputPath ?? file.path;

    final msg = await wallpaperService.setImageWallpaper(
      outputPath,
      style: setup.style,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
