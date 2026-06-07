import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: KsColors.bg,
      body: Center(
        child: CircularProgressIndicator(color: KsColors.primary, strokeWidth: 2.5),
      ),
    );
  }
}
