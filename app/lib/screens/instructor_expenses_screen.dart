// Instructor Expenses — submit / track reimbursable spend (petrol, lunch,
// parking, tolls, other). Approval-first: pending → approved → reimbursed
// (or → rejected). A receipt is required at submission — instructors can
// snap one with the camera, pick from the photo library, or upload an
// existing file (PDF / scan etc.) from inside the form.
//
// The receipt is held as in-memory bytes (not a file path) so the same
// code path works on web (where `Image.file` and `MultipartFile.fromFile`
// both blow up — picked files on web are blob URLs, not local paths).

import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/notification_bell.dart';
import '../widgets/receipt_thumb_cell.dart';

class InstructorExpensesScreen extends ConsumerStatefulWidget {
  const InstructorExpensesScreen({super.key});
  @override
  ConsumerState<InstructorExpensesScreen> createState() =>
      _InstructorExpensesScreenState();
}

class _InstructorExpensesScreenState
    extends ConsumerState<InstructorExpensesScreen> {
  @override
  Widget build(BuildContext context) {
    final async = ref.watch(myExpensesProvider);
    return Scaffold(
      backgroundColor: KsColors.bg,
      body: RefreshIndicator(
        color: KsColors.primary,
        onRefresh: () async => ref.invalidate(myExpensesProvider),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 24),
          children: [
            _Header(
              name: ref.watch(authControllerProvider).identity?.name ?? '',
              onAdd: _addExpense,
            ),
            const SizedBox(height: 14),
            async.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator(color: KsColors.primary)),
              ),
              error: (e, _) => Text('Couldn’t load.\n$e'),
              data: (payload) => _Body(payload: payload, onOpen: _openDetail),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _addExpense() async {
    // Open the form immediately — the receipt is attached from inside
    // the form so the instructor can fill in category / amount / where
    // first and choose camera / library / file last.
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => const _AddExpenseScreen(),
      fullscreenDialog: true,
    ));
    if (mounted) ref.invalidate(myExpensesProvider);
  }

  Future<void> _openDetail(Expense e) async {
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _ExpenseDetailScreen(expense: e),
    ));
    if (mounted) ref.invalidate(myExpensesProvider);
  }
}

class _Header extends StatelessWidget {
  final String name;
  final VoidCallback onAdd;
  const _Header({required this.name, required this.onAdd});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (name.isNotEmpty)
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                        color: KsColors.ink3)),
              const SizedBox(height: 2),
              Text('Expenses',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                      color: KsColors.ink,
                      letterSpacing: -0.6,
                      height: 1.05)),
            ],
          ),
        ),
        const SizedBox(width: 8),
        const NotificationBell(),
        const SizedBox(width: 6),
        ElevatedButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 18),
          label: const Text('Add expense'),
        ),
      ],
    );
  }
}

