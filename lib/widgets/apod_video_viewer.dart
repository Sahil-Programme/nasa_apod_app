import 'package:flutter/material.dart';

/// Wrapper abstraction for video viewer widget composition.
class ApodVideoViewer extends StatelessWidget {
  const ApodVideoViewer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => child;
}
