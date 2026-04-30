import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_providers.dart';
import '../ui/cosmic_scaffold.dart';

/// App-level configuration screen for key lifecycle, cache, and slideshow tuning.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final interval = ref.watch(slideshowIntervalProvider);
    final precache = ref.watch(precacheWindowProvider);

    return CosmicScaffold(
      appBar: AppBar(title: const Text('Settings')),
      child: ListView(
        children: [
          _tile(
            context,
            title: 'Update API Key',
            subtitle: 'Return to onboarding and replace saved key',
            icon: Icons.vpn_key,
            onTap: () async {
              await ref.read(apiKeyServiceProvider).clear();
              ref.read(apiKeyProvider.notifier).state = null;
              if (context.mounted) Navigator.pop(context);
            },
          ),
          const SizedBox(height: 10),
          _tile(
            context,
            title: 'Clear Cache',
            subtitle: 'Remove saved APOD metadata and media cache',
            icon: Icons.cleaning_services,
            onTap: () async {
              await ref.read(cacheServiceProvider).clearAll();
              if (context.mounted) {
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('Cache cleared')));
              }
            },
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Slideshow Interval: ${interval}s'),
                  Slider(
                    value: interval.toDouble(),
                    min: 3,
                    max: 20,
                    divisions: 17,
                    onChanged: (v) =>
                        ref.read(slideshowIntervalProvider.notifier).state = v
                            .round(),
                  ),
                  const SizedBox(height: 8),
                  Text('Pre-cache Window: $precache item(s)'),
                  Slider(
                    value: precache.toDouble(),
                    min: 1,
                    max: 8,
                    divisions: 7,
                    onChanged: (v) =>
                        ref.read(precacheWindowProvider.notifier).state = v
                            .round(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
  }) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: onTap,
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: Theme.of(context).cardTheme.color,
        ),
        child: ListTile(
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
        ),
      ),
    );
  }
}