class _Body extends StatelessWidget {
  final MyExpensesPayload payload;
  final void Function(Expense) onOpen;
  const _Body({required this.payload, required this.onOpen});
  @override
  Widget build(BuildContext context) {
    final pending = payload.expenses.where((e) => e.status == 'pending').toList();
    final approved = payload.expenses.where((e) => e.status == 'approved').toList();
    final reimbursed = payload.expenses.where((e) => e.status == 'reimbursed').toList();
    final rejected = payload.expenses.where((e) => e.status == 'rejected').toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Outstanding hero
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: KsColors.primaryTint,
            borderRadius: BorderRadius.circular(KsRadius.lg),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('AWAITING REIMBURSEMENT',
                  style: TextStyle(
                      color: KsColors.primaryDeep,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                      letterSpacing: 0.6)),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text('£${(payload.outstandingAmountPence / 100).toStringAsFixed(2)}',
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 30,
                          fontWeight: FontWeight.w800,
                          color: KsColors.primaryDeep,
                          letterSpacing: -0.7)),
                  const SizedBox(width: 10),
                  Text(
                      'across ${payload.outstandingCount} item${payload.outstandingCount == 1 ? '' : 's'}',
                      style: const TextStyle(
                          color: KsColors.ink2,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (pending.isNotEmpty)
          _Section(label: 'Pending review', rows: pending, onOpen: onOpen),
        if (approved.isNotEmpty)
          _Section(label: 'Approved — awaiting payment', rows: approved, onOpen: onOpen),
        if (reimbursed.isNotEmpty)
          _Section(label: 'Reimbursed', rows: reimbursed, onOpen: onOpen),
        if (rejected.isNotEmpty)
          _Section(label: 'Rejected', rows: rejected, onOpen: onOpen),
        if (payload.expenses.isEmpty)
          _EmptyState(),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  final String label;
  final List<Expense> rows;
  final void Function(Expense) onOpen;
  const _Section({required this.label, required this.rows, required this.onOpen});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 6, 2, 8),
            child: Text(label.toUpperCase(),
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: KsColors.ink3,
                    letterSpacing: 0.5)),
          ),
          for (final e in rows) _ExpenseRow(e: e, onTap: () => onOpen(e)),
        ],
      ),
    );
  }
}

class _ExpenseRow extends StatelessWidget {
  final Expense e;
  final VoidCallback onTap;
  const _ExpenseRow({required this.e, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final df = DateFormat('d MMM');
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: KsColors.surface,
            borderRadius: BorderRadius.circular(KsRadius.lg),
            border: Border.all(color: KsColors.border),
            boxShadow: KsShadows.sh1,
          ),
          child: Row(children: [
            // Inline 50×50 receipt thumbnail (base64 from the list
            // payload). Falls back to the striped category placeholder
            // when the server hasn't shipped a thumb (older rows from
            // before migration 0006).
            ReceiptThumbCell(
              thumbBytes: e.receiptThumbBytes,
              fallback: _ReceiptThumb(category: _categoryFromExpense(e)),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(children: [
                    Text('£${(e.amountPence / 100).toStringAsFixed(2)}',
                        style: GoogleFonts.plusJakartaSans(
                            fontSize: 14.5,
                            fontWeight: FontWeight.w800,
                            color: KsColors.ink)),
                    const SizedBox(width: 6),
                    Text('· ${e.categoryLabel}',
                        style: const TextStyle(
                            color: KsColors.ink3,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ]),
                  const SizedBox(height: 2),
                  Text(
                    '${e.where.isEmpty ? '—' : e.where} · ${df.format(e.occurredAt)}',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: KsColors.ink3, fontSize: 12),
                  ),
                ],
              ),
            ),
            _StatusPill(status: e.status),
          ]),
        ),
      ),
    );
  }
}

class _ReceiptThumb extends StatelessWidget {
  final ExpenseCategory? category;
  const _ReceiptThumb({required this.category});
  @override
  Widget build(BuildContext context) {
    final tone = category?.tone ?? 277;
    final c = HSLColor.fromAHSL(1, (tone % 360).toDouble(), 0.55, 0.55).toColor();
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(KsRadius.sm),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [KsColors.surface3, KsColors.surface2],
          stops: const [0.5, 0.5],
          tileMode: TileMode.repeated,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(_iconFor(category?.icon ?? 'more-h'), color: c, size: 18),
    );
  }
}


class _StatusPill extends StatelessWidget {
  final String status;
  const _StatusPill({required this.status});
  @override
  Widget build(BuildContext context) {
    late Color fg, bg;
    late String label;
    switch (status) {
      case 'pending':
        fg = KsColors.warning;
        bg = KsColors.warningTint;
        label = 'Pending review';
        break;
      case 'approved':
        fg = KsColors.primary;
        bg = KsColors.primaryTint;
        label = 'Approved';
        break;
      case 'reimbursed':
        fg = KsColors.success;
        bg = KsColors.successTint;
        label = 'Reimbursed';
        break;
      case 'rejected':
        fg = KsColors.danger;
        bg = KsColors.dangerTint;
        label = 'Rejected';
        break;
      default:
        fg = KsColors.ink3;
        bg = KsColors.surface3;
        label = status;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
          color: bg, borderRadius: BorderRadius.circular(KsRadius.pill)),
      child: Text(label,
          style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 11)),
    );
  }
}

