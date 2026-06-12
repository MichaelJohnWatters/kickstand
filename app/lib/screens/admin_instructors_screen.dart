// Admin Instructors — staff cards with home location + per-course
// accreditations (with expiry dates) + actions. Invite modal collects
// name/email/phone/password/home plus a starter list of accreditations.
// Per-row "Edit accreditations" opens a sheet with one date picker per
// course the instructor holds.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../state/school.dart';
import '../theme/tokens.dart';
import '../widgets/empty_state.dart';

class AdminInstructorsScreen extends ConsumerWidget {
  const AdminInstructorsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(instructorsProvider);
    final settings = ref.watch(schoolSettingsProvider).valueOrNull;

    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async => ref.invalidate(instructorsProvider),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(children: [
            Expanded(
              child: Text('Instructors',
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 28, fontWeight: FontWeight.w800, color: KsColors.ink, letterSpacing: -0.6)),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: () => _showInviteSheet(context, ref),
              icon: const Icon(Icons.person_add, size: 18),
              label: const Text('Invite instructor'),
            ),
          ]),
          const SizedBox(height: 16),
          if (settings != null) _SchoolTogglesCard(settings: settings),
          const SizedBox(height: 18),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator(color: KsColors.primary)),
            ),
            error: (e, _) => KsEmptyState.error(message: e.toString()),
            data: (instructors) {
              if (instructors.isEmpty) {
                return Container(
                  padding: const EdgeInsets.all(40),
                  decoration: BoxDecoration(
                    color: KsColors.surface,
                    borderRadius: BorderRadius.circular(KsRadius.lg),
                    border: Border.all(color: KsColors.border),
                  ),
                  child: Column(children: [
                    const Icon(Icons.group_outlined, size: 48, color: KsColors.ink4),
                    const SizedBox(height: 12),
                    Text('No instructors yet',
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 16, fontWeight: FontWeight.w700, color: KsColors.ink)),
                    const SizedBox(height: 4),
                    const Text('Invite your first instructor to get started.',
                        style: TextStyle(color: KsColors.ink2)),
                  ]),
                );
              }
              return LayoutBuilder(builder: (ctx, c) {
                // Defensive: a parent passing infinite width would make
                // SizedBox(width: infinity) below trip "infinite width"
                // assertions. Fall back to a sensible card width.
                final available = c.maxWidth.isFinite ? c.maxWidth : 900.0;
                final cols = available >= 1100 ? 3 : available >= 700 ? 2 : 1;
                final w = ((available - (cols - 1) * 14) / cols).clamp(200.0, 600.0);
                return Wrap(
                  spacing: 14, runSpacing: 14,
                  children: instructors
                      .map((i) => SizedBox(width: w, child: _InstructorCard(instructor: i)))
                      .toList(),
                );
              });
            },
          ),
        ],
      ),
    );
  }
}

class _SchoolTogglesCard extends ConsumerStatefulWidget {
  final SchoolSettings settings;
  const _SchoolTogglesCard({required this.settings});
  @override
  ConsumerState<_SchoolTogglesCard> createState() => _SchoolTogglesCardState();
}

class _SchoolTogglesCardState extends ConsumerState<_SchoolTogglesCard> {
  bool? _override;
  bool _saving = false;

  Future<void> _toggle(bool v) async {
    setState(() {
      _override = v;
      _saving = true;
    });
    try {
      await ref.read(apiClientProvider).updateSchoolSettings(instructorsCanRecordPayments: v);
      ref.invalidate(schoolSettingsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not update: $e'),
            backgroundColor: KsColors.danger,
            behavior: SnackBarBehavior.floating));
        setState(() => _override = !v);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final on = _override ?? widget.settings.instructorsCanRecordPayments;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
        boxShadow: KsShadows.sh1,
      ),
      child: Row(children: [
        const Icon(Icons.payments_outlined, color: KsColors.primaryDeep, size: 22),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Instructors can record payments',
                  style: GoogleFonts.plusJakartaSans(
                      fontWeight: FontWeight.w800, color: KsColors.ink, fontSize: 14)),
              const SizedBox(height: 2),
              const Text(
                'If on, instructors see "Record payment" on session detail for students who owe.',
                style: TextStyle(color: KsColors.ink3, fontSize: 12),
              ),
            ],
          ),
        ),
        if (_saving)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          ),
        Switch(value: on, onChanged: _saving ? null : _toggle),
      ]),
    );
  }
}

