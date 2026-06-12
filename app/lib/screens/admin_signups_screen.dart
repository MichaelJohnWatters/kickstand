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
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../state/school.dart';
import '../theme/tokens.dart';
import '../widgets/empty_state.dart';

enum _SignupsTab { pending, approved, rejected }

final _signupsTabProvider =
    StateProvider.autoDispose<_SignupsTab>((_) => _SignupsTab.pending);

class AdminSignupsScreen extends ConsumerWidget {
  const AdminSignupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pendingAsync = ref.watch(pendingSignupsProvider);
    final approvedAsync = ref.watch(approvedSignupsProvider);
    final rejectedAsync = ref.watch(rejectedSignupsProvider);
    final settingsAsync = ref.watch(schoolSettingsProvider);
    final tab = ref.watch(_signupsTabProvider);

    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async {
        ref.invalidate(pendingSignupsProvider);
        ref.invalidate(approvedSignupsProvider);
        ref.invalidate(rejectedSignupsProvider);
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
          // Tab strip — Pending is the daily flow; Approved keeps the
          // last week of approvals around so the manager can still ring
          // the student; Rejected is the escape hatch for the occasional
          // accidental click.
          _TabStrip(
            current: tab,
            pendingCount:
                pendingAsync.maybeWhen(data: (l) => l.length, orElse: () => 0),
            approvedCount:
                approvedAsync.maybeWhen(data: (l) => l.length, orElse: () => 0),
            rejectedCount:
                rejectedAsync.maybeWhen(data: (l) => l.length, orElse: () => 0),
          ),
          const SizedBox(height: 14),
          switch (tab) {
            _SignupsTab.pending => _PendingBody(
                pendingAsync: pendingAsync, settingsAsync: settingsAsync),
            _SignupsTab.approved => _ApprovedBody(approvedAsync: approvedAsync),
            _SignupsTab.rejected => _RejectedBody(rejectedAsync: rejectedAsync),
          },
        ],
      ),
    );
  }
}

class _PendingBody extends StatelessWidget {
  final AsyncValue<List<PendingApplicant>> pendingAsync;
  final AsyncValue<dynamic> settingsAsync;
  const _PendingBody({
    required this.pendingAsync,
    required this.settingsAsync,
  });

  @override
  Widget build(BuildContext context) {
    return pendingAsync.when(
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
                  child: _ApplicantCard(a, mode: _ApplicantCardMode.pending),
                )),
          ],
        );
      },
    );
  }
}

class _ApprovedBody extends StatelessWidget {
  final AsyncValue<List<PendingApplicant>> approvedAsync;
  const _ApprovedBody({required this.approvedAsync});

  @override
  Widget build(BuildContext context) {
    return approvedAsync.when(
      loading: () => const _ListLoading(),
      error: (e, _) => _ErrorCard(message: e.toString()),
      data: (applicants) {
        if (applicants.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: KsColors.surface,
              borderRadius: BorderRadius.circular(KsRadius.lg),
              border: Border.all(color: KsColors.border),
            ),
            child: Column(
              children: [
                const Icon(Icons.thumb_up_alt_outlined,
                    size: 36, color: KsColors.ink4),
                const SizedBox(height: 10),
                Text('No recent approvals',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: KsColors.ink2)),
                const SizedBox(height: 4),
                const Text(
                    'Students you approve land here for a week so you can still call them.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: KsColors.ink3, fontSize: 12.5)),
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final a in applicants)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _ApplicantCard(a, mode: _ApplicantCardMode.approved),
              ),
          ],
        );
      },
    );
  }
}

class _RejectedBody extends StatelessWidget {
  final AsyncValue<List<PendingApplicant>> rejectedAsync;
  const _RejectedBody({required this.rejectedAsync});

