// Instructor assess screen — per-booking competency capture + notes.
//
// Loads session detail, finds the booking, renders:
//   - Student header (name, phone, safety flags)
//   - Attendance row (Present / No-show)
//   - Competency rows (4 status options each)
//   - Free-text notes editor (saves on blur)
//
// Each control commits immediately so partial work isn't lost.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../state/providers.dart';
import '../theme/tokens.dart';
import 'instructor_session_detail_screen.dart';

class InstructorAssessScreen extends ConsumerStatefulWidget {
  final String sessionId;
  final String bookingId;
  const InstructorAssessScreen({required this.sessionId, required this.bookingId, super.key});

  @override
  ConsumerState<InstructorAssessScreen> createState() => _InstructorAssessScreenState();
}

class _InstructorAssessScreenState extends ConsumerState<InstructorAssessScreen> {
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
      await api.assessCompetency(bookingId: widget.bookingId, competencyId: compId, status: status);
      ref.invalidate(sessionDetailProvider(widget.sessionId));
    } catch (e) {
      _showToast('Could not save', error: true);
    } finally {
      if (mounted) {
        setState(() => _savingCompetencies = {..._savingCompetencies}..remove(compId));
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
      appBar: AppBar(
        title: Text('Assess',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 22)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: KsColors.ink),
          onPressed: () => context.pop(),
        ),
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator(color: KsColors.primary)),
        error: (e, _) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Couldn’t load.\n$e'))),
        data: (d) {
          final bookings = ((d['bookings'] as List?) ?? const []).cast<Map<String, dynamic>>();
          final b = bookings.where((x) => x['bookingId'] == widget.bookingId).firstOrNull;
          if (b == null) {
            return const Center(child: Text('Booking not found on this session.'));
          }
          final nonTeaching = d['nonTeaching'] ?? false;
          final competencies = ((d['courseCompetencies'] as List?) ?? const []).cast<Map<String, dynamic>>();
          final progress = (b['competencies'] as Map?)?.cast<String, dynamic>() ?? const {};
          final notesFromServer = (b['notes'] ?? '').toString();
          // Sync notes the first time we see them.
          if (_initialNotes != notesFromServer && !_notesFocus.hasFocus) {
            _initialNotes = notesFromServer;
            _notesCtrl.text = notesFromServer;
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _StudentHeader(b),
              const SizedBox(height: 16),
              _AttendanceCard(
                status: b['status'] ?? '',
                saving: _markingAttendance,
                onSelect: _setAttendance,
              ),
              const SizedBox(height: 16),
              if (nonTeaching)
                _TestDayBanner()
              else
                _CompetenciesCard(
                  competencies: competencies,
                  progress: progress.cast<String, dynamic>(),
                  saving: _savingCompetencies,
                  onChange: _setCompetency,
                ),
              const SizedBox(height: 16),
              _NotesCard(
                controller: _notesCtrl,
                focusNode: _notesFocus,
                onSave: _saveNotes,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _StudentHeader extends StatelessWidget {
  final Map<String, dynamic> b;
  const _StudentHeader(this.b);
  @override
  Widget build(BuildContext context) {
    final flags = ((b['safetyFlags'] as List?) ?? const []).cast<Map<String, dynamic>>();
    final phone = (b['studentPhone'] ?? '').toString();
    final bike = (b['bikeNickname'] ?? '').toString();
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
          Row(children: [
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(
                color: KsColors.primaryTint,
                borderRadius: BorderRadius.circular(KsRadius.pill),
              ),
              child: const Icon(Icons.person, color: KsColors.primaryDeep, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(b['studentName'] ?? '',
                      style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w800, color: KsColors.ink, fontSize: 17)),
                  if (phone.isNotEmpty)
                    Text(phone, style: const TextStyle(color: KsColors.ink3, fontSize: 12)),
                ],
              ),
            ),
          ]),
          if (bike.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(children: [
              const Icon(Icons.two_wheeler, size: 16, color: KsColors.ink3),
              const SizedBox(width: 6),
              Text(bike, style: const TextStyle(color: KsColors.ink2, fontSize: 13)),
            ]),
          ],
          if (flags.isNotEmpty) ...[
            const SizedBox(height: 12),
            ...flags.map((f) => Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: KsColors.warningTint,
                      borderRadius: BorderRadius.circular(KsRadius.md),
                      border: Border.all(color: KsColors.warning.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.warning_amber_rounded, color: KsColors.warning, size: 18),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(f['body'] ?? '',
                              style: const TextStyle(color: KsColors.warning, fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                )),
          ],
        ],
      ),
    );
  }
}

