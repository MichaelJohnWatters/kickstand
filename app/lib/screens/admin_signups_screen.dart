// Admin Sign-ups queue.
//
// Layout per design:
//   - Page head with subtitle
//   - Single onboarding-mode card: description on the left changes with the
//     selected segmented option on the right
//   - "Awaiting approval · N" small-caps section label
//   - Mode-aware empty states (different copy for Open vs Approval)
//   - Applicant cards: initials avatar with stable per-user tone, Pending
//     badge, meta line, phone-as-button, equal-width Approve + Reject

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../state/school.dart';
import '../theme/tokens.dart';

class AdminSignupsScreen extends ConsumerWidget {
  const AdminSignupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pendingAsync = ref.watch(pendingSignupsProvider);
    final settingsAsync = ref.watch(schoolSettingsProvider);

    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async {
        ref.invalidate(pendingSignupsProvider);
        ref.invalidate(schoolSettingsProvider);
      },
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Sign-ups',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: KsColors.ink,
                  letterSpacing: -0.6)),
          const SizedBox(height: 4),
          const Text(
            "How new students join, and who’s waiting to be approved.",
            style: TextStyle(color: KsColors.ink3, fontSize: 13),
          ),
          const SizedBox(height: 18),
          settingsAsync.when(
            loading: () => const _OnboardingSkeleton(),
            error: (_, __) => const SizedBox.shrink(),
            data: (s) => _OnboardingModeCard(currentMode: s.onboardingMode),
          ),
          const SizedBox(height: 18),
          _SectionLabel(
            text: switch (settingsAsync.value?.onboardingMode) {
              'approval' => 'Awaiting approval · ${pendingAsync.maybeWhen(data: (l) => l.length, orElse: () => 0)}',
              _ => 'Awaiting approval',
            },
          ),
          const SizedBox(height: 10),
          // Even in 'open' mode we surface the pending list — those students
          // signed up while approval was required and are still blocked
          // until someone clears them. Only new signups skip approval going
          // forward (the backend reads onboarding_mode on each signup).
          pendingAsync.when(
            loading: () => const _ListLoading(),
            error: (e, _) => _ErrorCard(message: e.toString()),
            data: (applicants) {
              final mode = settingsAsync.value?.onboardingMode;
              if (applicants.isEmpty) {
                return mode == 'open'
                    ? const _OpenModeCard()
                    : const _AllCaughtUpCard();
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (mode == 'open') ...[
                    const _OpenModeBanner(),
                    const SizedBox(height: 12),
                  ],
                  ...applicants.map((a) => Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _ApplicantCard(a),
                      )),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

// ===== Onboarding mode card =====

class _OnboardingModeCard extends ConsumerStatefulWidget {
  final String currentMode;
  const _OnboardingModeCard({required this.currentMode});
  @override
  ConsumerState<_OnboardingModeCard> createState() =>
      _OnboardingModeCardState();
}

class _OnboardingModeCardState extends ConsumerState<_OnboardingModeCard> {
  late String _mode;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.currentMode;
  }

  @override
  void didUpdateWidget(covariant _OnboardingModeCard old) {
    super.didUpdateWidget(old);
    if (!_saving && widget.currentMode != old.currentMode) {
      _mode = widget.currentMode;
    }
  }

  Future<void> _set(String mode) async {
    if (mode == _mode) return;
    final previous = _mode;
    setState(() {
      _mode = mode;
      _saving = true;
    });
    try {
      await ref
          .read(apiClientProvider)
          .updateSchoolSettings(onboardingMode: mode);
      ref.invalidate(schoolSettingsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not update: $e'),
          backgroundColor: KsColors.danger,
          behavior: SnackBarBehavior.floating,
        ));
        setState(() => _mode = previous);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final description = _mode == 'open'
        ? 'Open booking — students sign up and can book straight away. Best for high volume.'
        : 'Approval required — sign-ups land here for you to review (and phone) before they can book. Pending students can browse but not book.';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
        boxShadow: KsShadows.sh1,
      ),
      child: LayoutBuilder(builder: (ctx, c) {
        final twoCol = c.maxWidth >= 560;
        final left = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Text('New student onboarding',
                    style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w800, fontSize: 15.5)),
                if (_saving) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                          color: KsColors.ink3, strokeWidth: 2)),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(description,
                style: const TextStyle(
                    color: KsColors.ink3, fontSize: 13, height: 1.45)),
          ],
        );
        final seg = _Segmented(
          value: _mode,
          onChanged: _saving ? null : _set,
          items: const [
            _SegItem(value: 'open', label: 'Open booking'),
            _SegItem(value: 'approval', label: 'Approval required'),
          ],
        );
        if (twoCol) {
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: left),
              const SizedBox(width: 14),
              seg,
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            left,
            const SizedBox(height: 12),
            seg,
          ],
        );
      }),
    );
  }
}

