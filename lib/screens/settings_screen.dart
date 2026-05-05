import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/app_providers.dart';
import 'about_me_screen.dart';
import '../ui/cosmic_scaffold.dart';

/// App-level configuration screen for key lifecycle, cache, and slideshow tuning.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  static final Uri _privacyPolicy = Uri.parse(
    'https://stellar-lens-privacy.netlify.app/',
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final interval = ref.watch(slideshowIntervalProvider).clamp(8, 300);
    final lowInternetUsage = ref.watch(lowInternetUsageModeProvider);

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
          const SizedBox(height: 10),
          _tile(
            context,
            title: 'Privacy Policy',
            subtitle: 'How Stellar Lens handles your data',
            icon: Icons.privacy_tip_outlined,
            onTap: () async {
              final launched = await launchUrl(
                _privacyPolicy,
                mode: LaunchMode.externalApplication,
              );
              if (!launched && context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Could not open privacy policy'),
                  ),
                );
              }
            },
          ),
          const SizedBox(height: 10),
          _tile(
            context,
            title: 'About Me',
            subtitle: 'Personal profile and website',
            icon: Icons.person_outline,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AboutMeScreen()),
              );
            },
          ),
          const SizedBox(height: 14),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Low Internet Usage Mode'),
                    subtitle: const Text(
                      'Use standard APOD images instead of HD',
                    ),
                    secondary: const Icon(Icons.data_saver_on_outlined),
                    value: lowInternetUsage,
                    onChanged: (value) =>
                        ref.read(lowInternetUsageModeProvider.notifier).state =
                            value,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    'Slideshow Interval: ${interval}s (${(interval / 60).toStringAsFixed(interval >= 60 ? 1 : 2)} min)',
                  ),
                  Slider(
                    value: interval.toDouble(),
                    min: 8,
                    max: 300,
                    divisions: 292,
                    onChanged: (v) =>
                        ref.read(slideshowIntervalProvider.notifier).state = v
                            .round()
                            .clamp(8, 300),
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
