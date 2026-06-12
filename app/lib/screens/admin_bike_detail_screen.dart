// Admin Bike Detail — drilled into from the fleet table row.
//
// Two sections:
//   1. Header — bike info (nickname, make/model, reg, location, MOT/tax
//      pills, mileage).
//   2. Maintenance log — every quid spent on the bike, newest first,
//      with the inline thumb + a "+" to record a new line. Empty state
//      explains the feature.
//
// Recording opens a sheet with category, amount, occurred-at, optional
// vendor + notes, and a required receipt photo (camera/gallery via
// image_picker). Submits as multipart; refreshes the list on save.

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../state/school.dart';
import '../theme/tokens.dart';
import '../util/bike_warnings.dart';
import '../util/gov_links.dart';
import '../widgets/receipt_thumb_cell.dart';
import '../widgets/empty_state.dart';

// Provider for one bike's maintenance log. Keyed by bike id so each
// detail page caches independently and invalidates only its own.
final bikeExpensesProvider = FutureProvider.autoDispose
    .family<BikeExpensesPayload, String>((ref, bikeId) async {
  return ref.read(apiClientProvider).listBikeExpenses(bikeId);
});

const _categoryMeta = <String, ({String label, IconData icon, int tone})>{
  'parts':   (label: 'Parts',   icon: Icons.settings_outlined,            tone: 215),
  'labour':  (label: 'Labour',  icon: Icons.handyman_outlined,            tone: 277),
  'mot':     (label: 'MOT',     icon: Icons.verified_outlined,            tone: 25),
  'tax':     (label: 'Tax',     icon: Icons.receipt_long_outlined,        tone: 70),
  'service': (label: 'Service', icon: Icons.build_circle_outlined,        tone: 145),
  'other':   (label: 'Other',   icon: Icons.more_horiz,                   tone: 200),
};

class AdminBikeDetailScreen extends ConsumerWidget {
  final String bikeId;
  const AdminBikeDetailScreen({required this.bikeId, super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fleetAsync = ref.watch(fleetProvider);
    final expAsync = ref.watch(bikeExpensesProvider(bikeId));
    final settings = ref.watch(schoolSettingsProvider).valueOrNull;

    return Scaffold(
      backgroundColor: KsColors.bg,
      appBar: AppBar(
        backgroundColor: KsColors.surface,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          // We arrive via context.go(...) which replaces the route
          // rather than pushing onto Navigator's stack, so a plain
          // Navigator.maybePop() finds nothing. Send back to the
          // fleet route explicitly.
          onPressed: () => context.go('/admin/fleet'),
        ),
        title: const Text('Bike detail'),
      ),
      body: fleetAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Could not load: $e')),
        data: (bikes) {
          final bike = bikes.firstWhere(
            (b) => b.id == bikeId,
            orElse: () => bikes.isEmpty ? _emptyBike() : bikes.first,
          );
          if (bike.id != bikeId) {
            return const Center(child: Text('Bike not found.'));
          }
          return RefreshIndicator(
            color: KsColors.primary,
            onRefresh: () async {
              ref.invalidate(bikeExpensesProvider(bikeId));
              ref.invalidate(fleetProvider);
            },
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                _BikeHeader(bike: bike, settings: settings),
                const SizedBox(height: 24),

                Row(children: [
                  Text('Maintenance log',
                      style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w800,
                          fontSize: 18,
                          color: KsColors.ink)),
                  const Spacer(),
                  expAsync.maybeWhen(
                    data: (p) => _YtdPill(pence: p.ytdPence),
                    orElse: () => const SizedBox.shrink(),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () => _record(context, ref, bikeId),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Record'),
                  ),
                ]),
                const SizedBox(height: 12),
                expAsync.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                  error: (e, _) => KsEmptyState.error(title: 'Couldn’t load expenses', message: e.toString()),
                  data: (payload) {
                    if (payload.expenses.isEmpty) {
                      return _EmptyLog(onAdd: () => _record(context, ref, bikeId));
                    }
                    return Column(
                      children: [
                        for (final e in payload.expenses)
                          _ExpenseRow(expense: e, bikeId: bikeId),
                      ],
                    );
                  },
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _record(BuildContext context, WidgetRef ref, String bikeId) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.gallery, imageQuality: 90);
    if (picked == null) return;
    if (!context.mounted) return;
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: KsColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
      ),
      builder: (_) => _RecordSheet(bikeId: bikeId, receiptPath: picked.path),
    );
    if (ok == true) {
      ref.invalidate(bikeExpensesProvider(bikeId));
    }
  }
}

