import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/apod_entry.dart';
import '../models/slideshow_config.dart';
import '../providers/app_providers.dart';
import '../ui/app_theme.dart';
import '../ui/cosmic_scaffold.dart';
import '../widgets/apod_card.dart';
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
  // Keep controls visible initially, then tuck them away for immersive viewing.
  static const _controlAutoHideDelay = Duration(seconds: 5);
  static const _pointerWakeDebounce = Duration(milliseconds: 250);
  // APOD rejects very large date windows; keep slideshow request bounded.
  static const _maxSlideshowItems = 100;

  Timer? _hideTimer;
  bool _controlsVisible = true;
  bool _infoPanelVisible = true;
  DateTime _lastPointerWake = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime get _maxApodDate {
    final nowUtc = DateTime.now().toUtc();
    return DateTime(nowUtc.year, nowUtc.month, nowUtc.day);
  }

  @override
  void initState() {
    super.initState();
    _armAutoHideTimer();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final key = ref.watch(apiKeyProvider);
    final current = ref.watch(currentEntryProvider);

    if (key == null) {
      return const CosmicScaffold(
        child: Center(child: CircularProgressIndicator()),
      );
    }

    return CosmicScaffold(
      child: Listener(
        onPointerHover: (_) => _onPointerActivity(),
        onPointerMove: (_) => _onPointerActivity(),
        onPointerDown: (_) => _showControlsTemporarily(),
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: _showControlsTemporarily,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              AnimatedSize(
                duration: const Duration(milliseconds: 240),
                curve: Curves.easeOutCubic,
                child: _controlsVisible
                    ? Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _buildTopControlPanel(context, key),
                      )
                    : Align(
                        alignment: Alignment.centerRight,
                        child: _roundOverlayButton(
                          context: context,
                          icon: Icons.keyboard_arrow_down,
                          tooltip: 'Show controls',
                          onPressed: _showControlsTemporarily,
                        ),
                      ),
              ),
              Expanded(
                child: current.when(
                  data: (entry) => entry == null
                      ? _emptyPanel(context)
                      : LayoutBuilder(
                          builder: (context, constraints) {
                            final isWide = constraints.maxWidth >= 900;
                            final targetAspectRatio = isWide
                                ? (16 / 10)
                                : (4 / 5);
                            return Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 1500,
                                ),
                                child: AspectRatio(
                                  aspectRatio: targetAspectRatio,
                                  child: ApodCard(
                                    entry: entry,
                                    showInfoPanel: _infoPanelVisible,
                                    onTap: () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (_) =>
                                              DetailScreen(entry: entry),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => _errorPanel(context, e.toString()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Tracks user activity and re-arms auto-hide for the top controls.
  void _showControlsTemporarily() {
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _armAutoHideTimer();
  }

  void _armAutoHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_controlAutoHideDelay, () {
      if (!mounted) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _onPointerActivity() {
    final now = DateTime.now();
    if (now.difference(_lastPointerWake) < _pointerWakeDebounce) return;
    _lastPointerWake = now;
    _showControlsTemporarily();
  }

  /// Floating control strip containing fetch actions and navigation affordances.
  Widget _buildTopControlPanel(BuildContext context, String apiKey) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(18),
        color: AppTheme.card.withValues(alpha: 0.82),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.22)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 26,
            offset: Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(10),
      child: Wrap(
        runSpacing: 8,
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _actionChip(context, 'Today', Icons.today, () async {
            _showControlsTemporarily();
            await _load(
              () => ref.read(nasaApiServiceProvider).fetchToday(apiKey),
            );
          }),
          _actionChip(context, 'Date', Icons.calendar_month, () async {
            _showControlsTemporarily();
            final date = await showDatePicker(
              context: context,
              firstDate: _firstApodDate,
              lastDate: _maxApodDate,
              initialDate: _maxApodDate,
            );
            if (date == null) return;
            await _load(
              () => ref.read(nasaApiServiceProvider).fetchByDate(apiKey, date),
            );
          }),
          _actionChip(context, 'Random', Icons.shuffle, () async {
            _showControlsTemporarily();
            await _load(
              () => ref.read(nasaApiServiceProvider).fetchRandom(apiKey),
            );
          }),
          _actionChip(context, 'Slideshow', Icons.slideshow, () async {
            _showControlsTemporarily();
            await _launchDirectionalSlideshow(context, apiKey);
          }),
          _actionChip(
            context,
            _infoPanelVisible ? 'Hide Info' : 'Show Info',
            _infoPanelVisible ? Icons.visibility_off : Icons.info_outline,
            () {
              setState(() => _infoPanelVisible = !_infoPanelVisible);
              _showControlsTemporarily();
            },
          ),
          _actionChip(context, 'Settings', Icons.tune, () {
            _showControlsTemporarily();
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            );
          }),
        ],
      ),
    );
  }

  Future<void> _launchDirectionalSlideshow(
    BuildContext context,
    String apiKey,
  ) async {
    final previousEntryState = ref.read(currentEntryProvider);
    final config = await _pickSlideshowConfig(context);
    if (!mounted || config == null) return;

    final intervalSeconds = ref.read(slideshowIntervalProvider);
    // Runtime is translated to an estimated number of APOD dates to request.
    final requestedSlides = max(
      1,
      config.runDuration.inSeconds ~/ intervalSeconds,
    );
    final slideCount = min(requestedSlides, _maxSlideshowItems);
    final today = _maxApodDate;
    final safeSelectedDate = config.startDate.isAfter(today)
        ? today
        : config.startDate;

    DateTime start = safeSelectedDate;
    DateTime end = safeSelectedDate;

    final availableWindow = config.direction == SlideshowDirection.forward
        ? today.difference(safeSelectedDate).inDays + 1
        : safeSelectedDate.difference(_firstApodDate).inDays + 1;
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
      if (end.isAfter(today)) end = today;
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
                !e.date.isAfter(today) &&
                !e.date.isBefore(_firstApodDate) &&
                (e.isImage
                    ? e.bestImageUrl != null
                    : (e.url != null || e.thumbnailUrl != null)),
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

      ref.read(slideshowEntriesProvider.notifier).state = ordered;
      ref.read(currentEntryProvider.notifier).state = AsyncData(ordered.first);

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
            startDate: config.startDate,
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
    BuildContext context,
  ) async {
    final intervalSeconds = ref.read(slideshowIntervalProvider);
    DateTime selectedDate = _maxApodDate;
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
                          lastDate: _maxApodDate,
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

  Future<void> _load(Future<ApodEntry> Function() loader) async {
    ref.read(currentEntryProvider.notifier).state = const AsyncLoading();
    try {
      final entry = await loader();
      ref.read(currentEntryProvider.notifier).state = AsyncData(entry);
    } catch (e) {
      ref.read(currentEntryProvider.notifier).state = AsyncError(
        e,
        StackTrace.current,
      );
    }
  }

  Widget _actionChip(
    BuildContext context,
    String label,
    IconData icon,
    VoidCallback onTap,
  ) {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: onTap,
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          color: AppTheme.panel.withValues(alpha: 0.66),
          border: Border.all(color: AppTheme.accent.withValues(alpha: 0.2)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: AppTheme.accentSoft),
            const SizedBox(width: 8),
            Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roundOverlayButton({
    required BuildContext context,
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return Tooltip(
      message: tooltip,
      child: IconButton.filledTonal(
        onPressed: onPressed,
        style: IconButton.styleFrom(
          backgroundColor: AppTheme.card.withValues(alpha: 0.78),
          foregroundColor: AppTheme.accentSoft,
          side: BorderSide(color: AppTheme.accent.withValues(alpha: 0.25)),
        ),
        icon: Icon(icon),
      ),
    );
  }

  Widget _emptyPanel(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: AppTheme.accent.withValues(alpha: 0.18)),
        gradient: const LinearGradient(
          colors: [Color(0x88203457), Color(0x55131A2B)],
        ),
      ),
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'Load an APOD item from the top control panel. Controls auto-hide after a few seconds to keep viewing uninterrupted.',
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
