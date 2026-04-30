import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:nasa_apod_app/main.dart';

/// Driver-only entrypoint used by Dart MCP `flutter_driver` commands.
void main() {
  enableFlutterDriverExtension();
  runApp(const ProviderScope(child: NasaApodExplorerApp()));
}
