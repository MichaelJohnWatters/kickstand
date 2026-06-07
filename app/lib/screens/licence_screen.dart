// Licence & documents — provisional licence, CBT cert + variant + expiry,
// theory pass, DVA/DVSA test history.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/student_top_actions.dart';

final myProfileProvider = FutureProvider<StudentProfile>((ref) async {
  return ref.read(apiClientProvider).myStudentProfile();
});

final myTestsProvider = FutureProvider<List<ExternalTest>>((ref) async {
  final auth = ref.read(authControllerProvider);
  final id = auth.identity!.userId;
  return ref.read(apiClientProvider).studentTests(id);
});

class LicenceScreen extends ConsumerWidget {
  const LicenceScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(myProfileProvider);
    final testsAsync = ref.watch(myTestsProvider);

    return Scaffold(
      backgroundColor: KsColors.bg,
      appBar: AppBar(
        title: Text('Licence & docs',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 22)),
        actions: const [StudentTopActions()],
      ),
      body: RefreshIndicator(
        color: KsColors.primary,
        onRefresh: () async {
          ref.invalidate(myProfileProvider);
          ref.invalidate(myTestsProvider);
        },
        child: profileAsync.when(
          loading: () => const Center(child: CircularProgressIndicator(color: KsColors.primary)),
          error: (e, _) => ListView(children: [Padding(padding: const EdgeInsets.all(24), child: Text('Couldn’t load.\n$e'))]),
          data: (profile) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _ProvisionalCard(profile),
              const SizedBox(height: 12),
              _CBTCard(profile),
              const SizedBox(height: 12),
              _TheoryCard(profile),
              const SizedBox(height: 20),
              Text('${profile.testBodyLabel} test history',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 16, fontWeight: FontWeight.w800, color: KsColors.ink, letterSpacing: -0.3)),
              const SizedBox(height: 8),
              testsAsync.when(
                loading: () => const SizedBox(
                    height: 60, child: Center(child: CircularProgressIndicator(color: KsColors.primary))),
                error: (e, _) => Text('Couldn’t load tests.\n$e'),
                data: (tests) {
                  if (tests.isEmpty) return _NoTestsCard(profile.testBodyLabel);
                  return Column(
                    children: tests.map((t) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _TestRow(t),
                    )).toList(),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ----- Cards -----

class _ProvisionalCard extends StatelessWidget {
  final StudentProfile p;
  const _ProvisionalCard(this.p);
  @override
  Widget build(BuildContext context) {
    return _Card(
      title: 'Provisional licence',
      icon: Icons.badge_outlined,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (p.provisionalLicenceNo.isNotEmpty) ...[
            Text(p.provisionalLicenceNo, style: ksMono(size: 15, weight: FontWeight.w700)),
            const SizedBox(height: 6),
          ],
          _kv('Category', p.licenceCategoryPursued.isEmpty ? '—' : p.licenceCategoryPursued),
          _kv('Transmission', p.transmissionPreference.isEmpty ? '—' : p.transmissionPreference),
        ],
      ),
    );
  }
}

class _CBTCard extends StatelessWidget {
  final StudentProfile p;
  const _CBTCard(this.p);
  @override
  Widget build(BuildContext context) {
    if (!p.cbtHeld) {
      return _Card(
        title: 'CBT certificate',
        icon: Icons.school_outlined,
        statusChip: _chip('Not held', KsColors.warning, KsColors.warningTint),
        child: const Text('Book a CBT day to start.', style: TextStyle(color: KsColors.ink2)),
      );
    }
    final expiresOn = _parseDate(p.cbtExpiresOn);
    final daysLeft = expiresOn?.difference(DateTime.now()).inDays;
    String? expiryLabel;
    Widget? statusChip;
    if (expiresOn != null) {
      expiryLabel = 'Expires ${DateFormat('d MMM yyyy').format(expiresOn)}';
      if (daysLeft != null) {
        if (daysLeft < 0) {
          statusChip = _chip('Expired', KsColors.danger, KsColors.dangerTint);
        } else if (daysLeft < 30) {
          statusChip = _chip('Expires soon', KsColors.warning, KsColors.warningTint);
        } else {
          statusChip = _chip('Valid', KsColors.success, KsColors.successTint);
        }
      }
    } else {
      statusChip = _chip('Held', KsColors.success, KsColors.successTint);
    }
    return _Card(
      title: 'CBT certificate',
      icon: Icons.school_outlined,
      statusChip: statusChip,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (p.cbtVariant.isNotEmpty) _kv('Variant', p.cbtVariant),
          if (expiryLabel != null) _kv('Validity', expiryLabel),
          if (p.cbtRegion.isNotEmpty) _kv('Region', p.cbtRegion),
        ],
      ),
    );
  }
}

