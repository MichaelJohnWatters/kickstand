// Progress — per-course rollup of the student's competency status.
//
// Pulls /students/{id}/progress (the engine already filters to non_teaching=0
// courses, so test days don't appear here).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/student_top_actions.dart';

final myProgressProvider = FutureProvider<List<CourseProgress>>((ref) async {
  final api = ref.read(apiClientProvider);
  final auth = ref.read(authControllerProvider);
  final id = auth.identity!.userId;
  return api.studentProgress(id);
});

class ProgressScreen extends ConsumerWidget {
  const ProgressScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myProgressProvider);
    return Scaffold(
      backgroundColor: KsColors.bg,
      appBar: AppBar(
        title: Text('Progress',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 22)),
        actions: const [StudentTopActions()],
      ),
      body: RefreshIndicator(
        color: KsColors.primary,
        onRefresh: () async => ref.invalidate(myProgressProvider),
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator(color: KsColors.primary)),
          error: (e, _) => ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text('Couldn’t load progress.\n$e'))]),
          data: (courses) {
            if (courses.isEmpty) return const _EmptyState();
            return ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: courses.length,
              separatorBuilder: (_, __) => const SizedBox(height: 14),
              itemBuilder: (ctx, i) => _CourseCard(courses[i]),
            );
          },
        ),
      ),
    );
  }
}

class _CourseCard extends StatelessWidget {
  final CourseProgress c;
  const _CourseCard(this.c);
  @override
  Widget build(BuildContext context) {
    final pct = c.totalCompetencies == 0 ? 0.0 : c.competentCount / c.totalCompetencies;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
        boxShadow: KsShadows.sh1,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(c.courseName,
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 16, fontWeight: FontWeight.w800, color: KsColors.ink, letterSpacing: -0.3)),
              ),
              Text('${c.competentCount}/${c.totalCompetencies}',
                  style: GoogleFonts.plusJakartaSans(
                      color: KsColors.primaryDeep, fontWeight: FontWeight.w700)),
            ],
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(KsRadius.pill),
            child: LinearProgressIndicator(
              value: pct,
              minHeight: 8,
              backgroundColor: KsColors.surface3,
              valueColor: const AlwaysStoppedAnimation(KsColors.primary),
            ),
          ),
          if (c.needsWorkCount > 0) ...[
            const SizedBox(height: 8),
            Text('${c.needsWorkCount} needs work',
                style: const TextStyle(color: KsColors.warning, fontSize: 12, fontWeight: FontWeight.w600)),
          ],
          const SizedBox(height: 14),
          ...c.competencies.map((cm) => _CompetencyRow(cm)),
        ],
      ),
    );
  }
}

class _CompetencyRow extends StatelessWidget {
  final CompetencyProgress c;
  const _CompetencyRow(this.c);
  @override
  Widget build(BuildContext context) {
    late IconData icon;
    late Color fg;
    switch (c.status) {
      case 'competent':
        icon = Icons.check_circle; fg = KsColors.success; break;
      case 'developing':
        icon = Icons.adjust; fg = KsColors.primary; break;
      case 'needs_work':
        icon = Icons.error_outline; fg = KsColors.warning; break;
      default:
        icon = Icons.radio_button_unchecked; fg = KsColors.ink4;
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(icon, color: fg, size: 18),
          const SizedBox(width: 10),
          Expanded(child: Text(c.label, style: const TextStyle(color: KsColors.ink, fontSize: 14))),
          if (c.status != 'not_assessed')
            Text(_statusLabel(c.status),
                style: TextStyle(color: fg, fontSize: 12, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  String _statusLabel(String s) {
    switch (s) {
      case 'competent': return 'Competent';
      case 'developing': return 'Developing';
      case 'needs_work': return 'Needs work';
    }
    return '';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.insights_outlined, size: 48, color: KsColors.ink4),
            const SizedBox(height: 12),
            Text('Progress will show here',
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 16, fontWeight: FontWeight.w700, color: KsColors.ink)),
            const SizedBox(height: 4),
            const Text('Once your instructor signs off competencies, they appear here.',
                textAlign: TextAlign.center, style: TextStyle(color: KsColors.ink2)),
          ],
        ),
      ),
    );
  }
}
