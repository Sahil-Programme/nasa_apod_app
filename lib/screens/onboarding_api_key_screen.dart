import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../providers/app_providers.dart';
import '../ui/app_theme.dart';
import '../ui/cosmic_scaffold.dart';
import '../widgets/space_loading.dart';

/// First-run onboarding for collecting and validating NASA API credentials.
class OnboardingApiKeyScreen extends ConsumerStatefulWidget {
  const OnboardingApiKeyScreen({super.key});

  @override
  ConsumerState<OnboardingApiKeyScreen> createState() =>
      _OnboardingApiKeyScreenState();
}

class _OnboardingApiKeyScreenState
    extends ConsumerState<OnboardingApiKeyScreen> {
  final c = TextEditingController();
  bool loading = false;
  String? error;

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CosmicScaffold(
      appBar: AppBar(title: const Text('NASA APOD Explorer')),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Connect NASA API',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Bring the cosmos to your device with your personal API key.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 16),
                  _step(context, '1', 'Go to https://api.nasa.gov/'),
                  _step(context, '2', 'Fill out the API signup form'),
                  _step(context, '3', 'Copy the generated API key'),
                  _step(context, '4', 'Paste it below and validate'),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: () =>
                        launchUrl(Uri.parse('https://api.nasa.gov/')),
                    icon: const Icon(Icons.open_in_new),
                    label: const Text('Open NASA API Portal'),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: c,
                    decoration: const InputDecoration(
                      labelText: 'NASA API Key',
                    ),
                  ),
                  if (error != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      error!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                  ],
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: loading
                          ? null
                          : () async {
                              setState(() {
                                loading = true;
                                error = null;
                              });
                              try {
                                await ref
                                    .read(nasaApiServiceProvider)
                                    .validateApiKey(c.text.trim());
                                await ref
                                    .read(apiKeyServiceProvider)
                                    .save(c.text.trim());
                                ref.read(apiKeyProvider.notifier).state = c.text
                                    .trim();
                              } catch (e) {
                                setState(() => error = e.toString());
                              } finally {
                                if (mounted) setState(() => loading = false);
                              }
                            },
                      child: loading
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: SpaceLoadingIndicator(
                                size: SpaceIndicatorSize.tiny,
                                semanticLabel: 'Validating API key',
                              ),
                            )
                          : const Text('Validate & Save Key'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Reusable numbered onboarding step row.
  Widget _step(BuildContext context, String n, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              color: AppTheme.accent.withValues(alpha: 0.2),
            ),
            child: Center(
              child: Text(
                n,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppTheme.accentSoft,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: Colors.white),
            ),
          ),
        ],
      ),
    );
  }
}