ExpenseCategory? _categoryFromExpense(Expense e) => ExpenseCategory(
      id: e.categoryId,
      label: e.categoryLabel,
      icon: e.categoryIcon,
      tone: e.categoryTone,
      active: true,
      sortOrder: 0,
    );

IconData _iconFor(String name) {
  switch (name) {
    case 'fuel':
      return Icons.local_gas_station;
    case 'cap':
      return Icons.school_outlined;
    case 'pin':
      return Icons.place_outlined;
    case 'route':
      return Icons.route_outlined;
    case 'card':
      return Icons.credit_card;
    case 'wrench':
      return Icons.build_outlined;
    case 'shield':
      return Icons.shield_outlined;
    case 'building':
      return Icons.business_outlined;
    case 'phone':
      return Icons.phone_outlined;
    default:
      return Icons.more_horiz;
  }
}

class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Column(children: [
          Icon(Icons.receipt_long, size: 48, color: KsColors.ink4),
          const SizedBox(height: 10),
          const Text('No expenses yet',
              style: TextStyle(
                  color: KsColors.ink, fontWeight: FontWeight.w800, fontSize: 16)),
          const SizedBox(height: 4),
          const Text('Tap "Add expense" the next time you fill up.',
              style: TextStyle(color: KsColors.ink2)),
        ]),
      ),
    );
  }
}

// ============ Add expense screen ============

