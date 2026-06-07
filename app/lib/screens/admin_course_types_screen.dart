// Admin Course types — list + create/edit/delete, competencies drawer.
//
// Region-aware (NI default; GB if your school region is GB). Each row shows
// duration, ratio, price, required bike category, prerequisites, test-day
// flag. Tap to edit; "Competencies" button opens a drawer with add/delete.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../state/school.dart';
import '../theme/tokens.dart';

class AdminCourseTypesScreen extends ConsumerWidget {
  const AdminCourseTypesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(courseTypesFullProvider);
    final settings = ref.watch(schoolSettingsProvider).valueOrNull;

    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async => ref.invalidate(courseTypesFullProvider),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(children: [
            Expanded(
              child: Text('Course types',
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 28, fontWeight: FontWeight.w800, color: KsColors.ink, letterSpacing: -0.6)),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: () => _showCourseTypeSheet(context, ref,
                  defaultRegion: settings?.region ?? 'NI'),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add course type'),
            ),
          ]),
          const SizedBox(height: 6),
          Text(
            settings?.region == 'GB'
                ? 'GB pathway: CBT → Mod 1 → Mod 2.'
                : 'NI pathway: CBT (variants by bike size) → theory → practical.',
            style: const TextStyle(color: KsColors.ink3, fontSize: 13),
          ),
          const SizedBox(height: 18),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator(color: KsColors.primary)),
            ),
            error: (e, _) => Text('Couldn’t load.\n$e'),
            data: (types) {
              if (types.isEmpty) {
                return Container(
                  padding: const EdgeInsets.all(40),
                  decoration: BoxDecoration(
                    color: KsColors.surface,
                    borderRadius: BorderRadius.circular(KsRadius.lg),
                    border: Border.all(color: KsColors.border),
                  ),
                  child: Column(children: [
                    const Icon(Icons.menu_book_outlined, size: 48, color: KsColors.ink4),
                    const SizedBox(height: 12),
                    Text('No course types yet',
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 16, fontWeight: FontWeight.w700, color: KsColors.ink)),
                    const SizedBox(height: 4),
                    const Text('Add at least one before scheduling.',
                        style: TextStyle(color: KsColors.ink2)),
                  ]),
                );
              }
              return LayoutBuilder(builder: (ctx, c) {
                final available = c.maxWidth.isFinite ? c.maxWidth : 900.0;
                final cols = available >= 1200 ? 3 : available >= 700 ? 2 : 1;
                final w = ((available - (cols - 1) * 14) / cols).clamp(200.0, 600.0);
                return Wrap(
                  spacing: 14, runSpacing: 14,
                  children: types
                      .map((ct) => SizedBox(width: w, child: _CourseTypeCard(courseType: ct)))
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

class _CourseTypeCard extends ConsumerStatefulWidget {
  final CourseTypeFull courseType;
  const _CourseTypeCard({required this.courseType});
  @override
  ConsumerState<_CourseTypeCard> createState() => _CourseTypeCardState();
}

class _CourseTypeCardState extends ConsumerState<_CourseTypeCard> {
  bool _deleting = false;

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete this course type?'),
        content: Text(
            '${widget.courseType.name} will be removed if no sessions, competencies or qualifications reference it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: KsColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _deleting = true);
    try {
      await ref.read(apiClientProvider).deleteCourseType(widget.courseType.id);
      ref.invalidate(courseTypesFullProvider);
      ref.invalidate(courseTypesProvider);
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.code == 'in_use'
                ? 'Can’t delete — still referenced by sessions, competencies, or qualifications.'
                : e.message),
            backgroundColor: KsColors.danger,
            behavior: SnackBarBehavior.floating));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Error: $e'),
            backgroundColor: KsColors.danger,
            behavior: SnackBarBehavior.floating));
      }
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.courseType;
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
              width: 36, height: 36,
              decoration: BoxDecoration(
                color: KsColors.primaryTint,
                borderRadius: BorderRadius.circular(KsRadius.sm),
              ),
              child: const Icon(Icons.menu_book_outlined, color: KsColors.primaryDeep, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.name,
                      style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w800, color: KsColors.ink, fontSize: 16)),
                  Text('${c.code} · ${c.region}',
                      style: const TextStyle(color: KsColors.ink3, fontSize: 12)),
                ],
              ),
            ),
            if (c.nonTeaching)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: KsColors.warningTint,
                  borderRadius: BorderRadius.circular(KsRadius.pill),
                ),
                child: const Text('Test day',
                    style: TextStyle(color: KsColors.warning, fontWeight: FontWeight.w700, fontSize: 10)),
              ),
          ]),
          const SizedBox(height: 14),
          _row('Duration', '${c.durationMinutes} min'),
          _row('Max ratio', '1:${c.maxRatio}'),
          _row('Price', _money(c.pricePence)),
          if (c.requiredBikeCategory.isNotEmpty) _row('Bike', c.requiredBikeCategory),
          if (c.cancellationCutoffHours > 0)
            _row('Cancel cutoff', '${c.cancellationCutoffHours}h'),
          if (c.prerequisites.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 6, children: c.prerequisites.map(_prereqChip).toList()),
          ],
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _showCompetenciesSheet(context, ref, c),
                icon: const Icon(Icons.checklist, size: 16),
                label: const Text('Competencies'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(36)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _showCourseTypeSheet(context, ref, existing: c),
                icon: const Icon(Icons.edit_outlined, size: 16),
                label: const Text('Edit'),
                style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(36)),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 44, height: 36,
              child: IconButton(
                onPressed: _deleting ? null : _delete,
                style: IconButton.styleFrom(
                  side: BorderSide(color: KsColors.danger.withValues(alpha: 0.4)),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(KsRadius.md)),
                ),
                icon: _deleting
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.delete_outline, color: KsColors.danger, size: 18),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _row(String k, String v) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          SizedBox(width: 92, child: Text(k, style: const TextStyle(color: KsColors.ink3, fontSize: 12))),
          Expanded(
              child: Text(v,
                  style: const TextStyle(color: KsColors.ink, fontSize: 13, fontWeight: FontWeight.w600))),
        ]),
      );

  Widget _prereqChip(String p) {
    String label;
    switch (p) {
      case 'cbt_held': label = 'CBT held'; break;
      case 'theory_passed': label = 'Theory passed'; break;
      default: label = p;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: KsColors.surface3,
        borderRadius: BorderRadius.circular(KsRadius.pill),
      ),
      child: Text(label,
          style: const TextStyle(color: KsColors.ink2, fontWeight: FontWeight.w700, fontSize: 10)),
    );
  }
}

