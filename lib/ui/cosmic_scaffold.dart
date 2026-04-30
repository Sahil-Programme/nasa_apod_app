import 'package:flutter/material.dart';

import 'app_theme.dart';

/// Shared scaffold shell with cosmic background treatment.
///
/// This wrapper keeps all screens visually cohesive while still allowing each
/// screen to provide its own app bar and content.
class CosmicScaffold extends StatelessWidget {
  const CosmicScaffold({
    super.key,
    this.appBar,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
  });

  final PreferredSizeWidget? appBar;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBar,
      body: Stack(
        children: [
          // Base backdrop gradient.
          Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Color(0xFF080D19),
                  Color(0xFF0D1630),
                  Color(0xFF071222),
                ],
              ),
            ),
          ),
          // Accent glows create depth behind the main content.
          Positioned(
            top: -110,
            right: -70,
            child: _glow(220, AppTheme.accent.withValues(alpha: 0.13)),
          ),
          Positioned(
            bottom: -140,
            left: -90,
            child: _glow(260, const Color(0xFF4468FF).withValues(alpha: 0.1)),
          ),
          SafeArea(
            child: Padding(padding: padding, child: child),
          ),
        ],
      ),
    );
  }

  Widget _glow(double size, Color color) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: color, blurRadius: 70, spreadRadius: 22)],
      ),
    );
  }
}
