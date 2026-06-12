// Admin Settings — single home for school-wide configuration.
//
// Sections (top to bottom):
//   1. School profile          — name, region, test body label
//   2. Onboarding              — open vs approval signup mode
//   3. Booking policy          — cancel cutoff, cross-site notice,
//                                travel buffer, instructor-records-payments
//   4. Fleet warnings          — MOT/tax due-soon and urgent windows
//
// All four sections share one bottom "Save changes" button. The form
// tracks dirty state per field; on save we PATCH /school with only the
// changed fields and invalidate the schoolSettingsProvider so the
// sidebar header and other screens see the new values immediately.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../state/school.dart';
import '../theme/tokens.dart';

class AdminSettingsScreen extends ConsumerStatefulWidget {
  const AdminSettingsScreen({super.key});
  @override
  ConsumerState<AdminSettingsScreen> createState() => _AdminSettingsScreenState();
}

class _AdminSettingsScreenState extends ConsumerState<AdminSettingsScreen> {
  // Controllers for free-text fields. Numeric fields use TextEditingController
  // too; we parseInt at save time.
  final _name = TextEditingController();
  final _testBody = TextEditingController();
  final _cancelCutoff = TextEditingController();
  final _travelBuffer = TextEditingController();
  final _crossSiteNotice = TextEditingController();
  final _motWarn = TextEditingController();
  final _motUrgent = TextEditingController();
  final _taxWarn = TextEditingController();
  final _taxUrgent = TextEditingController();
  final _accWarn = TextEditingController();
  final _accUrgent = TextEditingController();
  final _insWarn = TextEditingController();
  final _insUrgent = TextEditingController();

  String _onboardingMode = 'open';
  bool _instructorsCanRecordPayments = false;

  // Snapshot of the values we loaded so the save call only ships
  // changed fields.
  SchoolSettings? _loaded;
  bool _saving = false;
  bool _hydrated = false;

  @override
  void dispose() {
    _name.dispose();
    _testBody.dispose();
    _cancelCutoff.dispose();
    _travelBuffer.dispose();
    _crossSiteNotice.dispose();
    _motWarn.dispose();
    _motUrgent.dispose();
    _taxWarn.dispose();
    _taxUrgent.dispose();
    _accWarn.dispose();
    _accUrgent.dispose();
    _insWarn.dispose();
    _insUrgent.dispose();
    super.dispose();
  }

  void _hydrate(SchoolSettings s) {
    if (_hydrated) return;
    _hydrated = true;
    _loaded = s;
    _name.text = s.name;
    _testBody.text = s.testBodyLabel;
    _cancelCutoff.text = s.cancelCutoffHours.toString();
    _travelBuffer.text = s.travelBufferMinutes.toString();
    _crossSiteNotice.text = s.crossSiteNoticeHours.toString();
    _motWarn.text = s.motWarnDays.toString();
    _motUrgent.text = s.motUrgentDays.toString();
    _taxWarn.text = s.taxWarnDays.toString();
    _taxUrgent.text = s.taxUrgentDays.toString();
    _accWarn.text = s.accreditationWarnDays.toString();
    _accUrgent.text = s.accreditationUrgentDays.toString();
    _insWarn.text = s.insuranceWarnDays.toString();
    _insUrgent.text = s.insuranceUrgentDays.toString();
    _onboardingMode = s.onboardingMode;
    _instructorsCanRecordPayments = s.instructorsCanRecordPayments;
  }

