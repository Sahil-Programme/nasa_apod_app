import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ui/cosmic_scaffold.dart';

/// Personal profile page with quick link to external website.
class AboutMeScreen extends StatefulWidget {
  const AboutMeScreen({super.key});

  static final Uri _website = Uri.parse('https://www.iamsahilyadav.com');
  static final Uri _coffee = Uri.parse(
    'https://buymeacoffee.com/iamsahilyadav',
  );

  @override
  State<AboutMeScreen> createState() => _AboutMeScreenState();
}

class _AboutMeScreenState extends State<AboutMeScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _supportPulse;

  @override
  void initState() {
    super.initState();
    _supportPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _supportPulse.dispose();
    super.dispose();
  }

  Future<void> _openLink(
    BuildContext context,
    Uri uri, {
    required String errorMessage,
  }) async {
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(errorMessage)));
    }
  }

  @override
  Widget build(BuildContext context) {
    return CosmicScaffold(
      appBar: AppBar(title: const Text('About Me')),
      child: ListView(
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Sahil Yadav',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'I build practical, polished digital experiences with a focus on clean design, useful features, and reliable software.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: () => _openLink(
                      context,
                      AboutMeScreen._website,
                      errorMessage: 'Could not open website',
                    ),
                    icon: const Icon(Icons.language),
                    label: const Text('www.iamsahilyadav.com'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildSupportCard(context),
        ],
      ),
    );
  }

  Widget _buildSupportCard(BuildContext context) {
    return AnimatedBuilder(
      animation: _supportPulse,
      builder: (context, _) {
        final pulse = Curves.easeInOutCubic.transform(_supportPulse.value);
        final glow = 0.10 + (pulse * 0.12);
        final border = 0.24 + (pulse * 0.18);
        final iconLift = -2.5 * pulse;
        final buttonScale = 1 + (pulse * 0.018);

        return Card(
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFFFFD166).withValues(alpha: border),
              ),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0x332B2110), Color(0x11131A2B)],
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFFFD166).withValues(alpha: glow),
                  blurRadius: 14 + (pulse * 12),
                  spreadRadius: pulse * 1.5,
                ),
              ],
            ),
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Transform.translate(
                      offset: Offset(0, iconLift),
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFFFFD166,
                          ).withValues(alpha: 0.14 + (pulse * 0.08)),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.local_cafe_outlined,
                          color: Color(0xFFFFD166),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Enjoying the app?',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'If Stellar Lens made your APOD browsing better, you can support my work with a coffee.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 16),
                Transform.scale(
                  scale: buttonScale,
                  alignment: Alignment.centerLeft,
                  child: FilledButton.icon(
                    onPressed: () => _openLink(
                      context,
                      AboutMeScreen._coffee,
                      errorMessage: 'Could not open Buy Me a Coffee',
                    ),
                    icon: const Icon(Icons.favorite_border),
                    label: const Text('Buy me a coffee'),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