FleetBike _emptyBike() => FleetBike(
      id: '',
      nickname: '',
      make: '',
      model: '',
      registration: '',
      category: '',
      transmission: '',
      engineCc: 0,
      status: '',
      homeLocationId: '',
      homeLocationName: '',
      currentLocationId: '',
      currentLocationName: '',
      isCrossSite: false,
      motExpiresOn: '',
      taxExpiresOn: '',
      currentMileageMiles: 0,
    );

// ----- Header -----

class _BikeHeader extends StatelessWidget {
  final FleetBike bike;
  final SchoolSettings? settings;
  const _BikeHeader({required this.bike, required this.settings});
  @override
  Widget build(BuildContext context) {
    final motWarn = settings?.motWarnDays ?? 90;
    final motUrgent = settings?.motUrgentDays ?? 14;
    final taxWarn = settings?.taxWarnDays ?? 30;
    final taxUrgent = settings?.taxUrgentDays ?? 7;
    final mot = bucketExpiry(bike.motExpiresOn,
        warnDays: motWarn, urgentDays: motUrgent);
    final tax = bucketExpiry(bike.taxExpiresOn,
        warnDays: taxWarn, urgentDays: taxUrgent);
    final title = bike.nickname.isEmpty
        ? '${bike.make} ${bike.model}'.trim()
        : bike.nickname;
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title.isEmpty ? '—' : title,
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 22, fontWeight: FontWeight.w800, color: KsColors.ink)),
          if (bike.registration.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: InkWell(
                onTap: () => openVehicleEnquiry(context, bike.registration),
                borderRadius: BorderRadius.circular(KsRadius.sm),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Text(bike.registration,
                      style: const TextStyle(
                          color: KsColors.primary,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          decoration: TextDecoration.underline)),
                  const SizedBox(width: 4),
                  const Icon(Icons.open_in_new, size: 14, color: KsColors.primary),
                ]),
              ),
            ),
          const SizedBox(height: 10),
          Wrap(spacing: 6, runSpacing: 6, children: [
            _Pill(
                label:
                    'MOT · ${mot == BikeWarning.unknown ? "Unknown" : warningLabel(mot, expires: bike.motExpiresOn)}',
                warning: mot),
            _Pill(
                label:
                    'Tax · ${tax == BikeWarning.unknown ? "Unknown" : warningLabel(tax, expires: bike.taxExpiresOn)}',
                warning: tax),
            if (bike.currentMileageMiles > 0)
              _Pill(label: '${_thousands(bike.currentMileageMiles)} mi', warning: BikeWarning.ok),
            _Pill(
                label: bike.currentLocationName.isEmpty ? 'No location' : bike.currentLocationName,
                warning: BikeWarning.ok),
          ]),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final String label;
  final BikeWarning warning;
  const _Pill({required this.label, required this.warning});
  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (warning) {
      BikeWarning.unknown => (KsColors.surface3, KsColors.ink3),
      BikeWarning.ok => (KsColors.successTint, KsColors.success),
      BikeWarning.dueSoon => (KsColors.warningTint, KsColors.warning),
      BikeWarning.dueUrgent => (KsColors.dangerTint, KsColors.danger),
      BikeWarning.expired => (KsColors.dangerTint, KsColors.danger),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(KsRadius.pill),
      ),
      child: Text(label,
          style: TextStyle(color: fg, fontWeight: FontWeight.w700, fontSize: 12)),
    );
  }
}

