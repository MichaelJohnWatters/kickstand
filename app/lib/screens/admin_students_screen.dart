// Admin Students — searchable roster + click-through to detail (stub).

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/empty_state.dart';

final _studentsQueryProvider = StateProvider.autoDispose<String>((_) => '');
// 'active' is the default view — hides students who've passed their final
// practical (the school has archived them in effect). Toggle to 'passed'
// to see the alumni, or 'all' to see everyone. 'owes' / 'flags' compose by
// scoping to the active roster too (a passed student who still owes is
// pretty rare and the school's already chasing them via Instructor pay etc).
final _studentsFilterProvider = StateProvider.autoDispose<String>((_) => 'active');
// Search runs server-side (`?q=…`); filters run client-side so flipping is
// instant and doesn't refire the network.

class AdminStudentsScreen extends ConsumerWidget {
  const AdminStudentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(_studentsQueryProvider);
    final async = ref.watch(studentsProvider(q));
    final filter = ref.watch(_studentsFilterProvider);
    final filtered = async.maybeWhen(
      data: (list) => _applyFilter(list, filter),
      orElse: () => const <StudentRow>[],
    );
    // Totals reflect the *whole* roster, not the filtered view — that's
    // the headline number the manager wants to see at a glance.
    final riderCount = async.maybeWhen(
        data: (list) => list.length, orElse: () => null);
    final owingPence = async.maybeWhen(data: (list) {
      var total = 0;
      for (final s in list) {
        if (s.balancePence > 0) total += s.balancePence;
      }
      return total;
    }, orElse: () => null);

    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async => ref.invalidate(studentsProvider),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Students',
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            color: KsColors.ink,
                            letterSpacing: -0.6)),
                    const SizedBox(height: 4),
                    Text(_subtitleFor(riderCount, owingPence),
                        style:
                            const TextStyle(color: KsColors.ink3, fontSize: 13)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: () => _showAddStudentSheet(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New student'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          _SearchAndFilter(
            filter: filter,
            onSearch: (v) =>
                ref.read(_studentsQueryProvider.notifier).state = v,
            onFilter: (v) =>
                ref.read(_studentsFilterProvider.notifier).state = v,
          ),
          const SizedBox(height: 16),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                  child:
                      CircularProgressIndicator(color: KsColors.primary)),
            ),
            error: (e, _) => KsEmptyState.error(message: e.toString()),
            data: (_) {
              if (filtered.isEmpty) return _empty(filter);
              return Container(
                decoration: BoxDecoration(
                  color: KsColors.surface,
                  borderRadius: BorderRadius.circular(KsRadius.lg),
                  border: Border.all(color: KsColors.border),
                  boxShadow: KsShadows.sh1,
                ),
                child: Column(
                  children: [
                    _HeaderRow(),
                    ...filtered.asMap().entries.map((e) => _StudentRow(
                          student: e.value,
                          first: e.key == 0,
                          last: e.key == filtered.length - 1,
                        )),
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  List<StudentRow> _applyFilter(List<StudentRow> list, String filter) {
    switch (filter) {
      case 'active':
        return list.where((s) => !s.passed).toList();
      case 'passed':
        return list.where((s) => s.passed).toList();
      case 'owes':
        return list.where((s) => s.balancePence > 0 && !s.passed).toList();
      case 'flags':
        return list.where((s) => s.safetyFlagCount > 0 && !s.passed).toList();
      default: // 'all'
        return list;
    }
  }

  String _subtitleFor(int? riderCount, int? owingPence) {
    if (riderCount == null) return 'Loading roster…';
    final ridersStr = '$riderCount rider${riderCount == 1 ? '' : 's'}';
    if (owingPence == null || owingPence == 0) {
      return '$ridersStr on the books · everyone settled';
    }
    return '$ridersStr on the books · ${_money(owingPence)} outstanding across the school';
  }

  String _money(int pence) {
    final p = pence ~/ 100;
    final f = pence % 100;
    return f == 0 ? '£$p' : '£$p.${f.toString().padLeft(2, '0')}';
  }

  Widget _empty(String filter) => Container(
        padding: const EdgeInsets.all(40),
        decoration: BoxDecoration(
          color: KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.lg),
          border: Border.all(color: KsColors.border),
        ),
        child: Column(children: [
          const Icon(Icons.school_outlined, size: 48, color: KsColors.ink4),
          const SizedBox(height: 12),
          Text(
            switch (filter) {
              'active' => 'No active students',
              'passed' => 'No alumni yet — nobody has passed their final test',
              'owes' => 'No active students currently owe money',
              'flags' => 'No active safety flags',
              _ => 'No students found',
            },
            style: GoogleFonts.plusJakartaSans(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: KsColors.ink),
          ),
          const SizedBox(height: 4),
          const Text('Try clearing the filter or search.',
              style: TextStyle(color: KsColors.ink3)),
        ]),
      );
}

/// Search box + segmented filter, laid out side by side. Wraps when the
/// container is too narrow to fit them on one row.
class _SearchAndFilter extends StatelessWidget {
  final String filter;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onFilter;
  const _SearchAndFilter({
    required this.filter,
    required this.onSearch,
    required this.onFilter,
  });

  @override
  Widget build(BuildContext context) {
    final search = ConstrainedBox(
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 360),
      child: TextField(
        onChanged: onSearch,
        decoration: const InputDecoration(
          hintText: 'Search students',
          prefixIcon: Icon(Icons.search, color: KsColors.ink3),
          isDense: true,
        ),
      ),
    );
    final seg = _FilterSegmented(value: filter, onChanged: onFilter);
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [search, seg],
    );
  }
}