class _OnboardingSkeleton extends StatelessWidget {
  const _OnboardingSkeleton();
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 96,
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
      ),
      child: const Center(
          child: CircularProgressIndicator(color: KsColors.primary)),
    );
  }
}

// ===== Segmented control =====

class _SegItem {
  final String value;
  final String label;
  const _SegItem({required this.value, required this.label});
}

class _Segmented extends StatelessWidget {
  final String value;
  final ValueChanged<String>? onChanged;
  final List<_SegItem> items;
  const _Segmented(
      {required this.value, required this.onChanged, required this.items});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: KsColors.surface2,
        borderRadius: BorderRadius.circular(KsRadius.pill),
        border: Border.all(color: KsColors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: items.map((it) {
          final on = it.value == value;
          return InkWell(
            onTap: onChanged == null ? null : () => onChanged!(it.value),
            borderRadius: BorderRadius.circular(KsRadius.pill),
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: on ? KsColors.surface : Colors.transparent,
                borderRadius: BorderRadius.circular(KsRadius.pill),
                boxShadow: on ? KsShadows.sh1 : null,
              ),
              child: Text(it.label,
                  style: GoogleFonts.plusJakartaSans(
                      color: on ? KsColors.ink : KsColors.ink3,
                      fontWeight: FontWeight.w700,
                      fontSize: 13)),
            ),
          );
        }).toList(),
      ),
    );
  }
}

// ===== Section label =====

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel({required this.text});
  @override
  Widget build(BuildContext context) {
    return Text(text.toUpperCase(),
        style: GoogleFonts.plusJakartaSans(
            color: KsColors.ink3,
            fontSize: 11.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.6));
  }
}

// ===== Empty state cards =====

class _OpenModeCard extends StatelessWidget {
  const _OpenModeCard();
  @override
  Widget build(BuildContext context) {
    return _emptyCard(
      icon: Icons.bolt_rounded,
      title: 'Open booking is on',
      message:
          'New students book immediately — nothing to approve. Switch to ‘Approval required’ to vet sign-ups first.',
    );
  }
}

/// Small banner shown above the queue when the school is in Open mode but
/// pre-existing pending applicants haven't been cleared yet.
class _OpenModeBanner extends StatelessWidget {
  const _OpenModeBanner();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: KsColors.surface2,
        borderRadius: BorderRadius.circular(KsRadius.md),
        border: Border.all(color: KsColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.bolt_rounded, color: KsColors.ink3, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Open booking is on — new sign-ups go straight to active. '
              'The students below signed up while approval was required, '
              'so they’re still blocked until you clear them.',
              style: GoogleFonts.plusJakartaSans(
                  color: KsColors.ink2, fontSize: 12.5, height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}

class _AllCaughtUpCard extends StatelessWidget {
  const _AllCaughtUpCard();
  @override
  Widget build(BuildContext context) {
    return _emptyCard(
      icon: Icons.check_circle_outline,
      title: 'All caught up',
      message: 'No sign-ups waiting for review.',
    );
  }
}

class _ErrorCard extends StatelessWidget {
  final String message;
  const _ErrorCard({required this.message});
  @override
  Widget build(BuildContext context) {
    return _emptyCard(
      icon: Icons.error_outline,
      title: 'Couldn’t load sign-ups',
      message: message,
      iconColour: KsColors.danger,
    );
  }
}

class _ListLoading extends StatelessWidget {
  const _ListLoading();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 32),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
      ),
      child: const Center(
          child: CircularProgressIndicator(color: KsColors.primary)),
    );
  }
}