class _AddExpenseScreen extends ConsumerStatefulWidget {
  const _AddExpenseScreen();
  @override
  ConsumerState<_AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends ConsumerState<_AddExpenseScreen> {
  Uint8List? _receiptBytes;
  String? _receiptName; // displayable label (e.g. "receipt.pdf")
  bool _receiptIsImage = false;
  String? _categoryId;
  final _amount = TextEditingController();
  final _where = TextEditingController();
  final _notes = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    _where.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _pickReceipt() async {
    final source = await showModalBottomSheet<_ReceiptSource>(
      context: context,
      backgroundColor: KsColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(KsRadius.xl)),
      ),
      builder: (_) => const _ReceiptSourceSheet(),
    );
    if (source == null || !mounted) return;
    try {
      switch (source) {
        case _ReceiptSource.camera:
          final picked = await ImagePicker()
              .pickImage(source: ImageSource.camera, imageQuality: 85);
          if (picked == null) return;
          final bytes = await picked.readAsBytes();
          if (!mounted) return;
          setState(() {
            _receiptBytes = bytes;
            _receiptName = picked.name;
            _receiptIsImage = true;
          });
        case _ReceiptSource.gallery:
          final picked = await ImagePicker()
              .pickImage(source: ImageSource.gallery, imageQuality: 85);
          if (picked == null) return;
          final bytes = await picked.readAsBytes();
          if (!mounted) return;
          setState(() {
            _receiptBytes = bytes;
            _receiptName = picked.name;
            _receiptIsImage = true;
          });
        case _ReceiptSource.file:
          // withData: true loads bytes into memory on every platform —
          // necessary on web (no local path) and harmless on mobile.
          final result = await FilePicker.platform.pickFiles(
            type: FileType.custom,
            allowedExtensions: const ['pdf', 'jpg', 'jpeg', 'png', 'heic', 'webp'],
            withData: true,
          );
          if (result == null || result.files.isEmpty) return;
          final f = result.files.single;
          if (f.bytes == null) return;
          final lower = f.name.toLowerCase();
          final isImage = lower.endsWith('.jpg') ||
              lower.endsWith('.jpeg') ||
              lower.endsWith('.png') ||
              lower.endsWith('.heic') ||
              lower.endsWith('.webp');
          if (!mounted) return;
          setState(() {
            _receiptBytes = f.bytes;
            _receiptName = f.name;
            _receiptIsImage = isImage;
          });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not attach: $e'),
          backgroundColor: KsColors.danger,
          behavior: SnackBarBehavior.floating,
        ));
      }
    }
  }

  Future<void> _submit() async {
    final amountPence = (double.tryParse(_amount.text.replaceAll(',', '.')) ?? 0) * 100;
    if (amountPence <= 0) return;
    if (_categoryId == null) return;
    if (_receiptBytes == null) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).submitExpense(
            categoryId: _categoryId!,
            amountPence: amountPence.round(),
            occurredAt: DateTime.now(),
            receiptBytes: _receiptBytes!,
            receiptFilename: _receiptName ?? 'receipt.jpg',
            where: _where.text.trim(),
            notes: _notes.text.trim(),
          );
      ref.invalidate(myExpensesProvider);
      if (mounted) Navigator.of(context).pop();
    } on ApiException catch (e) {
      setState(() {
        _error = e.message;
        _submitting = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Could not submit. Try again.';
        _submitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final catsAsync = ref.watch(expenseCategoriesProvider);
    final ready = _categoryId != null &&
        (double.tryParse(_amount.text.replaceAll(',', '.')) ?? 0) > 0 &&
        _receiptBytes != null;
    return Scaffold(
      backgroundColor: KsColors.bg,
      appBar: AppBar(
        title: const Text('Add expense'),
        backgroundColor: KsColors.surface,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
        children: [
          // Form fields come first — category, amount, where, notes —
          // so the instructor isn't gated on attaching a receipt before
          // they've even captured what they spent.
          Text('CATEGORY',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: KsColors.ink3,
                  letterSpacing: 0.5)),
          const SizedBox(height: 8),
          catsAsync.when(
            loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 14),
                child: LinearProgressIndicator(color: KsColors.primary)),
            error: (e, _) => Text('Couldn’t load categories: $e'),
            data: (cats) => Wrap(
              spacing: 8,
              runSpacing: 8,
              children: cats
                  .where((c) => c.active)
                  .map((c) => _CategoryChip(
                        cat: c,
                        selected: _categoryId == c.id,
                        onTap: () => setState(() => _categoryId = c.id),
                      ))
                  .toList(),
            ),
          ),
          const SizedBox(height: 16),
          _LabelledField(
            label: 'Amount paid',
            child: TextField(
              controller: _amount,
              onChanged: (_) => setState(() {}),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(prefixText: '£ '),
            ),
          ),
          _LabelledField(
            label: 'Where',
            hint: 'Forecourt, café, car park…',
            child: TextField(
                controller: _where,
                decoration: const InputDecoration(hintText: 'Esso Sydenham')),
          ),
          _LabelledField(
            label: 'Notes (optional)',
            child: TextField(
                controller: _notes,
                decoration: const InputDecoration(hintText: 'Top-up for the week')),
          ),
          const SizedBox(height: 14),
          // Receipt attach lives at the bottom of the form. When no
          // receipt is on file we render a single full-width "Attach
          // receipt" button (camera/library/file); after attachment, a
          // compact preview with Change / Remove controls.
          Text('RECEIPT',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: KsColors.ink3,
                  letterSpacing: 0.5)),
          const SizedBox(height: 8),
          if (_receiptBytes == null)
            ElevatedButton.icon(
              onPressed: _pickReceipt,
              icon: const Icon(Icons.attach_file, size: 18),
              label: const Text('Attach receipt'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
                backgroundColor: KsColors.primaryTint,
                foregroundColor: KsColors.primaryDeep,
                elevation: 0,
                side: BorderSide(
                    color: KsColors.primary.withValues(alpha: 0.35), width: 1.2),
              ),
            )
          else
            _ReceiptPreview(
              bytes: _receiptBytes!,
              name: _receiptName,
              isImage: _receiptIsImage,
              onChange: _pickReceipt,
              onClear: () => setState(() {
                _receiptBytes = null;
                _receiptName = null;
                _receiptIsImage = false;
              }),
            ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Icon(Icons.info_outline, size: 14, color: KsColors.ink4),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                    'Receipt is required. Submissions are reviewed by the owner before reimbursement.',
                    style: TextStyle(color: KsColors.ink3, fontSize: 12)),
              ),
            ]),
          ),
          if (_error != null) ...[
            const SizedBox(height: 6),
            Text(_error!, style: const TextStyle(color: KsColors.danger, fontSize: 13)),
          ],
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _submitting ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton(
                onPressed: ready && !_submitting ? _submit : null,
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            color: Colors.white, strokeWidth: 2))
                    : const Text('Submit for review'),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}