class _AttendanceCard extends StatelessWidget {
  final String status;
  final bool saving;
  final ValueChanged<String> onSelect;
  const _AttendanceCard({required this.status, required this.saving, required this.onSelect});

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
          Row(children: [
            Text('Attendance',
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800, color: KsColors.ink, fontSize: 16)),
            const Spacer(),
            if (saving)
              const SizedBox(
                width: 14, height: 14,
                child: CircularProgressIndicator(color: KsColors.ink3, strokeWidth: 2),
              ),
          ]),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: _AttButton(
                label: 'Present',
                icon: Icons.check_rounded,
                fg: KsColors.success,
                bg: KsColors.successTint,
                selected: status == 'completed',
                onTap: saving ? null : () => onSelect('completed'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _AttButton(
                label: 'No-show',
                icon: Icons.close_rounded,
                fg: KsColors.danger,
                bg: KsColors.dangerTint,
                selected: status == 'no_show',
                onTap: saving ? null : () => onSelect('no_show'),
              ),
            ),
          ]),
          if (status == 'booked' || status == 'needs_reassignment') ...[
            const SizedBox(height: 8),
            Text('Not marked yet.',
                style: TextStyle(color: KsColors.ink3, fontSize: 12, fontStyle: FontStyle.italic)),
          ],
        ],
      ),
    );
  }
}

class _AttButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color fg, bg;
  final bool selected;
  final VoidCallback? onTap;
  const _AttButton({
    required this.label, required this.icon, required this.fg, required this.bg,
    required this.selected, required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.md),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: selected ? bg : KsColors.surface2,
          borderRadius: BorderRadius.circular(KsRadius.md),
          border: Border.all(color: selected ? fg.withValues(alpha: 0.5) : KsColors.border, width: selected ? 1.5 : 1),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: selected ? fg : KsColors.ink3),
            const SizedBox(width: 8),
            Text(label,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: selected ? fg : KsColors.ink2,
                  fontSize: 14,
                )),
          ],
        ),
      ),
    );
  }
}

class _TestDayBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: KsColors.warningTint,
        borderRadius: BorderRadius.circular(KsRadius.md),
        border: Border.all(color: KsColors.warning.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.task_alt, color: KsColors.warning, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Test day — no assessment.',
              style: GoogleFonts.plusJakartaSans(
                  color: KsColors.warning, fontWeight: FontWeight.w700, fontSize: 14),
            ),
          ),
        ],
      ),
    );
  }
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
    if (competencies.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.lg),
          border: Border.all(color: KsColors.border),
        ),
        child: const Text('No competencies configured for this course type.',
            style: TextStyle(color: KsColors.ink2)),
      );
    }
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
          Text('Competencies',
              style: GoogleFonts.plusJakartaSans(
                  fontWeight: FontWeight.w800, color: KsColors.ink, fontSize: 16)),
          const SizedBox(height: 12),
          ...competencies.asMap().entries.map((entry) {
            final c = entry.value;
            final id = c['id']?.toString() ?? '';
            final label = c['label']?.toString() ?? '';
            final status = progress[id]?.toString() ?? 'not_assessed';
            return Padding(
              padding: EdgeInsets.only(top: entry.key == 0 ? 0 : 12),
              child: _CompetencyRow(
                id: id, label: label, status: status,
                saving: saving.contains(id),
                onChange: (s) => onChange(id, s),
              ),
            );
          }),
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
          Expanded(
            child: Text(label,
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w600, color: KsColors.ink, fontSize: 14)),
          ),
          if (saving)
            const SizedBox(
              width: 12, height: 12,
              child: CircularProgressIndicator(color: KsColors.ink3, strokeWidth: 2),
            ),
        ]),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          children: [
            _statusButton('not_assessed', '—', KsColors.ink3, KsColors.surface3),
            _statusButton('developing', 'Developing', KsColors.primary, KsColors.primaryTint),
            _statusButton('competent', 'Competent', KsColors.success, KsColors.successTint),
            _statusButton('needs_work', 'Needs work', KsColors.warning, KsColors.warningTint),
          ],
        ),
      ],
    );
  }

  Widget _statusButton(String value, String label, Color fg, Color bg) {
    final selected = value == status;
    return InkWell(
      onTap: saving ? null : () => onChange(value),
      borderRadius: BorderRadius.circular(KsRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? bg : KsColors.surface2,
          borderRadius: BorderRadius.circular(KsRadius.pill),
          border: Border.all(color: selected ? fg.withValues(alpha: 0.5) : KsColors.border),
        ),
        child: Text(label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: selected ? fg : KsColors.ink3,
              fontSize: 12,
            )),
      ),
    );
  }
}

class _NotesCard extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final VoidCallback onSave;
  const _NotesCard({
    required this.controller,
    required this.focusNode,
    required this.onSave,
  });

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
          Row(children: [
            Text('Notes',
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800, color: KsColors.ink, fontSize: 16)),
            const Spacer(),
            TextButton(
              onPressed: onSave,
              child: const Text('Save'),
            ),
          ]),
          const SizedBox(height: 6),
          TextField(
            controller: controller,
            focusNode: focusNode,
            maxLines: 4,
            decoration: const InputDecoration(
              hintText: 'How was the session? What to work on next?',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Saves when you tap Save or move focus away. Factual notes only — students can request access.',
            style: TextStyle(color: KsColors.ink3, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
