// Booking confirmation — success state + any advisories the engine surfaced
// (CBT missing, theory missing, cross-site bike, ...).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';

class BookingConfirmationScreen extends ConsumerWidget {
  final String bookingId;
  const BookingConfirmationScreen({required this.bookingId, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final result = ref.watch(lastBookingProvider);

    return Scaffold(
      appBar: AppBar(automaticallyImplyLeading: false),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 84, height: 84,
                decoration: const BoxDecoration(color: KsColors.successTint, shape: BoxShape.circle),
                child: const Icon(Icons.check_rounded, color: KsColors.success, size: 44),
              ).centered(),
              const SizedBox(height: 18),
              Text(
                'Booking confirmed',
                textAlign: TextAlign.center,
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.6, color: KsColors.ink),
              ),
              const SizedBox(height: 8),
              const Text(
                'You’ll get a reminder before your session.',
                textAlign: TextAlign.center,
                style: TextStyle(color: KsColors.ink2),
              ),
              const SizedBox(height: 24),
              if (result?.advisories.isNotEmpty ?? false) _Advisories(result!.advisories),
              const Spacer(),
              ElevatedButton(
                onPressed: () => context.go('/student'),
                child: const Text('Back to home'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Advisories extends StatelessWidget {
  final List<Advisory> advisories;
  const _Advisories(this.advisories);

  @override
  Widget build(BuildContext context) {
    return Column(
      children: advisories
          .map((a) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: KsColors.warningTint,
                    borderRadius: BorderRadius.circular(KsRadius.md),
                    border: Border.all(color: KsColors.warning.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.tips_and_updates_outlined, color: KsColors.warning, size: 18),
                      const SizedBox(width: 10),
                      Expanded(child: Text(a.message, style: const TextStyle(color: KsColors.warning))),
                    ],
                  ),
                ),
              ))
          .toList(),
    );
  }
}

extension _CenterX on Widget {
  Widget centered() => Center(child: this);
}
