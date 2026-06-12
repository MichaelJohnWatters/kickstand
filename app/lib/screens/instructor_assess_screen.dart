// Instructor Assess — per-booking competency capture + notes.
//
// Loads session detail, finds the booking, and renders:
//   - Header: back, "Assess · CourseName" eyebrow, big student name,
//     progress ring (competent / total)
//   - Compact attendance row (Present / No-show)
//   - Test-day banner instead of competencies when the course is
//     non-teaching
//   - Safety-flags banner (if any)
//   - Competencies section with one row per item, each row offering
//     four status pills (Not assessed / Developing / Competent / Needs
//     work)
//   - Session notes textarea (autosaves on blur)
//
// Every control commits immediately so partial work isn't lost. Visual
// structure mirrors the design handoff (`instructor.jsx` →
// `CompetencyCapture`); the four-status model is deliberately richer
// than the design's binary checklist because that's how the engine
// stores progress.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../state/providers.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../util/course_colour.dart';
import '../widgets/ks_avatar.dart';
import '../widgets/progress_ring.dart';
import 'instructor_session_detail_screen.dart';

class InstructorAssessScreen extends ConsumerStatefulWidget {
  final String sessionId;
  final String bookingId;
  const InstructorAssessScreen({
    required this.sessionId,
    required this.bookingId,
    super.key,
  });

  @override
  ConsumerState<InstructorAssessScreen> createState() =>
      _InstructorAssessScreenState();
}

class _InstructorAssessScreenState
    extends ConsumerState<InstructorAssessScreen> {
  late TextEditingController _notesCtrl;
  final _notesFocus = FocusNode();
  String _initialNotes = '';
  Set<String> _savingCompetencies = {};
  bool _markingAttendance = false;

  @override
  void initState() {
    super.initState();
    _notesCtrl = TextEditingController();
    _notesFocus.addListener(_onNotesFocusChange);
  }

  @override
  void dispose() {
    _notesFocus.removeListener(_onNotesFocusChange);
    _notesFocus.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  void _onNotesFocusChange() {
    if (!_notesFocus.hasFocus && _notesCtrl.text != _initialNotes) {
      _saveNotes();
    }
  }

  Future<void> _saveNotes() async {
    final api = ref.read(apiClientProvider);
    final text = _notesCtrl.text;
    try {
      await api.setBookingNotes(bookingId: widget.bookingId, notes: text);
      _initialNotes = text;
      ref.invalidate(sessionDetailProvider(widget.sessionId));
      _showToast('Notes saved');
    } catch (e) {
      _showToast('Could not save notes', error: true);
    }
  }

  Future<void> _setAttendance(String status) async {
    setState(() => _markingAttendance = true);
    final api = ref.read(apiClientProvider);
    try {
      await api.markAttendance(bookingId: widget.bookingId, status: status);
      ref.invalidate(sessionDetailProvider(widget.sessionId));
      _showToast(status == 'completed' ? 'Marked present' : 'Marked no-show');
    } catch (e) {
      _showToast('Could not update attendance', error: true);
    } finally {
      if (mounted) setState(() => _markingAttendance = false);
    }
  }

  Future<void> _setCompetency(String compId, String status) async {
    setState(() => _savingCompetencies = {..._savingCompetencies, compId});
    final api = ref.read(apiClientProvider);
    try {
      await api.assessCompetency(
          bookingId: widget.bookingId, competencyId: compId, status: status);
      ref.invalidate(sessionDetailProvider(widget.sessionId));
    } catch (e) {
      _showToast('Could not save', error: true);
    } finally {
      if (mounted) {
        setState(() =>
            _savingCompetencies = {..._savingCompetencies}..remove(compId));
      }
    }
  }

  void _showToast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? KsColors.danger : KsColors.ink,
      duration: const Duration(seconds: 2),
      behavior: SnackBarBehavior.floating,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(sessionDetailProvider(widget.sessionId));
    return Scaffold(
      backgroundColor: KsColors.bg,
      body: SafeArea(
        bottom: false,
        child: async.when(
          loading: () =>
              const Center(child: CircularProgressIndicator(color: KsColors.primary)),
          error: (e, _) => Center(
            child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Couldn’t load.\n$e',
                    style: const TextStyle(color: KsColors.danger))),
          ),
          data: (d) {
            final bookings =
                ((d['bookings'] as List?) ?? const []).cast<Map<String, dynamic>>();
            final b = bookings.where((x) => x['bookingId'] == widget.bookingId).firstOrNull;
            if (b == null) {
              return const Center(child: Text('Booking not found on this session.'));
            }
            final nonTeaching = d['nonTeaching'] ?? false;
            final competencies = ((d['courseCompetencies'] as List?) ?? const [])
                .cast<Map<String, dynamic>>();
            final progress = (b['competencies'] as Map?)?.cast<String, dynamic>() ?? const {};
            final notesFromServer = (b['notes'] ?? '').toString();
            // Sync notes the first time we see them (or after a remote
            // change — but only when the field doesn't currently have
            // focus, so we don't stomp on the instructor's typing).
            if (_initialNotes != notesFromServer && !_notesFocus.hasFocus) {
              _initialNotes = notesFromServer;
              _notesCtrl.text = notesFromServer;
            }
            final courseName = (d['courseName'] ?? '').toString();
            final courseCode = (d['courseCode'] ?? '').toString();
            final courseHex = (d['courseAccentColour'] ?? '').toString();
            final accent = courseColour(courseCode, courseHex);
            final competentCount = competencies
                .where((c) => progress[c['id']?.toString() ?? ''] == 'competent')
                .length;
            final flags = ((b['safetyFlags'] as List?) ?? const [])
                .cast<Map<String, dynamic>>();

            return ListView(
              padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
              children: [
                _Header(
                  studentName: (b['studentName'] ?? '').toString(),
                  courseName: courseName,
                  accent: accent,
                  done: competentCount,
                  total: competencies.length,
                ),
                const SizedBox(height: 16),
                if (nonTeaching)
                  _testDayBanner()
                else
                  _AttendanceRow(
                    status: (b['status'] ?? '').toString(),
                    saving: _markingAttendance,
                    onSelect: _setAttendance,
                  ),
                if (flags.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  _SafetyFlagsBanner(flags: flags),
                ],
                if (!nonTeaching && competencies.isNotEmpty) ...[
                  const SizedBox(height: 18),
                  _SectionLabel(_compsLabel(courseCode)),
                  const SizedBox(height: 8),
                  _CompetenciesCard(
                    competencies: competencies,
                    progress: progress,
                    saving: _savingCompetencies,
                    onChange: _setCompetency,
                  ),
                ] else if (!nonTeaching) ...[
                  const SizedBox(height: 18),
                  _SectionLabel('Competencies'),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: KsColors.surface,
                      borderRadius: BorderRadius.circular(KsRadius.lg),
                      border: Border.all(color: KsColors.border),
                    ),
                    child: const Text(
                        'No competencies configured for this course type yet.',
                        style: TextStyle(color: KsColors.ink2)),
                  ),
                ],
                const SizedBox(height: 18),
                _SectionLabel('Session notes'),
                const SizedBox(height: 8),
                _NotesField(
                  controller: _notesCtrl,
                  focusNode: _notesFocus,
                ),
                const SizedBox(height: 18),
                ElevatedButton.icon(
                  onPressed: () => context.pop(),
                  icon: const Icon(Icons.check, size: 18),
                  label: const Text('Done'),
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Attendance, competencies and notes save automatically.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: KsColors.ink4, fontSize: 11.5),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _testDayBanner() => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: KsColors.warningTint,
          borderRadius: BorderRadius.circular(KsRadius.md),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.flag_outlined, color: KsColors.warning, size: 18),
            const SizedBox(width: 9),
            Expanded(
              child: Text(
                'Test day — bike & escort are reserved for the DVA test. No competency assessment to capture.',
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: KsColors.ink2,
                    height: 1.45),
              ),
            ),
          ],
        ),
      );

  String _compsLabel(String courseCode) {
    final c = courseCode.toUpperCase();
    if (c.startsWith('CBT')) return 'CBT elements';
    if (c.contains('TEST')) return 'Test items';
    return 'Practical skills';
  }
}