  Future<void> _save() async {
    final orig = _loaded;
    if (orig == null) return;
    setState(() => _saving = true);
    try {
      final api = ref.read(apiClientProvider);
      await api.updateSchoolSettings(
        name: _name.text.trim() == orig.name ? null : _name.text.trim(),
        testBodyLabel: _testBody.text.trim() == orig.testBodyLabel ? null : _testBody.text.trim(),
        onboardingMode: _onboardingMode == orig.onboardingMode ? null : _onboardingMode,
        instructorsCanRecordPayments:
            _instructorsCanRecordPayments == orig.instructorsCanRecordPayments
                ? null
                : _instructorsCanRecordPayments,
        cancelCutoffHours: _diffInt(_cancelCutoff.text, orig.cancelCutoffHours),
        travelBufferMinutes: _diffInt(_travelBuffer.text, orig.travelBufferMinutes),
        crossSiteNoticeHours: _diffInt(_crossSiteNotice.text, orig.crossSiteNoticeHours),
        motWarnDays: _diffInt(_motWarn.text, orig.motWarnDays),
        motUrgentDays: _diffInt(_motUrgent.text, orig.motUrgentDays),
        taxWarnDays: _diffInt(_taxWarn.text, orig.taxWarnDays),
        taxUrgentDays: _diffInt(_taxUrgent.text, orig.taxUrgentDays),
        accreditationWarnDays:
            _diffInt(_accWarn.text, orig.accreditationWarnDays),
        accreditationUrgentDays:
            _diffInt(_accUrgent.text, orig.accreditationUrgentDays),
        insuranceWarnDays:
            _diffInt(_insWarn.text, orig.insuranceWarnDays),
        insuranceUrgentDays:
            _diffInt(_insUrgent.text, orig.insuranceUrgentDays),
      );
      ref.invalidate(schoolSettingsProvider);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Settings saved.'), backgroundColor: KsColors.success),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message), backgroundColor: KsColors.danger),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not save settings.'), backgroundColor: KsColors.danger),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // Returns the parsed int when it differs from `current`; otherwise
  // null so the API client skips that field.
  int? _diffInt(String raw, int current) {
    final v = int.tryParse(raw.trim());
    if (v == null || v == current) return null;
    return v;
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(schoolSettingsProvider);
    return settingsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('Could not load settings: $e')),
      data: (s) {
        _hydrate(s);
        return ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text('Settings',
                style: GoogleFonts.plusJakartaSans(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: KsColors.ink,
                )),
            const SizedBox(height: 4),
            const Text(
              'Tune school-wide behaviour. Changes apply immediately to every screen.',
              style: TextStyle(color: KsColors.ink3, fontSize: 13.5),
            ),
            const SizedBox(height: 24),

            _Section(
              title: 'School profile',
              children: [
                _TextField(
                  label: 'School name',
                  controller: _name,
                  textCapitalization: TextCapitalization.words,
                ),
                _TextField(
                  label: 'Test body label',
                  controller: _testBody,
                  hint: 'DVA, DVSA, …',
                  textCapitalization: TextCapitalization.characters,
                ),
              ],
            ),

            _Section(
              title: 'Onboarding',
              children: [
                _SegmentedRow<String>(
                  label: 'Student signup mode',
                  helper: 'Approval mode means new signups land pending until a manager confirms.',
                  segments: const [
                    ('open', 'Open'),
                    ('approval', 'Approval required'),
                  ],
                  selected: _onboardingMode,
                  onChange: (v) => setState(() => _onboardingMode = v),
                ),
              ],
            ),

            _Section(
              title: 'Booking policy',
              children: [
                _NumberField(
                  label: 'Cancellation cutoff (hours)',
                  controller: _cancelCutoff,
                  helper: 'How close to the lesson students can still cancel.',
                ),
                _NumberField(
                  label: 'Travel buffer between sessions (minutes)',
                  controller: _travelBuffer,
                ),
                _NumberField(
                  label: 'Cross-site notice (hours)',
                  controller: _crossSiteNotice,
                  helper: "Notice required when an instructor's next session is at a different location.",
                ),
                _SwitchRow(
                  label: 'Instructors can record cash payments',
                  helper: 'When off, only admins/owners can record student payments.',
                  value: _instructorsCanRecordPayments,
                  onChange: (v) => setState(() => _instructorsCanRecordPayments = v),
                ),
              ],
            ),

            _Section(
              title: 'Fleet warnings',
              children: [
                const Text(
                  'How early to flag MOT and tax expiries on the bike cards.',
                  style: TextStyle(color: KsColors.ink3, fontSize: 12.5),
                ),
                const SizedBox(height: 12),
                _NumberField(
                  label: 'MOT — warn from (days)',
                  controller: _motWarn,
                  helper: 'Amber pill from this many days out.',
                ),
                _NumberField(
                  label: 'MOT — urgent from (days)',
                  controller: _motUrgent,
                  helper: 'Red pill from this many days out.',
                ),
                _NumberField(
                  label: 'Tax — warn from (days)',
                  controller: _taxWarn,
                ),
                _NumberField(
                  label: 'Tax — urgent from (days)',
                  controller: _taxUrgent,
                ),
              ],
            ),

            _Section(
              title: 'Compliance warnings',
              children: [
                const Text(
                  'How early to flag instructor accreditation and school insurance on the Compliance page.',
                  style: TextStyle(color: KsColors.ink3, fontSize: 12.5),
                ),
                const SizedBox(height: 12),
                _NumberField(
                  label: 'Accreditation — warn from (days)',
                  controller: _accWarn,
                ),
                _NumberField(
                  label: 'Accreditation — urgent from (days)',
                  controller: _accUrgent,
                ),
                _NumberField(
                  label: 'Insurance — warn from (days)',
                  controller: _insWarn,
                ),
                _NumberField(
                  label: 'Insurance — urgent from (days)',
                  controller: _insUrgent,
                ),
              ],
            ),

            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(KsRadius.md),
                  ),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : const Text('Save changes'),
              ),
            ),
            const SizedBox(height: 24),
          ],
        );
      },
    );
  }
}