Widget _emptyCard({
  required IconData icon,
  required String title,
  required String message,
  Color? iconColour,
}) {
  return Container(
    padding: const EdgeInsets.fromLTRB(24, 36, 24, 36),
    decoration: BoxDecoration(
      color: KsColors.surface,
      borderRadius: BorderRadius.circular(KsRadius.lg),
      border: Border.all(color: KsColors.border),
    ),
    child: Column(
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: KsColors.surface3,
            borderRadius: BorderRadius.circular(KsRadius.md),
          ),
          alignment: Alignment.center,
          child: Icon(icon, color: iconColour ?? KsColors.ink4, size: 26),
        ),
        const SizedBox(height: 14),
        Text(title,
            style: GoogleFonts.plusJakartaSans(
                fontSize: 16, fontWeight: FontWeight.w800)),
        const SizedBox(height: 4),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
                color: KsColors.ink3, fontSize: 13.5, height: 1.45),
          ),
        ),
      ],
    ),
  );
}

// ===== Applicant card =====

class _ApplicantCard extends ConsumerStatefulWidget {
  final PendingApplicant a;
  const _ApplicantCard(this.a);
  @override
  ConsumerState<_ApplicantCard> createState() => _ApplicantCardState();
}

class _ApplicantCardState extends ConsumerState<_ApplicantCard> {
  bool _saving = false;

  Future<void> _approve() => _act(approve: true);

  Future<void> _reject() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KsRadius.lg)),
        title: const Text('Reject this applicant?'),
        content: Text('${widget.a.name} won’t be able to log in.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reject',
                style: TextStyle(color: KsColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _act(approve: false);
  }

  Future<void> _act({required bool approve}) async {
    setState(() => _saving = true);
    final api = ref.read(apiClientProvider);
    try {
      if (approve) {
        await api.approveSignup(widget.a.userId);
      } else {
        await api.rejectSignup(widget.a.userId);
      }
      // pendingSignupsCountProvider derives from this — sidebar updates with it.
      ref.invalidate(pendingSignupsProvider);
      // Approve creates an active student; refresh the Students roster too.
      if (approve) ref.invalidate(studentsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not ${approve ? 'approve' : 'reject'}: $e'),
          backgroundColor: KsColors.danger,
          behavior: SnackBarBehavior.floating,
        ));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copyPhone() async {
    final phone = widget.a.phone;
    if (phone.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: phone));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text('Copied $phone'),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.a;
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
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _InitialsAvatar(name: a.name, seed: a.userId, size: 46),
              const SizedBox(width: 13),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(a.name,
                              overflow: TextOverflow.ellipsis,
                              style: GoogleFonts.plusJakartaSans(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: KsColors.ink)),
                        ),
                        const SizedBox(width: 8),
                        const _PendingBadge(),
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(
                      _metaLine(a),
                      style: const TextStyle(
                          color: KsColors.ink3, fontSize: 12.5),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (a.phone.isNotEmpty) ...[
                const SizedBox(width: 8),
                _PhoneButton(phone: a.phone, onTap: _copyPhone),
              ],
            ],
          ),
          if (a.signupNote.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SignupNoteBlock(text: a.signupNote),
          ],
          const SizedBox(height: 13),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _saving ? null : _approve,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: KsColors.success,
                    foregroundColor: Colors.white,
                    minimumSize: const Size(0, 38),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    textStyle: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w800, fontSize: 13),
                  ),
                  icon: _saving
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2.4))
                      : const Icon(Icons.check_rounded, size: 16),
                  label: const Text('Approve'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _saving ? null : _reject,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: KsColors.ink2,
                    side: const BorderSide(color: KsColors.border2),
                    minimumSize: const Size(0, 38),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    textStyle: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  icon: const Icon(Icons.close_rounded, size: 16),
                  label: const Text('Reject'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _metaLine(PendingApplicant a) {
    final bits = <String>[];
    if (a.licenceCategoryPursued.isNotEmpty) {
      bits.add('Pursuing cat ${a.licenceCategoryPursued}');
    }
    if (a.transmissionPreference.isNotEmpty) {
      bits.add(a.transmissionPreference);
    }
    bits.add('applied ${_relTime(a.signedUpAt)}');
    if (a.dateOfBirth.isNotEmpty) {
      final age = _ageFromDob(a.dateOfBirth);
      if (age != null) bits.add('$age yrs');
    }
    return bits.join(' · ');
  }
}

class _PendingBadge extends StatelessWidget {
  const _PendingBadge();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: KsColors.warningTint,
        borderRadius: BorderRadius.circular(KsRadius.pill),
      ),
      child: Text('Pending',
          style: GoogleFonts.plusJakartaSans(
              color: KsColors.warning,
              fontWeight: FontWeight.w800,
              fontSize: 10.5)),
    );
  }
}