  @override
  Widget build(BuildContext context) {
    return rejectedAsync.when(
      loading: () => const _ListLoading(),
      error: (e, _) => _ErrorCard(message: e.toString()),
      data: (applicants) {
        if (applicants.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              color: KsColors.surface,
              borderRadius: BorderRadius.circular(KsRadius.lg),
              border: Border.all(color: KsColors.border),
            ),
            child: Column(
              children: [
                const Icon(Icons.history_toggle_off,
                    size: 36, color: KsColors.ink4),
                const SizedBox(height: 10),
                Text('No rejected sign-ups',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: KsColors.ink2)),
                const SizedBox(height: 4),
                const Text(
                    'Rejections show up here so you can restore one if it was a mistake.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: KsColors.ink3, fontSize: 12.5)),
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final a in applicants)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _ApplicantCard(a, mode: _ApplicantCardMode.rejected),
              ),
          ],
        );
      },
    );
  }
}

/// Pending / Approved / Rejected tab pill row. Lightweight — same look
/// as the Mine/All toggle on instructor schedule, but with counts
/// attached.
class _TabStrip extends ConsumerWidget {
  final _SignupsTab current;
  final int pendingCount;
  final int approvedCount;
  final int rejectedCount;
  const _TabStrip({
    required this.current,
    required this.pendingCount,
    required this.approvedCount,
    required this.rejectedCount,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Row(children: [
      _pill(ref, _SignupsTab.pending, 'Pending', pendingCount),
      const SizedBox(width: 8),
      _pill(ref, _SignupsTab.approved, 'Approved', approvedCount),
      const SizedBox(width: 8),
      _pill(ref, _SignupsTab.rejected, 'Rejected', rejectedCount),
    ]);
  }

  Widget _pill(WidgetRef ref, _SignupsTab tab, String label, int count) {
    final active = current == tab;
    final accent = switch (tab) {
      _SignupsTab.pending => KsColors.primary,
      _SignupsTab.approved => KsColors.success,
      _SignupsTab.rejected => KsColors.ink3,
    };
    final tint = switch (tab) {
      _SignupsTab.pending => KsColors.primaryTint,
      _SignupsTab.approved => KsColors.successTint,
      _SignupsTab.rejected => KsColors.surface3,
    };
    return InkWell(
      onTap: () => ref.read(_signupsTabProvider.notifier).state = tab,
      borderRadius: BorderRadius.circular(KsRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: active ? tint : KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.pill),
          border: Border.all(
              color: active ? accent.withValues(alpha: 0.45) : KsColors.border,
              width: active ? 1.5 : 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label,
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: active ? accent : KsColors.ink2)),
          const SizedBox(width: 7),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: active ? accent : KsColors.surface3,
              borderRadius: BorderRadius.circular(KsRadius.pill),
            ),
            child: Text('$count',
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 10.5,
                    fontWeight: FontWeight.w800,
                    color: active ? Colors.white : KsColors.ink3)),
          ),
        ]),
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

// ===== Empty state cards =====