String _money(int pence) {
  final pounds = pence ~/ 100;
  final cents = pence % 100;
  return '£${NumberFormat('#,##0').format(pounds)}.${cents.toString().padLeft(2, '0')}';
}

// ----- Add/Edit course-type sheet -----

Future<void> _showCourseTypeSheet(
  BuildContext context,
  WidgetRef ref, {
  CourseTypeFull? existing,
  String defaultRegion = 'NI',
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => _CourseTypeSheet(existing: existing, defaultRegion: defaultRegion),
  );
}

class _CourseTypeSheet extends ConsumerStatefulWidget {
  final CourseTypeFull? existing;
  final String defaultRegion;
  const _CourseTypeSheet({this.existing, required this.defaultRegion});
  @override
  ConsumerState<_CourseTypeSheet> createState() => _CourseTypeSheetState();
}

class _CourseTypeSheetState extends ConsumerState<_CourseTypeSheet> {
  late TextEditingController _code, _name, _duration, _ratio, _price, _cutoff;
  late String _region;
  String _bikeCat = '';
  bool _nonTeaching = false;
  String _accent = ''; // hex with leading '#', '' = unset
  final Set<String> _prereqs = {};
  bool _saving = false;
  String? _error;

  /// Curated palette — covers the design's blocks plus a few extras.
  /// Schools that want something else can extend this list, but in the
  /// MVP a fixed picker keeps the UI tight.
  static const _palette = <String>[
    '#6366F1', // indigo
    '#9333EA', // purple
    '#0EA5E9', // sky
    '#1F9D6B', // green
    '#C98A1E', // amber
    '#EC4899', // pink
    '#DC2626', // red
    '#374151', // slate
  ];

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _code = TextEditingController(text: e?.code ?? '');
    _name = TextEditingController(text: e?.name ?? '');
    _duration = TextEditingController(text: e == null ? '' : '${e.durationMinutes}');
    _ratio = TextEditingController(text: e == null ? '1' : '${e.maxRatio}');
    _price = TextEditingController(text: e == null ? '' : (e.pricePence / 100).toStringAsFixed(2));
    _cutoff = TextEditingController(text: e == null ? '' : '${e.cancellationCutoffHours}');
    _region = e?.region ?? widget.defaultRegion;
    _bikeCat = e?.requiredBikeCategory ?? '';
    _nonTeaching = e?.nonTeaching ?? false;
    _accent = e?.accentColour ?? '';
    if (e != null) _prereqs.addAll(e.prerequisites);
  }

  @override
  void dispose() {
    _code.dispose();
    _name.dispose();
    _duration.dispose();
    _ratio.dispose();
    _price.dispose();
    _cutoff.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_code.text.trim().isEmpty || _name.text.trim().isEmpty) {
      setState(() => _error = 'Code and name required.');
      return;
    }
    final dur = int.tryParse(_duration.text);
    final ratio = int.tryParse(_ratio.text);
    if (dur == null || dur <= 0 || ratio == null || ratio <= 0) {
      setState(() => _error = 'Duration and ratio must be positive.');
      return;
    }
    final priceD = double.tryParse(_price.text.isEmpty ? '0' : _price.text);
    if (priceD == null || priceD < 0) {
      setState(() => _error = 'Price must be a non-negative number.');
      return;
    }
    final cutoff = int.tryParse(_cutoff.text) ?? 0;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final api = ref.read(apiClientProvider);
      if (widget.existing == null) {
        await api.createCourseType(
          code: _code.text.trim(),
          name: _name.text.trim(),
          region: _region,
          requiredBikeCategory: _bikeCat,
          durationMinutes: dur,
          maxRatio: ratio,
          pricePence: (priceD * 100).round(),
          nonTeaching: _nonTeaching,
          cancellationCutoffHours: cutoff,
          accentColour: _accent,
          prerequisites: _prereqs.toList(),
        );
      } else {
        await api.updateCourseType(
          id: widget.existing!.id,
          code: _code.text.trim(),
          name: _name.text.trim(),
          region: _region,
          requiredBikeCategory: _bikeCat,
          durationMinutes: dur,
          maxRatio: ratio,
          pricePence: (priceD * 100).round(),
          nonTeaching: _nonTeaching,
          cancellationCutoffHours: cutoff,
          accentColour: _accent,
          prerequisites: _prereqs.toList(),
        );
      }
      ref.invalidate(courseTypesFullProvider);
      ref.invalidate(courseTypesProvider);
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
                Text(widget.existing == null ? 'Add course type' : 'Edit course type',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 18, fontWeight: FontWeight.w800, color: KsColors.ink)),
                const SizedBox(height: 16),
                Row(children: [
                  Expanded(child: TextField(
                      controller: _code,
                      textCapitalization: TextCapitalization.characters,
                      decoration: const InputDecoration(labelText: 'Code', hintText: 'e.g. CBT-125'))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(controller: _name, decoration: const InputDecoration(labelText: 'Name'))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Text('Region', style: GoogleFonts.plusJakartaSans(
                      color: KsColors.ink, fontWeight: FontWeight.w700, fontSize: 13)),
                  const SizedBox(width: 10),
                  _picker(label: 'NI', selected: _region == 'NI', onTap: () => setState(() => _region = 'NI')),
                  const SizedBox(width: 6),
                  _picker(label: 'GB', selected: _region == 'GB', onTap: () => setState(() => _region = 'GB')),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Text('Required bike category', style: GoogleFonts.plusJakartaSans(
                      color: KsColors.ink, fontWeight: FontWeight.w700, fontSize: 13)),
                ]),
                const SizedBox(height: 6),
                Wrap(spacing: 6, children: [
                  _picker(label: 'None', selected: _bikeCat.isEmpty, onTap: () => setState(() => _bikeCat = '')),
                  for (final cat in const ['A1', 'A2', 'A'])
                    _picker(label: cat, selected: _bikeCat == cat, onTap: () => setState(() => _bikeCat = cat)),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(
                      controller: _duration,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(labelText: 'Duration', suffixText: 'min'))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(
                      controller: _ratio,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(labelText: 'Max ratio', prefixText: '1:'))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Expanded(child: TextField(
                      controller: _price,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))],
                      decoration: const InputDecoration(labelText: 'Price', prefixText: '£ '))),
                  const SizedBox(width: 10),
                  Expanded(child: TextField(
                      controller: _cutoff,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      decoration: const InputDecoration(labelText: 'Cancel cutoff', suffixText: 'h'))),
                ]),
                const SizedBox(height: 12),
                Row(children: [
                  Switch(value: _nonTeaching, onChanged: (v) => setState(() => _nonTeaching = v)),
                  const SizedBox(width: 6),
                  const Expanded(child: Text(
                    'Test day (non-teaching) — skips competency capture; still reserves bike + charges.',
                    style: TextStyle(color: KsColors.ink2, fontSize: 13),
                  )),
                ]),
                const SizedBox(height: 12),
                Text('Accent colour',
                    style: GoogleFonts.plusJakartaSans(
                        color: KsColors.ink,
                        fontWeight: FontWeight.w700,
                        fontSize: 13)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    // "Auto" = no explicit accent → UI uses the
                    // code-derived fallback colour.
                    InkWell(
                      onTap: () => setState(() => _accent = ''),
                      borderRadius: BorderRadius.circular(KsRadius.pill),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: _accent.isEmpty
                              ? KsColors.primaryTint
                              : KsColors.surface2,
                          borderRadius:
                              BorderRadius.circular(KsRadius.pill),
                          border: Border.all(
                              color: _accent.isEmpty
                                  ? KsColors.primary.withValues(alpha: 0.5)
                                  : KsColors.border,
                              width: _accent.isEmpty ? 1.5 : 1),
                        ),
                        child: Text('Auto',
                            style: GoogleFonts.plusJakartaSans(
                                color: _accent.isEmpty
                                    ? KsColors.primaryDeep
                                    : KsColors.ink2,
                                fontWeight: FontWeight.w700,
                                fontSize: 12)),
                      ),
                    ),
                    for (final hex in _palette)
                      _Swatch(
                          hex: hex,
                          selected: _accent.toUpperCase() == hex,
                          onTap: () => setState(() => _accent = hex)),
                  ],
                ),
                const SizedBox(height: 14),
                Text('Prerequisites (advisory only)',
                    style: GoogleFonts.plusJakartaSans(color: KsColors.ink, fontWeight: FontWeight.w700, fontSize: 13)),
                const SizedBox(height: 6),
                Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final p in const [('cbt_held', 'CBT held'), ('theory_passed', 'Theory passed')])
                    _picker(
                      label: p.$2,
                      selected: _prereqs.contains(p.$1),
                      onTap: () => setState(() => _prereqs.contains(p.$1) ? _prereqs.remove(p.$1) : _prereqs.add(p.$1)),
                    ),
                ]),
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
                      : Text(widget.existing == null ? 'Add' : 'Save'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ----- Competencies sheet -----

final _competenciesProvider = FutureProvider.autoDispose
    .family<List<Competency>, String>((ref, ctId) async {
  return ref.read(apiClientProvider).listCompetencies(ctId);
});

Future<void> _showCompetenciesSheet(BuildContext context, WidgetRef ref, CourseTypeFull ct) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: KsColors.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
    ),
    builder: (_) => _CompetenciesSheet(courseType: ct),
  );
}