class _InstructorCard extends ConsumerWidget {
  final InstructorRow instructor;
  const _InstructorCard({required this.instructor});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
              width: 40, height: 40,
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
                  Text(instructor.name,
                      style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w800, color: KsColors.ink, fontSize: 16)),
                  Text(instructor.email,
                      style: const TextStyle(color: KsColors.ink3, fontSize: 12),
                      overflow: TextOverflow.ellipsis),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 12),
          if (instructor.phone.isNotEmpty)
            _row(Icons.phone, instructor.phone),
          if (instructor.homeLocationName.isNotEmpty)
            _row(Icons.home_outlined, 'Home: ${instructor.homeLocationName}'),
          const SizedBox(height: 10),
          Text(
            'Accreditations · ${instructor.accreditations.length}',
            style: const TextStyle(
                color: KsColors.ink3, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4),
          ),
          const SizedBox(height: 6),
          _AccreditationsRow(accreditations: instructor.accreditations),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _showEditAccreditationsSheet(context, ref, instructor),
            icon: const Icon(Icons.edit_outlined, size: 16),
            label: const Text('Edit accreditations'),
            style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(34)),
          ),
        ],
      ),
    );
  }

  Widget _row(IconData icon, String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Icon(icon, color: KsColors.ink3, size: 14),
          const SizedBox(width: 6),
          Expanded(
            child: Text(text,
                style: const TextStyle(color: KsColors.ink2, fontSize: 12),
                overflow: TextOverflow.ellipsis),
          ),
        ]),
      );
}

class _AccreditationsRow extends ConsumerWidget {
  final List<Accreditation> accreditations;
  const _AccreditationsRow({required this.accreditations});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (accreditations.isEmpty) {
      return const Text('Not accredited for any course yet.',
          style: TextStyle(color: KsColors.ink3, fontSize: 12, fontStyle: FontStyle.italic));
    }
    final types = ref.watch(courseTypesProvider).valueOrNull ?? const [];
    final byId = {for (final c in types) c.id: c};
    return Wrap(
      spacing: 6, runSpacing: 6,
      children: accreditations.map((a) {
        final c = byId[a.courseTypeId];
        final dateLabel = a.expiresOn.isEmpty ? 'no date' : a.expiresOn;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: KsColors.primaryTint,
            borderRadius: BorderRadius.circular(KsRadius.pill),
          ),
          child: Text('${c?.code ?? a.courseTypeId} · $dateLabel',
              style: const TextStyle(color: KsColors.primaryDeep, fontWeight: FontWeight.w700, fontSize: 11)),
        );
      }).toList(),
    );
  }
}

// ---------------- Invite sheet ----------------

Future<void> _showInviteSheet(BuildContext context, WidgetRef ref) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => const _InviteInstructorSheet(),
  );
}

class _InviteInstructorSheet extends ConsumerStatefulWidget {
  const _InviteInstructorSheet();
  @override
  ConsumerState<_InviteInstructorSheet> createState() => _InviteInstructorSheetState();
}