class _YtdPill extends StatelessWidget {
  final int pence;
  const _YtdPill({required this.pence});
  @override
  Widget build(BuildContext context) {
    final pounds = (pence / 100).toStringAsFixed(2);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: KsColors.primaryTint,
        borderRadius: BorderRadius.circular(KsRadius.pill),
      ),
      child: Text('£$pounds YTD',
          style: const TextStyle(
              color: KsColors.primaryDeep,
              fontWeight: FontWeight.w800,
              fontSize: 12)),
    );
  }
}

// ----- Expense rows -----

class _ExpenseRow extends ConsumerWidget {
  final BikeExpense expense;
  final String bikeId;
  const _ExpenseRow({required this.expense, required this.bikeId});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final meta = _categoryMeta[expense.category] ?? _categoryMeta['other']!;
    final df = DateFormat('d MMM yyyy');
    final date = DateTime.tryParse(expense.occurredAt);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
      ),
      child: Row(children: [
        ReceiptThumbCell(
          thumbBytes: expense.receiptThumbBytes,
          fallback: _CategoryGlyph(meta: meta),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Text('£${(expense.amountPence / 100).toStringAsFixed(2)}',
                    style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w800,
                        fontSize: 15,
                        color: KsColors.ink)),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: HSLColor.fromAHSL(1, meta.tone.toDouble(), 0.55, 0.93).toColor(),
                    borderRadius: BorderRadius.circular(KsRadius.pill),
                  ),
                  child: Text(meta.label,
                      style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          color: HSLColor.fromAHSL(1, meta.tone.toDouble(), 0.55, 0.35).toColor())),
                ),
              ]),
              const SizedBox(height: 2),
              Text(
                [
                  if (expense.vendor.isNotEmpty) expense.vendor,
                  date != null ? df.format(date) : expense.occurredAt,
                ].join(' · '),
                style: const TextStyle(color: KsColors.ink3, fontSize: 12.5),
              ),
              if (expense.notes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(expense.notes,
                      style: const TextStyle(color: KsColors.ink2, fontSize: 12.5)),
                ),
            ],
          ),
        ),
        IconButton(
          tooltip: 'View receipt',
          onPressed: () => _showReceipt(context, ref, expense),
          icon: const Icon(Icons.open_in_full, size: 18, color: KsColors.ink3),
        ),
        IconButton(
          tooltip: 'Delete',
          onPressed: () => _confirmDelete(context, ref, expense),
          icon: const Icon(Icons.delete_outline, size: 18, color: KsColors.danger),
        ),
      ]),
    );
  }

  Future<void> _showReceipt(BuildContext context, WidgetRef ref, BikeExpense e) async {
    final api = ref.read(apiClientProvider);
    await showDialog<void>(
      context: context,
      builder: (_) => Dialog(
        backgroundColor: KsColors.surface,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: CachedNetworkImage(
            imageUrl: api.bikeExpenseReceiptUrl(e.id),
            httpHeaders: {
              if (api.currentToken() != null && api.currentToken()!.isNotEmpty)
                'Authorization': 'Bearer ${api.currentToken()}',
            },
            placeholder: (_, __) => e.receiptThumbBytes.isNotEmpty
                ? Image.memory(e.receiptThumbBytes,
                    width: 320, height: 320, fit: BoxFit.cover)
                : const SizedBox(width: 320, height: 320),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref, BikeExpense e) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Delete this maintenance entry?'),
        content: const Text(
          'The receipt image will be deleted too. The bike record is unaffected.',
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('Cancel')),
          ElevatedButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              style: ElevatedButton.styleFrom(backgroundColor: KsColors.danger),
              child: const Text('Delete')),
        ],
      ),
    );
    if (yes != true) return;
    try {
      await ref.read(apiClientProvider).deleteBikeExpense(e.id);
      ref.invalidate(bikeExpensesProvider(bikeId));
    } catch (err) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $err')),
        );
      }
    }
  }
}