class _TheoryCard extends StatelessWidget {
  final StudentProfile p;
  const _TheoryCard(this.p);
  @override
  Widget build(BuildContext context) {
    if (!p.theoryPassed) {
      return _Card(
        title: 'Theory test',
        icon: Icons.menu_book_outlined,
        statusChip: _chip('Not passed', KsColors.warning, KsColors.warningTint),
        child: Text('Required before your practical (${p.testBodyLabel}).',
            style: const TextStyle(color: KsColors.ink2)),
      );
    }
    return _Card(
      title: 'Theory test',
      icon: Icons.menu_book_outlined,
      statusChip: _chip('Passed', KsColors.success, KsColors.successTint),
      child: p.theoryPassedOn.isEmpty
          ? const SizedBox.shrink()
          : _kv('Passed on', p.theoryPassedOn),
    );
  }
}

class _NoTestsCard extends StatelessWidget {
  final String label;
  const _NoTestsCard(this.label);
  @override
  Widget build(BuildContext context) {
    return _Card(
      icon: Icons.fact_check_outlined,
      title: '$label test history',
      child: Text(
        'No $label test attempts recorded yet.\nYour school will add these as they happen.',
        style: const TextStyle(color: KsColors.ink2),
      ),
    );
  }
}

class _TestRow extends StatelessWidget {
  final ExternalTest t;
  const _TestRow(this.t);
  @override
  Widget build(BuildContext context) {
    late Color fg, bg;
    late String label;
    switch (t.outcome) {
      case 'pass': fg = KsColors.success; bg = KsColors.successTint; label = 'Pass'; break;
      case 'fail': fg = KsColors.danger; bg = KsColors.dangerTint; label = 'Fail'; break;
      case 'booked': fg = KsColors.primary; bg = KsColors.primaryTint; label = 'Booked'; break;
      default: fg = KsColors.ink3; bg = KsColors.surface3; label = t.outcome;
    }
    final scheduled = t.scheduledAt;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.md),
        border: Border.all(color: KsColors.border),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_humanTestType(t.testType)} · attempt ${t.attemptNumber}',
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w700, color: KsColors.ink, fontSize: 14),
                ),
                if (scheduled != null) ...[
                  const SizedBox(height: 4),
                  Text(DateFormat('d MMM yyyy').format(scheduled),
                      style: const TextStyle(color: KsColors.ink2, fontSize: 12)),
                ],
              ],
            ),
          ),
          _chip(label, fg, bg),
        ],
      ),
    );
  }

  String _humanTestType(String t) {
    switch (t) {
      case 'theory': return 'Theory';
      case 'practical': return 'Practical';
      case 'mod1': return 'Mod 1';
      case 'mod2': return 'Mod 2';
    }
    return t;
  }
}

// ----- Bits -----

DateTime? _parseDate(String s) {
  if (s.isEmpty) return null;
  try { return DateFormat('yyyy-MM-dd').parseStrict(s); } catch (_) { return null; }
}

Widget _kv(String k, String v) => Padding(
      padding: const EdgeInsets.only(bottom: 3),
      child: Row(
        children: [
          SizedBox(width: 92, child: Text(k, style: const TextStyle(color: KsColors.ink3, fontSize: 13))),
          Expanded(child: Text(v, style: const TextStyle(color: KsColors.ink, fontSize: 14))),
        ],
      ),
    );

Widget _chip(String label, Color fg, Color bg) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(KsRadius.pill)),
      child: Text(label, style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 12)),
    );

class _Card extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;
  final Widget? statusChip;
  const _Card({required this.title, required this.icon, required this.child, this.statusChip});
  @override
  Widget build(BuildContext context) {
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
              Icon(icon, color: KsColors.primary, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(title,
                    style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w800, color: KsColors.ink, fontSize: 15)),
              ),
              if (statusChip != null) statusChip!,
            ],
          ),
          const SizedBox(height: 10),
          child,
        ],
      ),
    );
  }
}