enum _ReceiptSource { camera, gallery, file }

/// Bottom-sheet shown when the instructor taps the receipt slot. Lists
/// the three attach sources — camera, photo library, file from disk —
/// and returns the chosen one.
class _ReceiptSourceSheet extends StatelessWidget {
  const _ReceiptSourceSheet();

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 14),
                decoration: BoxDecoration(
                  color: KsColors.border2,
                  borderRadius: BorderRadius.circular(KsRadius.pill),
                ),
              ),
            ),
            Text('Attach receipt',
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    color: KsColors.ink)),
            const SizedBox(height: 12),
            _option(context,
                icon: Icons.photo_camera_outlined,
                label: 'Take a photo',
                hint: 'Use the camera now',
                source: _ReceiptSource.camera),
            const SizedBox(height: 8),
            _option(context,
                icon: Icons.photo_library_outlined,
                label: 'Photo library',
                hint: 'Choose from your camera roll',
                source: _ReceiptSource.gallery),
            const SizedBox(height: 8),
            _option(context,
                icon: Icons.attach_file,
                label: 'Choose file',
                hint: 'PDF or image from Files',
                source: _ReceiptSource.file),
          ],
        ),
      ),
    );
  }

  Widget _option(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String hint,
    required _ReceiptSource source,
  }) {
    return InkWell(
      onTap: () => Navigator.of(context).pop(source),
      borderRadius: BorderRadius.circular(KsRadius.md),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: KsColors.surface2,
          borderRadius: BorderRadius.circular(KsRadius.md),
          border: Border.all(color: KsColors.border),
        ),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: KsColors.primaryTint,
              borderRadius: BorderRadius.circular(10),
            ),
            alignment: Alignment.center,
            child: Icon(icon, color: KsColors.primaryDeep, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label,
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w800,
                        color: KsColors.ink)),
                const SizedBox(height: 1),
                Text(hint,
                    style: const TextStyle(
                        color: KsColors.ink3, fontSize: 12)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: KsColors.ink4, size: 18),
        ]),
      ),
    );
  }
}

/// Compact preview shown once a receipt has been attached. For images
/// a 90-tall thumbnail; for files a PDF/file glyph tile. Both have
/// Change / Remove controls so the instructor can swap the attachment
/// before submitting.
class _ReceiptPreview extends StatelessWidget {
  final Uint8List bytes;
  final String? name;
  final bool isImage;
  final VoidCallback onChange;
  final VoidCallback onClear;
  const _ReceiptPreview({
    required this.bytes,
    required this.name,
    required this.isImage,
    required this.onChange,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.md),
        border: Border.all(color: KsColors.border),
      ),
      child: Row(children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            width: 64,
            height: 64,
            // Image.memory is cross-platform — Image.file would assert
            // on web (no dart:io File).
            child: isImage
                ? Image.memory(bytes, fit: BoxFit.cover)
                : Container(
                    color: KsColors.primaryTint,
                    alignment: Alignment.center,
                    child: const Icon(Icons.picture_as_pdf_outlined,
                        color: KsColors.primaryDeep, size: 26),
                  ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(name ?? 'Receipt attached',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: KsColors.ink)),
              const SizedBox(height: 2),
              Text(isImage ? 'Image · ready to submit' : 'File · ready to submit',
                  style: const TextStyle(
                      color: KsColors.ink3, fontSize: 12)),
            ],
          ),
        ),
        TextButton(onPressed: onChange, child: const Text('Change')),
        IconButton(
          onPressed: onClear,
          icon: const Icon(Icons.close, size: 16),
          tooltip: 'Remove',
          color: KsColors.ink3,
        ),
      ]),
    );
  }
}

