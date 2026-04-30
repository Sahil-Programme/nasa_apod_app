import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:nasa_apod_app/main.dart';

/// Basic smoke test to ensure app root renders with provider scope.
void main() {
  testWidgets('app boots', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: NasaApodExplorerApp()));
    expect(find.byType(NasaApodExplorerApp), findsOneWidget);
  });
}