class _OpenModeCard extends StatelessWidget {
  const _OpenModeCard();
  @override
  Widget build(BuildContext context) {
    return const KsEmptyState(
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
    return const KsEmptyState(
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
    return KsEmptyState.error(
      title: 'Couldn’t load sign-ups',
      message: message,
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

// ===== Applicant card =====

enum _ApplicantCardMode { pending, approved, rejected }

class _ApplicantCard extends ConsumerStatefulWidget {
  final PendingApplicant a;
  final _ApplicantCardMode mode;
  const _ApplicantCard(this.a, {required this.mode});
  @override
  ConsumerState<_ApplicantCard> createState() => _ApplicantCardState();
}

class _ApplicantCardState extends ConsumerState<_ApplicantCard> {
  bool _saving = false;

  Future<void> _approve() => _act(action: _Action.approve);

  Future<void> _reject() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(KsRadius.lg)),
        title: const Text('Reject this applicant?'),
        content: Text(
            '${widget.a.name} won’t be able to log in. You can restore them later from the Rejected tab.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: const Text('Reject',
                style: TextStyle(color: KsColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _act(action: _Action.reject);
  }

  Future<void> _restore() => _act(action: _Action.restore);

  Future<void> _act({required _Action action}) async {
    setState(() => _saving = true);
    final api = ref.read(apiClientProvider);
    try {
      switch (action) {
        case _Action.approve:
          await api.approveSignup(widget.a.userId);
        case _Action.reject:
          await api.rejectSignup(widget.a.userId);
        case _Action.restore:
          await api.restoreSignup(widget.a.userId);
      }
      // Approve / reject / restore all shift between pending and
      // rejected lists — invalidate all three so whichever tab the
      // admin flips to is fresh. Approve in particular needs the
      // approved list invalidated so the newly-approved row pops in.
      ref.invalidate(pendingSignupsProvider);
      ref.invalidate(approvedSignupsProvider);
      ref.invalidate(rejectedSignupsProvider);
      if (action == _Action.approve) ref.invalidate(studentsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not ${action.name}: $e'),
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
                        switch (widget.mode) {
                          _ApplicantCardMode.pending => const _PendingBadge(),
                          _ApplicantCardMode.approved => const _ApprovedBadge(),
                          _ApplicantCardMode.rejected => const _RejectedBadge(),
                        },
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
          // Buttons sit on the leading edge of the card — Expanded
          // stretched them across the whole card which looked clumsy
          // on wider screens. Sized + left-aligned reads as "two
          // actions on this row", not "this card has two giant CTAs".
          if (widget.mode == _ApplicantCardMode.approved)
            Row(children: [
              OutlinedButton.icon(
                onPressed: () =>
                    context.go('/admin/students/${widget.a.userId}'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: KsColors.ink2,
                  side: const BorderSide(color: KsColors.border2),
                  minimumSize: const Size(140, 38),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  textStyle: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w700, fontSize: 13),
                ),
                icon: const Icon(Icons.open_in_new_rounded, size: 16),
                label: const Text('Open student'),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Approved. They can log in and book. Listed here for a week so you can still ring them.',
                  style: TextStyle(color: KsColors.ink3, fontSize: 12),
                ),
              ),
            ])
          else if (widget.mode == _ApplicantCardMode.rejected)
            Row(children: [
              ElevatedButton.icon(
                onPressed: _saving ? null : _restore,
                style: ElevatedButton.styleFrom(
                  backgroundColor: KsColors.primary,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(120, 38),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  textStyle: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800, fontSize: 13),
                ),
                icon: _saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2.4))
                    : const Icon(Icons.replay_rounded, size: 16),
                label: const Text('Restore'),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Sends them back to the Pending tab for re-review. Their account stays disabled until you approve.',
                  style: TextStyle(color: KsColors.ink3, fontSize: 12),
                ),
              ),
            ])
          else
            Row(children: [
              ElevatedButton.icon(
                onPressed: _saving ? null : _approve,
                style: ElevatedButton.styleFrom(
                  backgroundColor: KsColors.primary,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(120, 38),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
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
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _saving ? null : _reject,
                style: OutlinedButton.styleFrom(
                  foregroundColor: KsColors.ink2,
                  side: const BorderSide(color: KsColors.border2),
                  minimumSize: const Size(100, 38),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 14, vertical: 10),
                  textStyle: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w700, fontSize: 13),
                ),
                icon: const Icon(Icons.close_rounded, size: 16),
                label: const Text('Reject'),
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
    if (widget.mode == _ApplicantCardMode.approved && a.approvedAt != null) {
      bits.add('approved ${_relTime(a.approvedAt!)}');
    } else {
      bits.add('applied ${_relTime(a.signedUpAt)}');
    }
    if (a.dateOfBirth.isNotEmpty) {
      final age = _ageFromDob(a.dateOfBirth);
      if (age != null) bits.add('$age yrs');
    }
    return bits.join(' · ');
  }
}

enum _Action { approve, reject, restore }

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

class _ApprovedBadge extends StatelessWidget {
  const _ApprovedBadge();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: KsColors.successTint,
        borderRadius: BorderRadius.circular(KsRadius.pill),
      ),
      child: Text('Approved',
          style: GoogleFonts.plusJakartaSans(
              color: KsColors.success,
              fontWeight: FontWeight.w800,
              fontSize: 10.5)),
    );
  }
}

class _RejectedBadge extends StatelessWidget {
  const _RejectedBadge();
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: KsColors.dangerTint,
        borderRadius: BorderRadius.circular(KsRadius.pill),
      ),
      child: Text('Rejected',
          style: GoogleFonts.plusJakartaSans(
              color: KsColors.danger,
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