class _Header extends StatelessWidget {
  final String studentName;
  final String courseName;
  final Color accent;
  final int done;
  final int total;
  const _Header({
    required this.studentName,
    required this.courseName,
    required this.accent,
    required this.done,
    required this.total,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        InkWell(
          onTap: () => Navigator.of(context).maybePop(),
          borderRadius: BorderRadius.circular(11),
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: KsColors.surface,
              border: Border.all(color: KsColors.border),
              borderRadius: BorderRadius.circular(11),
            ),
            child: const Icon(Icons.arrow_back, color: KsColors.ink2, size: 19),
          ),
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Assess · $courseName',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: KsColors.ink3)),
              const SizedBox(height: 1),
              Text(studentName,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: KsColors.ink,
                      letterSpacing: -0.4,
                      height: 1.05)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        if (total > 0)
          KsProgressRing(
            value: done,
            total: total,
            size: 48,
            strokeWidth: 5,
            colour: accent,
            child: Text('$done/$total',
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: KsColors.ink2)),
          )
        else
          KsAvatar(name: studentName, size: 48),
      ],
    );
  }
}

class _AttendanceRow extends StatelessWidget {
  final String status;
  final bool saving;
  final ValueChanged<String> onSelect;
  const _AttendanceRow({
    required this.status,
    required this.saving,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final present = status == 'completed';
    final noShow = status == 'no_show';
    return Row(children: [
      Expanded(
        child: _attBtn(
          label: 'Present',
          icon: Icons.check_rounded,
          tone: KsColors.success,
          active: present,
          onTap: saving ? null : () => onSelect('completed'),
        ),
      ),
      const SizedBox(width: 10),
      Expanded(
        child: _attBtn(
          label: 'No-show',
          icon: Icons.close_rounded,
          tone: KsColors.danger,
          active: noShow,
          onTap: saving ? null : () => onSelect('no_show'),
        ),
      ),
      if (saving) ...[
        const SizedBox(width: 10),
        const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2)),
      ],
    ]);
  }

  Widget _attBtn({
    required String label,
    required IconData icon,
    required Color tone,
    required bool active,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: active ? tone : KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.sm),
          border: active ? null : Border.all(color: KsColors.border2),
        ),
        alignment: Alignment.center,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 16, color: active ? Colors.white : KsColors.ink3),
          const SizedBox(width: 7),
          Text(label,
              style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                  color: active ? Colors.white : KsColors.ink3)),
        ]),
      ),
    );
  }
}