class _InviteInstructorSheetState extends ConsumerState<_InviteInstructorSheet> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  String? _homeLocationId;
  // Selected courses → optional YYYY-MM-DD expiry. Missing key = not
  // selected. Empty string value = selected but no date on file yet.
  final Map<String, String> _accreditations = {};
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _phone.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_name.text.trim().isEmpty || _email.text.trim().isEmpty || _password.text.length < 8) {
      setState(() => _error = 'Name, email and a password ≥ 8 chars are required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).inviteInstructor(
            name: _name.text.trim(),
            email: _email.text.trim(),
            phone: _phone.text.trim(),
            password: _password.text,
            homeLocationId: _homeLocationId ?? '',
            accreditations: _accreditations.entries
                .map((e) => Accreditation(courseTypeId: e.key, expiresOn: e.value))
                .toList(),
          );
      ref.invalidate(instructorsProvider);
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not invite.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final locs = ref.watch(locationsProvider).valueOrNull ?? const [];
    final courses = ref.watch(courseTypesProvider).valueOrNull ?? const [];
    final insets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    height: 4, width: 36,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: KsColors.border2,
                      borderRadius: BorderRadius.circular(KsRadius.pill),
                    ),
                  ),
                ),
                Text('Invite instructor',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 19, fontWeight: FontWeight.w800, color: KsColors.ink)),
                const SizedBox(height: 16),
                TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name')),
                const SizedBox(height: 10),
                TextField(controller: _email, keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(labelText: 'Email')),
                const SizedBox(height: 10),
                TextField(controller: _phone, keyboardType: TextInputType.phone,
                    decoration: const InputDecoration(labelText: 'Phone (optional)')),
                const SizedBox(height: 10),
                TextField(controller: _password, obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Initial password',
                      hintText: 'They can change after first login (≥ 8 chars)',
                    )),
                if (locs.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text('Home location',
                      style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w700, color: KsColors.ink, fontSize: 13)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    _picker(label: 'None', selected: _homeLocationId == null,
                        onTap: () => setState(() => _homeLocationId = null)),
                    ...locs.map((l) => _picker(
                          label: l.name,
                          selected: _homeLocationId == l.id,
                          onTap: () => setState(() => _homeLocationId = l.id),
                        )),
                  ]),
                ],
                if (courses.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Text('Accredited for',
                      style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w700, color: KsColors.ink, fontSize: 13)),
                  const SizedBox(height: 6),
                  Wrap(spacing: 6, runSpacing: 6, children: courses.map((c) {
                    final on = _accreditations.containsKey(c.id);
                    return _picker(
                      label: c.code,
                      selected: on,
                      onTap: () => setState(() {
                        if (on) {
                          _accreditations.remove(c.id);
                        } else {
                          _accreditations[c.id] = '';
                        }
                      }),
                    );
                  }).toList()),
                  if (_accreditations.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    const Text(
                      'Set expiry dates after invite from "Edit accreditations".',
                      style: TextStyle(color: KsColors.ink3, fontSize: 11.5),
                    ),
                  ],
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: KsColors.dangerTint,
                      borderRadius: BorderRadius.circular(KsRadius.md),
                    ),
                    child: Text(_error!, style: const TextStyle(color: KsColors.danger)),
                  ),
                ],
                const SizedBox(height: 18),
                ElevatedButton(
                  onPressed: _saving ? null : _submit,
                  child: _saving
                      ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                      : const Text('Invite'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _picker({required String label, required bool selected, required VoidCallback onTap}) {
  return InkWell(
    onTap: onTap,
    borderRadius: BorderRadius.circular(KsRadius.pill),
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: selected ? KsColors.primaryTint : KsColors.surface2,
        borderRadius: BorderRadius.circular(KsRadius.pill),
        border: Border.all(
          color: selected ? KsColors.primary.withValues(alpha: 0.5) : KsColors.border,
          width: selected ? 1.5 : 1,
        ),
      ),
      child: Text(label,
          style: TextStyle(
            color: selected ? KsColors.primaryDeep : KsColors.ink2,
            fontWeight: FontWeight.w700, fontSize: 12,
          )),
    ),
  );
}

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

// ---------------- Edit accreditations ----------------