// ----- Section + field building blocks -----

class _Section extends StatelessWidget {
  final String title;
  final List<Widget> children;
  const _Section({required this.title, required this.children});
  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w800,
                fontSize: 16,
                color: KsColors.ink,
              )),
          const SizedBox(height: 12),
          ...children,
        ],
      ),
    );
  }
}

class _TextField extends StatelessWidget {
  final String label;
  final String? hint;
  final TextEditingController controller;
  final TextCapitalization textCapitalization;
  const _TextField({
    required this.label,
    required this.controller,
    this.hint,
    this.textCapitalization = TextCapitalization.none,
  });
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        textCapitalization: textCapitalization,
        decoration: InputDecoration(labelText: label, hintText: hint),
      ),
    );
  }
}

class _NumberField extends StatelessWidget {
  final String label;
  final String? helper;
  final TextEditingController controller;
  const _NumberField({required this.label, required this.controller, this.helper});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextField(
        controller: controller,
        keyboardType: const TextInputType.numberWithOptions(decimal: false),
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(labelText: label, helperText: helper),
      ),
    );
  }
}

class _SegmentedRow<T> extends StatelessWidget {
  final String label;
  final String? helper;
  final List<(T, String)> segments;
  final T selected;
  final ValueChanged<T> onChange;
  const _SegmentedRow({
    required this.label,
    required this.segments,
    required this.selected,
    required this.onChange,
    this.helper,
  });
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                color: KsColors.ink2, fontWeight: FontWeight.w700, fontSize: 13)),
          if (helper != null) ...[
            const SizedBox(height: 4),
            Text(helper!, style: const TextStyle(color: KsColors.ink3, fontSize: 12)),
          ],
          const SizedBox(height: 8),
          SegmentedButton<T>(
            segments: [
              for (final (value, label) in segments)
                ButtonSegment<T>(value: value, label: Text(label)),
            ],
            selected: {selected},
            onSelectionChanged: (s) => onChange(s.first),
          ),
        ],
      ),
    );
  }
}

class _SwitchRow extends StatelessWidget {
  final String label;
  final String? helper;
  final bool value;
  final ValueChanged<bool> onChange;
  const _SwitchRow({
    required this.label,
    required this.value,
    required this.onChange,
    this.helper,
  });
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: const TextStyle(
                        color: KsColors.ink, fontWeight: FontWeight.w700, fontSize: 14)),
                if (helper != null) ...[
                  const SizedBox(height: 2),
                  Text(helper!,
                      style: const TextStyle(color: KsColors.ink3, fontSize: 12)),
                ],
              ],
            ),
          ),
          Switch(value: value, onChanged: onChange),
        ],
      ),
    );
  }
}
