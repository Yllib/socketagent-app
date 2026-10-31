import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ui_variant.dart';

/// Entry point of redesign A. The app shows this in place of the classic
/// interface when the user picks A.
class UiARoot extends StatelessWidget {
  const UiARoot({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () =>
              context.read<UiVariantController>().setVariant(UiVariant.classic),
          child: const Text('Interface A is not built yet. Back to Classic'),
        ),
      ),
    );
  }
}
