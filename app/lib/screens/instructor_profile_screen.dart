import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/notification_bell.dart';

class InstructorProfileScreen extends ConsumerWidget {
  const InstructorProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(authControllerProvider).identity;
    return Scaffold(
      backgroundColor: KsColors.bg,
      appBar: AppBar(
        title: Text('Profile',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 22)),
        actions: const [NotificationBell()],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: KsColors.surface,
              borderRadius: BorderRadius.circular(KsRadius.lg),
              border: Border.all(color: KsColors.border),
              boxShadow: KsShadows.sh1,
            ),
            child: Row(children: [
              Container(
                width: 56, height: 56,
                decoration: BoxDecoration(
                  color: KsColors.primaryTint,
                  borderRadius: BorderRadius.circular(KsRadius.pill),
                ),
                child: const Icon(Icons.person, color: KsColors.primaryDeep, size: 30),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(id?.name ?? '',
                        style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w800, fontSize: 17, color: KsColors.ink)),
                    const SizedBox(height: 2),
                    Text(id?.email ?? '', style: const TextStyle(color: KsColors.ink3, fontSize: 13)),
                    const SizedBox(height: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                      decoration: BoxDecoration(
                        color: KsColors.primaryTint,
                        borderRadius: BorderRadius.circular(KsRadius.pill),
                      ),
                      child: const Text('Instructor',
                          style: TextStyle(color: KsColors.primaryDeep, fontWeight: FontWeight.w700, fontSize: 11)),
                    ),
                  ],
                ),
              ),
            ]),
          ),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            onPressed: () async => ref.read(authControllerProvider.notifier).logout(),
            style: ElevatedButton.styleFrom(
              backgroundColor: KsColors.danger,
              foregroundColor: Colors.white,
            ),
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Sign out'),
          ),
        ],
      ),
    );
  }
}
