// Instructor Expenses — submit / track reimbursable spend (petrol, lunch,
// parking, tolls, other). Approval-first: pending → approved → reimbursed
// (or → rejected). Receipt photo is required at submission.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/notification_bell.dart';

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
            Row(children: [
              Expanded(
                child: Text('Expenses',
                    style: GoogleFonts.plusJakartaSans(
                        fontSize: 25,
                        fontWeight: FontWeight.w800,
                        color: KsColors.ink,
                        letterSpacing: -0.6)),
              ),
              const SizedBox(width: 8),
              const NotificationBell(),
              const SizedBox(width: 8),
              ElevatedButton.icon(
                onPressed: _addExpense,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add expense'),
              ),
            ]),
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
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: ImageSource.camera,
      imageQuality: 85,
    );
    if (picked == null) return;
    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => _AddExpenseScreen(receiptPath: picked.path),
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
            // Striped receipt thumbnail with the category glyph
            _ReceiptThumb(category: _categoryFromExpense(e)),
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
  final String receiptPath;
  const _AddExpenseScreen({required this.receiptPath});
  @override
  ConsumerState<_AddExpenseScreen> createState() => _AddExpenseScreenState();
}

class _AddExpenseScreenState extends ConsumerState<_AddExpenseScreen> {
  late String _receiptPath = widget.receiptPath;
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

  Future<void> _retake() async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: ImageSource.camera, imageQuality: 85);
    if (picked != null) setState(() => _receiptPath = picked.path);
  }

  Future<void> _submit() async {
    final amountPence = (double.tryParse(_amount.text.replaceAll(',', '.')) ?? 0) * 100;
    if (amountPence <= 0) return;
    if (_categoryId == null) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).submitExpense(
            categoryId: _categoryId!,
            amountPence: amountPence.round(),
            occurredAt: DateTime.now(),
            receiptPath: _receiptPath,
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
    final ready =
        _categoryId != null && (double.tryParse(_amount.text.replaceAll(',', '.')) ?? 0) > 0;
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
          // Receipt preview
          Stack(children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(KsRadius.lg),
              child: Image.file(File(_receiptPath),
                  height: 240, width: double.infinity, fit: BoxFit.cover),
            ),
            Positioned(
              top: 10,
              right: 10,
              child: ElevatedButton.icon(
                onPressed: _retake,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Retake'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: KsColors.surface,
                  foregroundColor: KsColors.ink,
                ),
              ),
            ),
          ]),
          const SizedBox(height: 16),
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
          const SizedBox(height: 4),
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Row(children: [
              Icon(Icons.info_outline, size: 14, color: KsColors.ink4),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                    'Submitted expenses are reviewed by the owner before reimbursement.',
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
      builder: (_) => AlertDialog(
        title: const Text('Withdraw this expense?'),
        content: const Text(
            'You can re-submit it later if needed. The receipt stays in our records for audit.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep')),
          TextButton(
              onPressed: () => Navigator.pop(context, true),
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
          // Receipt full
          ClipRRect(
            borderRadius: BorderRadius.circular(KsRadius.lg),
            child: Image.network(
              api.receiptUrl(_expense.id),
              headers: {
                if (api.currentToken() != null && api.currentToken()!.isNotEmpty)
                  'Authorization': 'Bearer ${api.currentToken()}',
              },
              height: 320,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
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