class _CategoryChip extends StatelessWidget {
  final ExpenseCategory cat;
  final bool selected;
  final VoidCallback onTap;
  const _CategoryChip({required this.cat, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    final tone = HSLColor.fromAHSL(1, (cat.tone % 360).toDouble(), 0.55, 0.55).toColor();
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? tone.withValues(alpha: 0.14) : KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.pill),
          border: Border.all(
              color: selected ? tone : KsColors.border, width: selected ? 1.5 : 1),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_iconFor(cat.icon), size: 14, color: selected ? tone : KsColors.ink2),
          const SizedBox(width: 6),
          Text(cat.label,
              style: TextStyle(
                  color: selected ? tone : KsColors.ink2,
                  fontWeight: FontWeight.w800,
                  fontSize: 13)),
        ]),
      ),
    );
  }
}

class _LabelledField extends StatelessWidget {
  final String label;
  final String? hint;
  final Widget child;
  const _LabelledField({required this.label, this.hint, required this.child});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: KsColors.ink2, fontWeight: FontWeight.w800, fontSize: 13)),
          if (hint != null)
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 4),
              child: Text(hint!,
                  style: const TextStyle(color: KsColors.ink4, fontSize: 12)),
            ),
          const SizedBox(height: 4),
          child,
        ],
      ),
    );
  }
}

// ============ Detail screen ============

class _ExpenseDetailScreen extends ConsumerStatefulWidget {
  final Expense expense;
  const _ExpenseDetailScreen({required this.expense});
  @override
  ConsumerState<_ExpenseDetailScreen> createState() => _ExpenseDetailScreenState();
}

class _ExpenseDetailScreenState extends ConsumerState<_ExpenseDetailScreen> {
  late final Expense _expense = widget.expense;
  bool _busy = false;

