// Welcome — indigo full-bleed per the design handoff. Two CTAs:
// create account (Firebase signup → /signup) vs sign-in.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../theme/tokens.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KsColors.primary,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 28, 28, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(KsRadius.sm),
                    ),
                    child: const Icon(Icons.two_wheeler, color: Colors.white, size: 22),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    'Kickstand',
                    style: GoogleFonts.plusJakartaSans(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                      fontSize: 20,
                      letterSpacing: -0.4,
                    ),
                  ),
                ],
              ),
              const Spacer(),
              Text(
                'Book your rider training\nin a few taps.',
                style: GoogleFonts.plusJakartaSans(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 34,
                  height: 1.1,
                  letterSpacing: -1.0,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                'CBT, theory, practical — all in one place.',
                style: GoogleFonts.plusJakartaSans(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 16,
                  height: 1.4,
                ),
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: () => context.go('/login'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: KsColors.primaryDeep,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    textStyle: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(KsRadius.md)),
                  ),
                  child: const Text('I already have an account'),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: () => context.go('/signup'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    side: BorderSide(color: Colors.white.withValues(alpha: 0.7)),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    textStyle: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w700, fontSize: 15),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(KsRadius.md)),
                  ),
                  child: const Text('Create account'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
