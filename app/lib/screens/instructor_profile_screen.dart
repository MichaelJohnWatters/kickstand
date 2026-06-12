// Instructor profile — centered hero (avatar + name + role line), the
// list of courses the instructor is accredited to teach (with expiry
// dates), and a Sign-out action. Visual structure mirrors the design
// handoff (`instructor.jsx` → `InstProfile`).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../util/course_colour.dart';
import '../widgets/ks_avatar.dart';

class InstructorProfileScreen extends ConsumerWidget {
  const InstructorProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final id = ref.watch(authControllerProvider).identity;
    final instructorsAsync = ref.watch(instructorsProvider);
    final coursesAsync = ref.watch(courseTypesProvider);

    final me = instructorsAsync.valueOrNull
        ?.firstWhere((i) => i.userId == (id?.userId ?? ''),
            orElse: () => InstructorRow(
                userId: '',
                name: id?.name ?? '',
                email: id?.email ?? '',
                phone: '',
                homeLocationId: '',
                homeLocationName: '',
                accountStatus: '',
                accreditations: const []));

    return Scaffold(
      backgroundColor: KsColors.bg,
      body: SafeArea(
        bottom: false,
        child: RefreshIndicator(
          color: KsColors.primary,
          onRefresh: () async {
            ref.invalidate(instructorsProvider);
            ref.invalidate(courseTypesProvider);
          },
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
            children: [
              _Hero(
                name: id?.name ?? '',
                subtitle: me != null && me.homeLocationName.isNotEmpty
                    ? 'Instructor · ${me.homeLocationName}'
                    : 'Instructor',
              ),
              const SizedBox(height: 18),
              _SectionLabel('Accredited to teach'),
              const SizedBox(height: 8),
              if (instructorsAsync.isLoading || coursesAsync.isLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: CircularProgressIndicator(color: KsColors.primary)),
                )
              else if (me == null || me.accreditations.isEmpty)
                _emptyAccreditations()
              else
                _AccreditationsList(
                  accreditations: me.accreditations,
                  courses: coursesAsync.valueOrNull ?? const [],
                ),
              const SizedBox(height: 18),
              _linkRow(
                icon: Icons.notifications_outlined,
                label: 'Notification preferences',
                onTap: null, // wired up when the prefs screen lands
              ),
              const SizedBox(height: 10),
              _linkRow(
                icon: Icons.logout,
                label: 'Sign out',
                tone: KsColors.danger,
                onTap: () => ref.read(authControllerProvider.notifier).logout(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyAccreditations() => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.lg),
          border: Border.all(color: KsColors.border),
        ),
        child: Column(children: [
          const Icon(Icons.school_outlined, size: 32, color: KsColors.ink4),
          const SizedBox(height: 8),
          Text('No accreditations on file yet',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: KsColors.ink2)),
          const SizedBox(height: 4),
          const Text('Ask your manager to record what you’re cleared to teach.',
              textAlign: TextAlign.center,
              style: TextStyle(color: KsColors.ink3, fontSize: 12.5)),
        ]),
      );

  Widget _linkRow({
    required IconData icon,
    required String label,
    VoidCallback? onTap,
    Color tone = KsColors.ink,
  }) =>
      InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(KsRadius.md),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          decoration: BoxDecoration(
            color: KsColors.surface,
            borderRadius: BorderRadius.circular(KsRadius.md),
            border: Border.all(color: KsColors.border),
            boxShadow: KsShadows.sh1,
          ),
          child: Row(children: [
            Icon(icon,
                size: 18,
                color: tone == KsColors.danger ? KsColors.danger : KsColors.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label,
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: tone)),
            ),
            if (onTap != null)
              const Icon(Icons.chevron_right, color: KsColors.ink4, size: 18)
            else
              Text('Coming soon',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w700,
                      color: KsColors.ink4)),
          ]),
        ),
      );
}

class _Hero extends StatelessWidget {
  final String name;
  final String subtitle;
  const _Hero({required this.name, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14),
      child: Column(
        children: [
          KsAvatar(name: name, size: 84),
          const SizedBox(height: 14),
          Text(name,
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  color: KsColors.ink,
                  letterSpacing: -0.6)),
          const SizedBox(height: 2),
          Text(subtitle,
              style: const TextStyle(
                  color: KsColors.ink3,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);
  @override
  Widget build(BuildContext context) => Text(text.toUpperCase(),
      style: GoogleFonts.plusJakartaSans(
          fontSize: 11.5,
          fontWeight: FontWeight.w800,
          color: KsColors.ink3,
          letterSpacing: 0.6));
}

class _AccreditationsList extends StatelessWidget {
  final List<Accreditation> accreditations;
  final List<CourseTypeLite> courses;
  const _AccreditationsList({required this.accreditations, required this.courses});

  @override
  Widget build(BuildContext context) {
    final byId = {for (final c in courses) c.id: c};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < accreditations.length; i++) ...[
          if (i > 0) const SizedBox(height: 10),
          _AccreditationCard(
            accreditation: accreditations[i],
            course: byId[accreditations[i].courseTypeId],
          ),
        ],
      ],
    );
  }
}

class _AccreditationCard extends StatelessWidget {
  final Accreditation accreditation;
  final CourseTypeLite? course;
  const _AccreditationCard({required this.accreditation, required this.course});

  @override
  Widget build(BuildContext context) {
    final code = course?.code ?? accreditation.courseTypeId;
    final hex = course?.accentColour ?? '';
    final colour = courseColour(code, hex);
    final name = course?.name ?? code;
    final ratioOrCat = [
      if (course?.requiredBikeCategory.isNotEmpty ?? false)
        course!.requiredBikeCategory,
      if (accreditation.expiresOn.isNotEmpty)
        'Expires ${accreditation.expiresOn}',
    ].join(' · ');
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
        boxShadow: KsShadows.sh1,
      ),
      child: Row(children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: colour.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(11),
          ),
          alignment: Alignment.center,
          child: Icon(Icons.menu_book_outlined, color: colour, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name,
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                      color: KsColors.ink)),
              if (ratioOrCat.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(ratioOrCat,
                    style: const TextStyle(
                        color: KsColors.ink3,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600)),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        const Icon(Icons.check_circle, color: KsColors.success, size: 20),
      ]),
    );
  }
}