  Future<void> _withdraw() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('Withdraw this expense?'),
        content: const Text(
            'You can re-submit it later if needed. The receipt stays in our records for audit.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: const Text('Keep')),
          TextButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: const Text('Withdraw',
                  style: TextStyle(color: KsColors.danger))),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busy = true);
    try {
      await ref.read(apiClientProvider).withdrawExpense(_expense.id);
      if (mounted) Navigator.of(context).pop();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final api = ref.read(apiClientProvider);
    final df = DateFormat('EEE d MMM');
    return Scaffold(
      backgroundColor: KsColors.bg,
      appBar: AppBar(
        title: const Text('Expense'),
        backgroundColor: KsColors.surface,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 24),
        children: [
          // Receipt full — cached on disk + in memory. Receipts are
          // immutable post-upload so we cache aggressively (default
          // ~100 MB cap, LRU). The Authorization header is supplied
          // for the initial fetch only; once the bytes are on disk,
          // subsequent reads don't need it, which is why Firebase
          // token rotation doesn't invalidate the cache.
          ClipRRect(
            borderRadius: BorderRadius.circular(KsRadius.lg),
            child: CachedNetworkImage(
              imageUrl: api.receiptUrl(_expense.id),
              httpHeaders: {
                if (api.currentToken() != null && api.currentToken()!.isNotEmpty)
                  'Authorization': 'Bearer ${api.currentToken()}',
              },
              height: 320,
              fit: BoxFit.cover,
              fadeInDuration: const Duration(milliseconds: 120),
              placeholder: (ctx, _) => _expense.receiptThumbBytes.isNotEmpty
                  ? Image.memory(
                      _expense.receiptThumbBytes,
                      height: 320,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                    )
                  : Container(
                      height: 320,
                      color: KsColors.surface2,
                    ),
              errorWidget: (_, __, ___) => Container(
                height: 320,
                color: KsColors.surface2,
                alignment: Alignment.center,
                child: const Icon(Icons.receipt_long, size: 56, color: KsColors.ink4),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(
              child: Text(
                  '£${(_expense.amountPence / 100).toStringAsFixed(2)}',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: KsColors.ink,
                      letterSpacing: -0.7)),
            ),
            _StatusPill(status: _expense.status),
          ]),
          const SizedBox(height: 4),
          Text(
            '${_expense.categoryLabel} · ${_expense.where.isEmpty ? '—' : _expense.where} · ${df.format(_expense.occurredAt)}',
            style: const TextStyle(color: KsColors.ink3, fontSize: 13),
          ),
          if (_expense.notes.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: KsColors.surface,
                borderRadius: BorderRadius.circular(KsRadius.md),
                border: Border.all(color: KsColors.border),
              ),
              child: Text(_expense.notes,
                  style: const TextStyle(color: KsColors.ink2, fontSize: 13.5)),
            ),
          ],
          if (_expense.status == 'approved' && _expense.reviewerNote.isNotEmpty) ...[
            const SizedBox(height: 12),
            _StatusBlock(
              tone: KsColors.primaryDeep,
              bg: KsColors.primaryTint,
              icon: Icons.check_circle,
              title: 'Approved · ${_expense.reviewedByName}',
              body: _expense.reviewerNote,
            ),
          ],
          if (_expense.status == 'reimbursed') ...[
            const SizedBox(height: 12),
            _StatusBlock(
              tone: KsColors.success,
              bg: KsColors.successTint,
              icon: Icons.check_circle,
              title:
                  'Reimbursed${_expense.paidAt == null ? '' : ' ${df.format(_expense.paidAt!)}'} · ${_methodLabel(_expense.paidMethod)}',
              body: '',
            ),
          ],
          if (_expense.status == 'rejected') ...[
            const SizedBox(height: 12),
            _StatusBlock(
              tone: KsColors.danger,
              bg: KsColors.dangerTint,
              icon: Icons.cancel,
              title: 'Rejected by ${_expense.reviewedByName.isEmpty ? 'Owner' : _expense.reviewedByName}',
              body: _expense.reviewerNote,
            ),
          ],
          if (_expense.status == 'pending') ...[
            const SizedBox(height: 18),
            OutlinedButton.icon(
              onPressed: _busy ? null : _withdraw,
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('Withdraw'),
              style: OutlinedButton.styleFrom(foregroundColor: KsColors.danger),
            ),
          ],
        ],
      ),
    );
  }
}

class _StatusBlock extends StatelessWidget {
  final Color tone;
  final Color bg;
  final IconData icon;
  final String title;
  final String body;
  const _StatusBlock({
    required this.tone,
    required this.bg,
    required this.icon,
    required this.title,
    required this.body,
  });
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(KsRadius.md),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(icon, color: tone, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(title,
                  style: TextStyle(
                      color: tone, fontWeight: FontWeight.w800, fontSize: 13.5)),
            ),
          ]),
          if (body.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(body,
                style: const TextStyle(
                    color: KsColors.ink2, fontWeight: FontWeight.w600, fontSize: 13)),
          ],
        ],
      ),
    );
  }
}

String _methodLabel(String m) {
  switch (m) {
    case 'bank':
      return 'Bank transfer';
    case 'cash':
      return 'Cash';
    case 'other':
      return 'Other';
  }
  return m;
}
