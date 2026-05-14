import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:md_desktop/main.dart';

void main() {
  testWidgets('renders the empty editor state', (tester) async {
    await tester.pumpWidget(const MdPreviewApp());

    expect(find.text('Open Markdown File'), findsOneWidget);
    expect(find.byIcon(Icons.description_outlined), findsWidgets);
  });
}