Future<void> _showEditAccreditationsSheet(BuildContext context, WidgetRef ref, InstructorRow instructor) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => _EditAccreditationsSheet(instructor: instructor),
  );
}

class _EditAccreditationsSheet extends ConsumerStatefulWidget {
  final InstructorRow instructor;
  const _EditAccreditationsSheet({required this.instructor});
  @override
  ConsumerState<_EditAccreditationsSheet> createState() => _EditAccreditationsSheetState();
}

class _EditAccreditationsSheetState extends ConsumerState<_EditAccreditationsSheet> {
  // courseTypeId → "YYYY-MM-DD" or "" (selected but no date on file).
  // Missing key = not accredited.
  late Map<String, String> _accreditations;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _accreditations = {
      for (final a in widget.instructor.accreditations) a.courseTypeId: a.expiresOn,
    };
  }

  Future<void> _pickExpiry(String courseTypeId) async {
    final existing = _accreditations[courseTypeId] ?? '';
    final initial = DateTime.tryParse(existing) ??
        DateTime.now().add(const Duration(days: 365));
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(initial.year - 5),
      lastDate: DateTime(initial.year + 10),
    );
    if (picked == null) return;
    setState(() {
      _accreditations[courseTypeId] = _isoDate(picked);
    });
  }

  Future<void> _submit() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).setInstructorAccreditations(
            instructorId: widget.instructor.userId,
            accreditations: _accreditations.entries
                .map((e) => Accreditation(courseTypeId: e.key, expiresOn: e.value))
                .toList(),
          );
      ref.invalidate(instructorsProvider);
      if (mounted) Navigator.pop(context);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not save.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final courses = ref.watch(courseTypesProvider).valueOrNull ?? const [];
    final insets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Container(
                    height: 4, width: 36,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: KsColors.border2,
                      borderRadius: BorderRadius.circular(KsRadius.pill),
                    ),
                  ),
                ),
                Text('Accreditations · ${widget.instructor.name}',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 18, fontWeight: FontWeight.w800, color: KsColors.ink)),
                const SizedBox(height: 16),
                if (courses.isEmpty)
                  const Text('No course types configured yet.',
                      style: TextStyle(color: KsColors.ink2))
                else
                  Column(children: courses.map((c) {
                    final on = _accreditations.containsKey(c.id);
                    final expiry = _accreditations[c.id] ?? '';
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(children: [
                        Expanded(
                          child: _picker(
                            label: '${c.code} · ${c.name}',
                            selected: on,
                            onTap: () => setState(() {
                              if (on) {
                                _accreditations.remove(c.id);
                              } else {
                                _accreditations[c.id] = '';
                              }
                            }),
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 150,
                          child: TextButton.icon(
                            onPressed: on ? () => _pickExpiry(c.id) : null,
                            icon: const Icon(Icons.event_outlined, size: 16),
                            label: Text(expiry.isEmpty ? 'Set expiry' : expiry,
                                style: const TextStyle(fontSize: 12)),
                            style: TextButton.styleFrom(
                              foregroundColor: on ? KsColors.primaryDeep : KsColors.ink4,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                          ),
                        ),
                        if (on && expiry.isNotEmpty)
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            tooltip: 'Clear date',
                            icon: const Icon(Icons.close, size: 16),
                            color: KsColors.ink4,
                            onPressed: () => setState(() => _accreditations[c.id] = ''),
                          ),
                      ]),
                    );
                  }).toList()),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: KsColors.dangerTint,
                    borderRadius: BorderRadius.circular(KsRadius.md),
                  ),
                  child: Text(_error!, style: const TextStyle(color: KsColors.danger)),
                ),
              ],
              const SizedBox(height: 18),
              ElevatedButton(
                onPressed: _saving ? null : _submit,
                child: _saving
                    ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                    : const Text('Save'),
              ),
            ],
            ),
          ),
        ),
      ),
    );
  }
}