class _CategoryGlyph extends StatelessWidget {
  final ({String label, IconData icon, int tone}) meta;
  const _CategoryGlyph({required this.meta});
  @override
  Widget build(BuildContext context) {
    final tone = meta.tone.toDouble();
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: HSLColor.fromAHSL(1, tone, 0.55, 0.92).toColor(),
        borderRadius: BorderRadius.circular(KsRadius.sm),
      ),
      alignment: Alignment.center,
      child: Icon(meta.icon,
          color: HSLColor.fromAHSL(1, tone, 0.55, 0.35).toColor(), size: 22),
    );
  }
}

class _EmptyLog extends StatelessWidget {
  final VoidCallback onAdd;
  const _EmptyLog({required this.onAdd});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
      ),
      child: Column(
        children: [
          const Icon(Icons.build_circle_outlined, size: 48, color: KsColors.ink4),
          const SizedBox(height: 10),
          const Text('No maintenance yet',
              style: TextStyle(
                  color: KsColors.ink, fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 4),
          const Text(
            'Record petrol, parts, labour, MOT and tax with a receipt photo so spend stays auditable.',
            textAlign: TextAlign.center,
            style: TextStyle(color: KsColors.ink3, fontSize: 13),
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Record the first one'),
          ),
        ],
      ),
    );
  }
}

// ----- Record sheet -----

class _RecordSheet extends ConsumerStatefulWidget {
  final String bikeId;
  final String receiptPath;
  const _RecordSheet({required this.bikeId, required this.receiptPath});
  @override
  ConsumerState<_RecordSheet> createState() => _RecordSheetState();
}

class _RecordSheetState extends ConsumerState<_RecordSheet> {
  String _category = 'service';
  final _amount = TextEditingController();
  final _vendor = TextEditingController();
  final _notes = TextEditingController();
  DateTime _occurredAt = DateTime.now();
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _vendor.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final pounds = double.tryParse(_amount.text.trim());
    if (pounds == null || pounds <= 0) {
      setState(() => _error = 'Enter an amount.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).recordBikeExpense(
            bikeId: widget.bikeId,
            category: _category,
            amountPence: (pounds * 100).round(),
            receiptPath: widget.receiptPath,
            vendor: _vendor.text.trim(),
            notes: _notes.text.trim(),
            occurredAt: _occurredAt,
          );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'Could not save.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 18, 20, 20 + bottomInset),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Record maintenance',
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800, fontSize: 18, color: KsColors.ink)),
            const SizedBox(height: 12),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final e in _categoryMeta.entries)
                  ChoiceChip(
                    label: Text(e.value.label),
                    selected: _category == e.key,
                    onSelected: (_) => setState(() => _category = e.key),
                  ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: const InputDecoration(
                labelText: 'Amount (£)',
                hintText: 'e.g. 124.50',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _vendor,
              decoration: const InputDecoration(
                labelText: 'Vendor (optional)',
                hintText: 'e.g. Belfast Honda Service',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _notes,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _saving
                  ? null
                  : () async {
                      final picked = await showDatePicker(
                        context: context,
                        initialDate: _occurredAt,
                        firstDate: DateTime(DateTime.now().year - 3),
                        lastDate: DateTime.now(),
                      );
                      if (picked != null) {
                        setState(() => _occurredAt = picked);
                      }
                    },
              icon: const Icon(Icons.calendar_today_outlined, size: 16),
              label: Text(DateFormat('d MMM yyyy').format(_occurredAt)),
              style: OutlinedButton.styleFrom(
                alignment: Alignment.centerLeft,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: KsColors.dangerTint,
                  borderRadius: BorderRadius.circular(KsRadius.md),
                ),
                child: Text(_error!,
                    style: const TextStyle(color: KsColors.danger, fontSize: 13)),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
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
                    : const Text('Save'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String _thousands(int n) {
  final s = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}
