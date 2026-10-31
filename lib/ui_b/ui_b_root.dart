import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../ui_variant.dart';

/// Entry point of redesign B. The app shows this in place of the classic
/// interface when the user picks B.
class UiBRoot extends StatelessWidget {
  const UiBRoot({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () =>
              context.read<UiVariantController>().setVariant(UiVariant.classic),
          child: const Text('Interface B is not built yet. Back to Classic'),
        ),
      ),
    );
  }
}