class _FilterSegmented extends StatelessWidget {
  final String value;
  final ValueChanged<String> onChanged;
  const _FilterSegmented({required this.value, required this.onChanged});

  static const _items = <(String, String)>[
    ('active', 'Active'),
    ('owes', 'Owes money'),
    ('flags', 'Has flags'),
    ('passed', 'Passed'),
    ('all', 'All'),
  ];

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
        children: [
          for (final (v, label) in _items)
            InkWell(
              onTap: () => onChanged(v),
              borderRadius: BorderRadius.circular(KsRadius.pill),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: value == v ? KsColors.surface : Colors.transparent,
                  borderRadius: BorderRadius.circular(KsRadius.pill),
                  boxShadow: value == v ? KsShadows.sh1 : null,
                ),
                child: Text(label,
                    style: GoogleFonts.plusJakartaSans(
                        color: value == v ? KsColors.ink : KsColors.ink3,
                        fontWeight: FontWeight.w700,
                        fontSize: 13)),
              ),
            ),
        ],
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: KsColors.surface2,
        border: Border(bottom: BorderSide(color: KsColors.border)),
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(KsRadius.lg),
          topRight: Radius.circular(KsRadius.lg),
        ),
      ),
      child: Row(children: const [
        Expanded(flex: 4, child: _ColHead('Student')),
        Expanded(flex: 2, child: _ColHead('Stage')),
        Expanded(flex: 1, child: _ColHead('Lessons')),
        Expanded(flex: 2, child: _ColHead('Balance')),
        Expanded(flex: 1, child: _ColHead('Flags')),
        SizedBox(width: 28),
      ]),
    );
  }
}

class _ColHead extends StatelessWidget {
  final String label;
  const _ColHead(this.label);
  @override
  Widget build(BuildContext context) => Text(label,
      style: const TextStyle(
          color: KsColors.ink3, fontSize: 11, fontWeight: FontWeight.w700, letterSpacing: 0.4));
}

class _StudentRow extends StatelessWidget {
  final StudentRow student;
  final bool first;
  final bool last;
  const _StudentRow({required this.student, required this.first, required this.last});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.go('/admin/students/${student.id}'),
      borderRadius: BorderRadius.only(
        bottomLeft: last ? const Radius.circular(KsRadius.lg) : Radius.zero,
        bottomRight: last ? const Radius.circular(KsRadius.lg) : Radius.zero,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          border: Border(
            bottom: last ? BorderSide.none : const BorderSide(color: KsColors.border),
          ),
        ),
        child: Row(children: [
          Expanded(
            flex: 4,
            child: Row(children: [
              _StudentAvatar(name: student.name, seed: student.id),
              const SizedBox(width: 11),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(student.name,
                        style: GoogleFonts.plusJakartaSans(
                            fontWeight: FontWeight.w700,
                            color: KsColors.ink,
                            fontSize: 14),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1),
                    const SizedBox(height: 2),
                    Text(_subtitle(student),
                        style: const TextStyle(
                            color: KsColors.ink4, fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1),
                  ],
                ),
              ),
            ]),
          ),
          Expanded(flex: 2, child: _StageChip(stage: student.stage)),
          Expanded(
            flex: 1,
            child: Text('${student.completedBookings}',
                style: const TextStyle(
                    color: KsColors.ink2,
                    fontSize: 13,
                    fontWeight: FontWeight.w600)),
          ),
          Expanded(
            flex: 2,
            child: _BalanceCell(student.balancePence),
          ),
          Expanded(
            flex: 1,
            child: _FlagsCell(count: student.safetyFlagCount),
          ),
          const Icon(Icons.chevron_right, color: KsColors.ink3, size: 20),
        ]),
      ),
    );
  }
}

/// Initials avatar with a stable per-student hue derived from user id —
/// matches the Sign-ups page so a given student looks the same across
/// admin screens.
class _StudentAvatar extends StatelessWidget {
  final String name;
  final String seed;
  const _StudentAvatar({required this.name, required this.seed});