class _PhoneButton extends StatelessWidget {
  final String phone;
  final VoidCallback onTap;
  const _PhoneButton({required this.phone, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Copy phone',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(KsRadius.pill),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            color: KsColors.surface2,
            borderRadius: BorderRadius.circular(KsRadius.pill),
            border: Border.all(color: KsColors.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.phone, size: 14, color: KsColors.ink2),
              const SizedBox(width: 6),
              Text(phone,
                  style: GoogleFonts.plusJakartaSans(
                      color: KsColors.ink,
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Light-grey tinted callout holding the applicant's signup note. Uses
/// surface-3 (a touch greyer than surface-2) so it reads clearly as a
/// distinct section against the white card background; matches the design's
/// note block in `admin-signups.jsx` line 53.
class _SignupNoteBlock extends StatelessWidget {
  final String text;
  const _SignupNoteBlock({required this.text});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 11, 13, 11),
      decoration: BoxDecoration(
        color: KsColors.surface3,
        borderRadius: BorderRadius.circular(KsRadius.md),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 2),
            child:
                Icon(Icons.info_outline, color: KsColors.ink4, size: 15),
          ),
          const SizedBox(width: 9),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    color: KsColors.ink2,
                    fontSize: 13,
                    height: 1.45,
                    fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}

class _InitialsAvatar extends StatelessWidget {
  final String name;
  final String seed;
  final double size;
  const _InitialsAvatar(
      {required this.name, required this.seed, required this.size});

  @override
  Widget build(BuildContext context) {
    final hue = _hueFromSeed(seed);
    final bg = HSLColor.fromAHSL(1, hue, 0.42, 0.90).toColor();
    final fg = HSLColor.fromAHSL(1, hue, 0.55, 0.30).toColor();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(_initialsOf(name),
          style: GoogleFonts.plusJakartaSans(
              color: fg,
              fontWeight: FontWeight.w800,
              fontSize: size * 0.34)),
    );
  }
}

double _hueFromSeed(String s) {
  if (s.isEmpty) return 277;
  var h = 0;
  for (final r in s.runes) {
    h = (h * 31 + r) & 0x7fffffff;
  }
  return (h % 360).toDouble();
}

String _initialsOf(String name) {
  final parts =
      name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
  return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
      .toUpperCase();
}

int? _ageFromDob(String dob) {
  final d = DateTime.tryParse(dob);
  if (d == null) return null;
  final now = DateTime.now();
  int age = now.year - d.year;
  if (now.month < d.month || (now.month == d.month && now.day < d.day)) {
    age--;
  }
  return math.max(age, 0);
}

String _relTime(DateTime t) {
  final diff = DateTime.now().difference(t);
  if (diff.inMinutes < 1) return 'just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  if (diff.inHours < 24) return '${diff.inHours}h ago';
  if (diff.inDays == 1) return 'yesterday';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return DateFormat('d MMM').format(t);
}