class _CompetenciesSheet extends ConsumerStatefulWidget {
  final CourseTypeFull courseType;
  const _CompetenciesSheet({required this.courseType});
  @override
  ConsumerState<_CompetenciesSheet> createState() => _CompetenciesSheetState();
}

class _CompetenciesSheetState extends ConsumerState<_CompetenciesSheet> {
  final _new = TextEditingController();
  bool _adding = false;

  @override
  void dispose() {
    _new.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    if (_new.text.trim().isEmpty) return;
    setState(() => _adding = true);
    try {
      final list = ref.read(_competenciesProvider(widget.courseType.id)).valueOrNull ?? const [];
      await ref.read(apiClientProvider).createCompetency(
            courseTypeId: widget.courseType.id,
            label: _new.text.trim(),
            sortOrder: list.length,
          );
      _new.clear();
      ref.invalidate(_competenciesProvider(widget.courseType.id));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Could not add: $e'),
            backgroundColor: KsColors.danger,
            behavior: SnackBarBehavior.floating));
      }
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  Future<void> _delete(Competency c) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Remove competency?'),
        content: Text('"${c.label}" will be removed if no assessments reference it.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove', style: TextStyle(color: KsColors.danger)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref.read(apiClientProvider).deleteCompetency(c.id);
      ref.invalidate(_competenciesProvider(widget.courseType.id));
    } on ApiException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(e.code == 'in_use'
                ? 'Can’t remove — already assessed against students.'
                : e.message),
            backgroundColor: KsColors.danger,
            behavior: SnackBarBehavior.floating));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(_competenciesProvider(widget.courseType.id));
    final insets = MediaQuery.of(context).viewInsets;
    return Padding(
      padding: EdgeInsets.only(bottom: insets.bottom),
      child: SafeArea(
        top: false,
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
              Text('Competencies · ${widget.courseType.name}',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 18, fontWeight: FontWeight.w800, color: KsColors.ink)),
              const SizedBox(height: 4),
              const Text(
                'Checklist items instructors sign off during sessions.',
                style: TextStyle(color: KsColors.ink3, fontSize: 12),
              ),
              const SizedBox(height: 14),
              async.when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(child: CircularProgressIndicator(color: KsColors.primary)),
                ),
                error: (e, _) => Text('Couldn’t load.\n$e'),
                data: (list) {
                  if (list.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Text('No competencies yet. Add the first one below.',
                          style: TextStyle(color: KsColors.ink3)),
                    );
                  }
                  return Column(
                    children: list.map((c) => Container(
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
                      decoration: BoxDecoration(
                        color: KsColors.surface2,
                        borderRadius: BorderRadius.circular(KsRadius.md),
                        border: Border.all(color: KsColors.border),
                      ),
                      child: Row(children: [
                        Expanded(
                          child: Text(c.label, style: const TextStyle(color: KsColors.ink, fontSize: 14, fontWeight: FontWeight.w600)),
                        ),
                        IconButton(
                          onPressed: () => _delete(c),
                          icon: const Icon(Icons.delete_outline, size: 18, color: KsColors.ink3),
                        ),
                      ]),
                    )).toList(),
                  );
                },
              ),
              const SizedBox(height: 14),
              Row(children: [
                Expanded(
                  child: TextField(
                    controller: _new,
                    decoration: const InputDecoration(
                      labelText: 'Add a competency',
                      hintText: 'e.g. U-turn',
                    ),
                    onSubmitted: (_) => _add(),
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _adding ? null : _add,
                    child: _adding
                        ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5))
                        : const Icon(Icons.add),
                  ),
                ),
              ]),
            ],
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

/// One colour swatch in the course-type accent picker. Renders a 28×28
/// rounded square; selected swatch gets an outer ring so the choice is
/// obvious without losing the colour underneath.
class _Swatch extends StatelessWidget {
  final String hex;
  final bool selected;
  final VoidCallback onTap;
  const _Swatch(
      {required this.hex, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = _parseHex(hex) ?? KsColors.primary;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.sm),
      child: Container(
        width: 28,
        height: 28,
        decoration: BoxDecoration(
          color: c,
          borderRadius: BorderRadius.circular(KsRadius.sm),
          border: Border.all(
            color: selected ? KsColors.ink : Colors.transparent,
            width: selected ? 2 : 0,
          ),
          boxShadow: selected
              ? [
                  BoxShadow(
                      color: c.withValues(alpha: 0.32),
                      blurRadius: 8,
                      spreadRadius: 1),
                ]
              : null,
        ),
        child: selected
            ? const Icon(Icons.check, color: Colors.white, size: 16)
            : null,
      ),
    );
  }
}

Color? _parseHex(String hex) {
  var s = hex.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length != 6) return null;
  final n = int.tryParse(s, radix: 16);
  if (n == null) return null;
  return Color(0xFF000000 | n);
}