  @override
  Widget build(BuildContext context) {
    final hue = _hueFromSeed(seed);
    final bg = HSLColor.fromAHSL(1, hue, 0.42, 0.90).toColor();
    final fg = HSLColor.fromAHSL(1, hue, 0.55, 0.30).toColor();
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      alignment: Alignment.center,
      child: Text(_initialsOf(name),
          style: GoogleFonts.plusJakartaSans(
              color: fg, fontWeight: FontWeight.w800, fontSize: 12)),
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

String _subtitle(StudentRow s) {
  final bits = <String>[];
  if (s.licenceCategoryPursued.isNotEmpty) {
    bits.add('Cat ${s.licenceCategoryPursued}');
  }
  if (s.transmissionPreference.isNotEmpty) {
    bits.add(s.transmissionPreference);
  }
  return bits.isEmpty ? s.email : bits.join(' · ');
}

/// Neutral chip showing the server-computed training stage.
class _StageChip extends StatelessWidget {
  final String stage;
  const _StageChip({required this.stage});
  @override
  Widget build(BuildContext context) {
    if (stage.isEmpty) {
      return const Text('—',
          style: TextStyle(color: KsColors.ink4, fontSize: 13));
    }
    final (fg, bg) = switch (stage) {
      'Awaiting approval' => (KsColors.warning, KsColors.warningTint),
      'Disabled' => (KsColors.danger, KsColors.dangerTint),
      'Passed' => (KsColors.success, KsColors.successTint),
      _ => (KsColors.ink2, KsColors.surface3),
    };
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
            color: bg, borderRadius: BorderRadius.circular(KsRadius.pill)),
        child: Text(stage,
            style: GoogleFonts.plusJakartaSans(
                color: fg,
                fontWeight: FontWeight.w700,
                fontSize: 11.5)),
      ),
    );
  }
}

/// Warning-tint badge when the student has 1+ active safety flags; dash
/// otherwise.
class _FlagsCell extends StatelessWidget {
  final int count;
  const _FlagsCell({required this.count});
  @override
  Widget build(BuildContext context) {
    if (count == 0) {
      return const Text('—',
          style: TextStyle(color: KsColors.ink4, fontSize: 13));
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: KsColors.warningTint,
            borderRadius: BorderRadius.circular(KsRadius.pill)),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.shield_outlined,
                color: KsColors.warning, size: 12),
            const SizedBox(width: 4),
            Text('$count',
                style: GoogleFonts.plusJakartaSans(
                    color: KsColors.warning,
                    fontWeight: FontWeight.w800,
                    fontSize: 11.5)),
          ],
        ),
      ),
    );
  }
}

class _BalanceCell extends StatelessWidget {
  final int balancePence;
  const _BalanceCell(this.balancePence);
  @override
  Widget build(BuildContext context) {
    if (balancePence == 0) {
      return const Text('—',
          style: TextStyle(color: KsColors.ink3, fontSize: 13));
    }
    final amount = (balancePence.abs() / 100).toStringAsFixed(2);
    final colour = balancePence > 0 ? KsColors.danger : KsColors.success;
    return Text(
      balancePence > 0 ? 'Owes £$amount' : 'Credit £$amount',
      style: TextStyle(color: colour, fontSize: 13, fontWeight: FontWeight.w700),
    );
  }
}

// ===== Add-student sheet =====

Future<void> _showAddStudentSheet(BuildContext context, WidgetRef ref) async {
  final created = await showModalBottomSheet<StudentRow>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => const _AddStudentSheet(),
  );
  if (created != null) {
    ref.invalidate(studentsProvider);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Added ${created.name}.'),
        behavior: SnackBarBehavior.floating,
      ));
    }
  }
}

class _AddStudentSheet extends ConsumerStatefulWidget {
  const _AddStudentSheet();
  @override
  ConsumerState<_AddStudentSheet> createState() => _AddStudentSheetState();
}

class _AddStudentSheetState extends ConsumerState<_AddStudentSheet> {
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
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
    if (_name.text.trim().isEmpty ||
        _email.text.trim().isEmpty ||
        _password.text.length < 6) {
      setState(() =>
          _error = 'Name, email and a password ≥ 6 chars are required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final created = await ref.read(apiClientProvider).createStudent(
            name: _name.text.trim(),
            email: _email.text.trim(),
            phone: _phone.text.trim(),
            password: _password.text,
          );
      if (mounted) Navigator.pop(context, created);
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _saving = false;
      });
    } catch (_) {
      setState(() {
        _error = 'Could not add student.';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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
                    height: 4,
                    width: 36,
                    margin: const EdgeInsets.only(bottom: 14),
                    decoration: BoxDecoration(
                      color: KsColors.border2,
                      borderRadius: BorderRadius.circular(KsRadius.pill),
                    ),
                  ),
                ),
                Text('New student',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: KsColors.ink)),
                const SizedBox(height: 4),
                const Text(
                  'Creates the account directly — skips the sign-up queue. '
                  'They can change the password after first login.',
                  style: TextStyle(color: KsColors.ink3, fontSize: 12),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _email,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(labelText: 'Email'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _phone,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(
                      labelText: 'Phone (optional)'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _password,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Initial password',
                    hintText: '≥ 6 characters',
                  ),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: KsColors.dangerTint,
                      borderRadius: BorderRadius.circular(KsRadius.md),
                    ),
                    child: Text(_error!,
                        style: const TextStyle(color: KsColors.danger)),
                  ),
                ],
                const SizedBox(height: 18),
                ElevatedButton(
                  onPressed: _saving ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(KsRadius.md),
                    ),
                  ),
                  child: _saving
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2.5))
                      : const Text('Add student'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
