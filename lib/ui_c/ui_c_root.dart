import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ui_variant.dart';

/// Entry point of redesign C. The app shows this in place of the classic
/// interface when the user picks C.
class UiCRoot extends StatelessWidget {
  const UiCRoot({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () =>
              context.read<UiVariantController>().setVariant(UiVariant.classic),
          child: const Text('Interface C is not built yet. Back to Classic'),
        ),
      ),
    );
  }
}
