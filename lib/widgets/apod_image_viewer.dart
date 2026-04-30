import 'package:flutter/material.dart';

/// Wrapper abstraction for image viewer widget composition.
class ApodImageViewer extends StatelessWidget {
  const ApodImageViewer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