class _SafetyFlagsBanner extends StatelessWidget {
  final List<Map<String, dynamic>> flags;
  const _SafetyFlagsBanner({required this.flags});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: KsColors.warningTint,
        borderRadius: BorderRadius.circular(KsRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final f in flags)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.shield_outlined,
                      color: KsColors.warning, size: 14),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(f['body'] ?? '',
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: KsColors.ink)),
                  ),
                ],
              ),
            ),
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

class _CompetenciesCard extends StatelessWidget {
  final List<Map<String, dynamic>> competencies;
  final Map<String, dynamic> progress;
  final Set<String> saving;
  final void Function(String compId, String status) onChange;
  const _CompetenciesCard({
    required this.competencies,
    required this.progress,
    required this.saving,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
        boxShadow: KsShadows.sh1,
      ),
      child: Column(
        children: [
          for (var i = 0; i < competencies.length; i++) ...[
            if (i > 0)
              const Divider(height: 18, color: KsColors.border, thickness: 1),
            _CompetencyRow(
              id: (competencies[i]['id'] ?? '').toString(),
              label: (competencies[i]['label'] ?? '').toString(),
              status: (progress[(competencies[i]['id'] ?? '').toString()] ?? 'not_assessed').toString(),
              saving: saving.contains((competencies[i]['id'] ?? '').toString()),
              onChange: (s) => onChange((competencies[i]['id'] ?? '').toString(), s),
            ),
          ],
        ],
      ),
    );
  }
}

class _CompetencyRow extends StatelessWidget {
  final String id;
  final String label;
  final String status;
  final bool saving;
  final ValueChanged<String> onChange;
  const _CompetencyRow({
    required this.id,
    required this.label,
    required this.status,
    required this.saving,
    required this.onChange,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          // Tick square — green when "competent", outlined otherwise.
          // Echoes the design's binary glyph while the 4-status pills
          // below carry the real signal.
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: status == 'competent'
                  ? KsColors.success
                  : KsColors.surface3,
              borderRadius: BorderRadius.circular(6),
              border: status == 'competent'
                  ? null
                  : Border.all(color: KsColors.border2, width: 1.2),
            ),
            alignment: Alignment.center,
            child: status == 'competent'
                ? const Icon(Icons.check, color: Colors.white, size: 14)
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: KsColors.ink)),
          ),
          if (saving)
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
        ]),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            _statusPill('not_assessed', '—', KsColors.ink3, KsColors.surface3),
            _statusPill('developing', 'Developing', KsColors.primary, KsColors.primaryTint),
            _statusPill('competent', 'Competent', KsColors.success, KsColors.successTint),
            _statusPill('needs_work', 'Needs work', KsColors.warning, KsColors.warningTint),
          ],
        ),
      ],
    );
  }

  Widget _statusPill(String value, String pillLabel, Color fg, Color bg) {
    final selected = value == status;
    return InkWell(
      onTap: saving ? null : () => onChange(value),
      borderRadius: BorderRadius.circular(KsRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? bg : KsColors.surface2,
          borderRadius: BorderRadius.circular(KsRadius.pill),
          border: Border.all(
              color: selected ? fg.withValues(alpha: 0.5) : KsColors.border,
              width: selected ? 1.5 : 1),
        ),
        child: Text(pillLabel,
            style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w800,
                color: selected ? fg : KsColors.ink3,
                fontSize: 12)),
      ),
    );
  }
}

class _NotesField extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  const _NotesField({required this.controller, required this.focusNode});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: controller,
          focusNode: focusNode,
          minLines: 4,
          maxLines: 8,
          style: ksMono(size: 14, color: KsColors.ink),
          decoration: InputDecoration(
            hintText: 'How did they get on? What to work on next…',
            hintStyle: ksMono(size: 13.5, color: KsColors.ink4),
            filled: true,
            fillColor: KsColors.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(KsRadius.md),
              borderSide: const BorderSide(color: KsColors.border2),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(KsRadius.md),
              borderSide: const BorderSide(color: KsColors.border2),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(KsRadius.md),
              borderSide: const BorderSide(color: KsColors.primary, width: 1.5),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
            'Saves when you move focus away. Factual notes only — students can request access.',
            style: TextStyle(color: KsColors.ink4, fontSize: 11.5)),
      ],
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
