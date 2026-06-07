// Admin Reimbursements — review instructor-submitted expenses.
//
// Layout mirrors design_handoff_kickstand/app/admin.jsx ReimbursementsScreen:
//   - KPI row: Pending review · Approved owed · This month
//   - Status tabs: Pending / Approved / Reimbursed / Rejected
//   - Table with per-row actions (Approve / Reject / Mark reimbursed)
//   - "Manage types" button in the header → categories editor modal
//   - Row click → full expense detail modal with timeline + actions

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';

class AdminReimbursementsScreen extends ConsumerStatefulWidget {
  const AdminReimbursementsScreen({super.key});
  @override
  ConsumerState<AdminReimbursementsScreen> createState() =>
      _AdminReimbursementsScreenState();
}

class _AdminReimbursementsScreenState
    extends ConsumerState<AdminReimbursementsScreen> {
  String _tab = 'pending';

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(expensesForReviewProvider);
    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async => ref.invalidate(expensesForReviewProvider),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Reimbursements',
                      style: GoogleFonts.plusJakartaSans(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: KsColors.ink,
                          letterSpacing: -0.6)),
                  const SizedBox(height: 4),
                  const Text(
                    'Instructor-submitted expenses: review, approve, and mark reimbursed.',
                    style: TextStyle(color: KsColors.ink3, fontSize: 13),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: _openManageCategories,
              icon: const Icon(Icons.tune, size: 16),
              label: const Text('Manage types'),
            ),
          ]),
          const SizedBox(height: 18),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: CircularProgressIndicator(color: KsColors.primary)),
            ),
            error: (e, _) => Text('Couldn’t load.\n$e'),
            data: (payload) => _Body(
              payload: payload,
              tab: _tab,
              onTab: (v) => setState(() => _tab = v),
              onOpen: _openDetail,
              onApprove: _approve,
              onReject: _reject,
              onReimburse: _reimburse,
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openManageCategories() async {
    await showDialog(
      context: context,
      builder: (_) => const Dialog(
        insetPadding: EdgeInsets.symmetric(horizontal: 28, vertical: 40),
        child: _ManageCategoriesDialog(),
      ),
    );
  }

  Future<void> _openDetail(Expense e) async {
    await showDialog(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
        child: _ExpenseDetailDialog(
          expense: e,
          onApprove: () {
            Navigator.of(context).pop();
            _approve(e);
          },
          onReject: () {
            Navigator.of(context).pop();
            _reject(e);
          },
          onReimburse: () {
            Navigator.of(context).pop();
            _reimburse(e);
          },
        ),
      ),
    );
  }

  Future<void> _approve(Expense e) async {
    final note = await _promptForNote(
      title: 'Approve expense',
      tone: KsColors.success,
      hint: 'e.g. Include in next payroll.',
      required: false,
      submitLabel: 'Approve',
    );
    if (note == null) return;
    try {
      await ref.read(apiClientProvider).approveExpense(e.id, reviewerNote: note);
      ref.invalidate(expensesForReviewProvider);
      if (mounted) _toast('Approved £${(e.amountPence / 100).toStringAsFixed(2)}');
    } catch (err) {
      if (mounted) _toast('Could not approve: $err', error: true);
    }
  }

  Future<void> _reject(Expense e) async {
    final note = await _promptForNote(
      title: 'Reject expense',
      tone: KsColors.danger,
      hint: 'Outside policy, missing receipt, duplicate…',
      required: true,
      submitLabel: 'Reject',
    );
    if (note == null || note.isEmpty) return;
    try {
      await ref.read(apiClientProvider).rejectExpense(e.id, reviewerNote: note);
      ref.invalidate(expensesForReviewProvider);
      if (mounted) _toast('Rejected · instructor notified');
    } catch (err) {
      if (mounted) _toast('Could not reject: $err', error: true);
    }
  }

  Future<void> _reimburse(Expense e) async {
    try {
      await ref.read(apiClientProvider).reimburseExpense(e.id);
      ref.invalidate(expensesForReviewProvider);
      if (mounted) _toast('Marked £${(e.amountPence / 100).toStringAsFixed(2)} as reimbursed');
    } catch (err) {
      if (mounted) _toast('Could not mark reimbursed: $err', error: true);
    }
  }

  Future<String?> _promptForNote({
    required String title,
    required Color tone,
    required String hint,
    required bool required,
    required String submitLabel,
  }) async {
    final ctrl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: ctrl,
                autofocus: true,
                maxLines: 3,
                decoration: InputDecoration(
                  hintText: hint,
                  labelText: required ? 'Reason (required)' : 'Note (optional)',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final v = ctrl.text.trim();
              if (required && v.isEmpty) return;
              Navigator.pop(ctx, v);
            },
            style: ElevatedButton.styleFrom(backgroundColor: tone),
            child: Text(submitLabel),
          ),
        ],
      ),
    );
  }

  void _toast(String message, {bool error = false}) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? KsColors.danger : KsColors.ink,
      behavior: SnackBarBehavior.floating,
    ));
  }
}

class _Body extends StatelessWidget {
  final ExpensesQueuePayload payload;
  final String tab;
  final ValueChanged<String> onTab;
  final void Function(Expense) onOpen;
  final void Function(Expense) onApprove;
  final void Function(Expense) onReject;
  final void Function(Expense) onReimburse;
  const _Body({
    required this.payload,
    required this.tab,
    required this.onTab,
    required this.onOpen,
    required this.onApprove,
    required this.onReject,
    required this.onReimburse,
  });

  @override
  Widget build(BuildContext context) {
    final pending = payload.expenses.where((e) => e.status == 'pending').toList();
    final approved = payload.expenses.where((e) => e.status == 'approved').toList();
    final reimbursed = payload.expenses.where((e) => e.status == 'reimbursed').toList();
    final rejected = payload.expenses.where((e) => e.status == 'rejected').toList();

    final pendingTotal = pending.fold(0, (s, e) => s + e.amountPence);
    final approvedTotal = approved.fold(0, (s, e) => s + e.amountPence);
    final monthTotal = [...approved, ...reimbursed].fold(0, (s, e) => s + e.amountPence);

    final rows = switch (tab) {
      'pending' => pending,
      'approved' => approved,
      'reimbursed' => reimbursed,
      'rejected' => rejected,
      _ => pending,
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _KpiRow(
          pendingPence: pendingTotal,
          pendingCount: pending.length,
          approvedPence: approvedTotal,
          approvedCount: approved.length,
          monthPence: monthTotal,
        ),
        const SizedBox(height: 14),
        Wrap(
          spacing: 4,
          children: [
            _TabChip(label: 'Pending', count: pending.length, on: tab == 'pending', onTap: () => onTab('pending')),
            _TabChip(label: 'Approved', count: approved.length, on: tab == 'approved', onTap: () => onTab('approved')),
            _TabChip(label: 'Reimbursed', count: reimbursed.length, on: tab == 'reimbursed', onTap: () => onTab('reimbursed')),
            _TabChip(label: 'Rejected', count: rejected.length, on: tab == 'rejected', onTap: () => onTab('rejected')),
          ],
        ),
        const SizedBox(height: 14),
        if (rows.isEmpty)
          Container(
            padding: const EdgeInsets.all(40),
            decoration: BoxDecoration(
              color: KsColors.surface,
              borderRadius: BorderRadius.circular(KsRadius.lg),
              border: Border.all(color: KsColors.border),
            ),
            child: const Center(
              child: Text('Nothing to show here.', style: TextStyle(color: KsColors.ink3)),
            ),
          )
        else
          Container(
            decoration: BoxDecoration(
              color: KsColors.surface,
              borderRadius: BorderRadius.circular(KsRadius.lg),
              border: Border.all(color: KsColors.border),
              boxShadow: KsShadows.sh1,
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(children: [
              _TableHeader(tab: tab),
              for (final e in rows)
                _TableRow(
                  e: e,
                  tab: tab,
                  onOpen: () => onOpen(e),
                  onApprove: () => onApprove(e),
                  onReject: () => onReject(e),
                  onReimburse: () => onReimburse(e),
                ),
            ]),
          ),
      ],
    );
  }
}

class _KpiRow extends StatelessWidget {
  final int pendingPence;
  final int pendingCount;
  final int approvedPence;
  final int approvedCount;
  final int monthPence;
  const _KpiRow({
    required this.pendingPence,
    required this.pendingCount,
    required this.approvedPence,
    required this.approvedCount,
    required this.monthPence,
  });
  @override
  Widget build(BuildContext context) {
    return Row(children: [
      _Kpi(
        tone: KsColors.warning,
        icon: Icons.warning_amber_rounded,
        label: 'Pending review',
        value: '£${(pendingPence / 100).toStringAsFixed(2)}',
        foot: '$pendingCount item${pendingCount == 1 ? '' : 's'}',
      ),
      const SizedBox(width: 12),
      _Kpi(
        tone: KsColors.primary,
        icon: Icons.credit_card,
        label: 'Approved, owed',
        value: '£${(approvedPence / 100).toStringAsFixed(2)}',
        foot: '$approvedCount item${approvedCount == 1 ? '' : 's'} · ready to pay',
      ),
      const SizedBox(width: 12),
      _Kpi(
        tone: KsColors.success,
        icon: Icons.check_circle,
        label: 'This month',
        value: '£${(monthPence / 100).toStringAsFixed(2)}',
        foot: 'Approved + reimbursed',
      ),
    ]);
  }
}

class _Kpi extends StatelessWidget {
  final Color tone;
  final IconData icon;
  final String label;
  final String value;
  final String foot;
  const _Kpi({
    required this.tone,
    required this.icon,
    required this.label,
    required this.value,
    required this.foot,
  });
  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
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
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                    color: tone.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(KsRadius.md)),
                alignment: Alignment.center,
                child: Icon(icon, color: tone, size: 18),
              ),
              const SizedBox(width: 10),
              Text(label.toUpperCase(),
                  style: TextStyle(
                      color: KsColors.ink3,
                      fontWeight: FontWeight.w800,
                      fontSize: 11,
                      letterSpacing: 0.4)),
            ]),
            const SizedBox(height: 8),
            Text(value,
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: KsColors.ink,
                    letterSpacing: -0.7)),
            Text(foot,
                style: const TextStyle(
                    color: KsColors.ink3, fontSize: 12.5, fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  final String label;
  final int count;
  final bool on;
  final VoidCallback onTap;
  const _TabChip({
    required this.label,
    required this.count,
    required this.on,
    required this.onTap,
  });
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: on ? KsColors.surface : Colors.transparent,
          borderRadius: BorderRadius.circular(KsRadius.pill),
          boxShadow: on ? KsShadows.sh1 : null,
        ),
        child: Text('$label ($count)',
            style: GoogleFonts.plusJakartaSans(
                color: on ? KsColors.ink : KsColors.ink3,
                fontWeight: FontWeight.w700,
                fontSize: 13)),
      ),
    );
  }
}

class _TableHeader extends StatelessWidget {
  final String tab;
  const _TableHeader({required this.tab});
  @override
  Widget build(BuildContext context) {
    final lastLabel = tab == 'reimbursed'
        ? 'Paid'
        : tab == 'rejected'
            ? 'Reason'
            : 'Status';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
      decoration: const BoxDecoration(
        color: KsColors.surface2,
        border: Border(bottom: BorderSide(color: KsColors.border)),
      ),
      child: Row(children: [
        Expanded(flex: 3, child: _ColLabel('Instructor')),
        const SizedBox(width: 60, child: _ColLabel('Receipt')),
        Expanded(flex: 2, child: _ColLabel('Category')),
        Expanded(flex: 2, child: _ColLabel('Amount')),
        Expanded(flex: 3, child: _ColLabel('When · Where')),
        Expanded(flex: 3, child: _ColLabel(lastLabel)),
        const SizedBox(width: 220),
      ]),
    );
  }
}

class _ColLabel extends StatelessWidget {
  final String label;
  const _ColLabel(this.label);
  @override
  Widget build(BuildContext context) => Text(label.toUpperCase(),
      style: GoogleFonts.plusJakartaSans(
          color: KsColors.ink3,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5));
}

class _TableRow extends StatelessWidget {
  final Expense e;
  final String tab;
  final VoidCallback onOpen;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onReimburse;
  const _TableRow({
    required this.e,
    required this.tab,
    required this.onOpen,
    required this.onApprove,
    required this.onReject,
    required this.onReimburse,
  });
  @override
  Widget build(BuildContext context) {
    final df = DateFormat('d MMM');
    final tone = HSLColor.fromAHSL(1, (e.categoryTone % 360).toDouble(), 0.55, 0.55).toColor();
    return InkWell(
      onTap: onOpen,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: KsColors.border)),
        ),
        child: Row(children: [
          // Instructor
          Expanded(
            flex: 3,
            child: Row(children: [
              Container(
                width: 32, height: 32,
                decoration: BoxDecoration(
                    color: KsColors.primaryTint,
                    borderRadius: BorderRadius.circular(KsRadius.pill)),
                alignment: Alignment.center,
                child: Text(
                  _initials(e.instructorName),
                  style: const TextStyle(
                      color: KsColors.primaryDeep, fontWeight: FontWeight.w800, fontSize: 12),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(e.instructorName,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, color: KsColors.ink)),
              ),
            ]),
          ),
          // Receipt thumbnail — striped placeholder + ticket glyph, click
          // opens the full detail modal (row click does the same; this gives
          // the manager an explicit visual cue per the design).
          SizedBox(
            width: 60,
            child: Align(
              alignment: Alignment.centerLeft,
              child: _ReceiptThumbButton(onTap: onOpen),
            ),
          ),
          // Category
          Expanded(
            flex: 2,
            child: Container(
              alignment: Alignment.centerLeft,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                decoration: BoxDecoration(
                  color: tone.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(KsRadius.pill),
                ),
                child: Text(e.categoryLabel,
                    style: TextStyle(color: tone, fontWeight: FontWeight.w800, fontSize: 12)),
              ),
            ),
          ),
          // Amount
          Expanded(
            flex: 2,
            child: Text('£${(e.amountPence / 100).toStringAsFixed(2)}',
                style: GoogleFonts.plusJakartaSans(
                    fontWeight: FontWeight.w800, color: KsColors.ink, fontSize: 14)),
          ),
          // When / where
          Expanded(
            flex: 3,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(df.format(e.occurredAt),
                    style: const TextStyle(color: KsColors.ink2, fontSize: 13)),
                Text(e.where.isEmpty ? '—' : e.where,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: KsColors.ink3, fontSize: 12)),
              ],
            ),
          ),
          // Status / reason / paid
          Expanded(
            flex: 3,
            child: tab == 'reimbursed'
                ? Text(
                    e.paidAt == null ? '' : '${df.format(e.paidAt!)} · ${_methodLabel(e.paidMethod)}',
                    style: const TextStyle(color: KsColors.ink2, fontSize: 12.5, fontWeight: FontWeight.w700))
                : tab == 'rejected'
                    ? Text(e.reviewerNote.isEmpty ? 'Rejected' : e.reviewerNote,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 2,
                        style: const TextStyle(color: KsColors.danger, fontSize: 12.5, fontWeight: FontWeight.w700))
                    : _StatusPill(status: e.status),
          ),
          // Actions
          SizedBox(
            width: 220,
            child: _ActionsCell(
              status: e.status,
              onApprove: onApprove,
              onReject: onReject,
              onReimburse: onReimburse,
              onView: onOpen,
            ),
          ),
        ]),
      ),
    );
  }
}

class _ActionsCell extends StatelessWidget {
  final String status;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onReimburse;
  final VoidCallback onView;
  const _ActionsCell({
    required this.status,
    required this.onApprove,
    required this.onReject,
    required this.onReimburse,
    required this.onView,
  });
  @override
  Widget build(BuildContext context) {
    switch (status) {
      case 'pending':
        return Row(mainAxisAlignment: MainAxisAlignment.end, children: [
          OutlinedButton(
              onPressed: onReject,
              style: OutlinedButton.styleFrom(
                  foregroundColor: KsColors.ink2, minimumSize: const Size(0, 32)),
              child: const Text('Reject')),
          const SizedBox(width: 6),
          ElevatedButton.icon(
              onPressed: onApprove,
              icon: const Icon(Icons.check, size: 14),
              label: const Text('Approve'),
              style: ElevatedButton.styleFrom(
                  backgroundColor: KsColors.success,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(0, 32))),
        ]);
      case 'approved':
        return Align(
          alignment: Alignment.centerRight,
          child: ElevatedButton.icon(
              onPressed: onReimburse,
              icon: const Icon(Icons.credit_card, size: 14),
              label: const Text('Mark reimbursed'),
              style: ElevatedButton.styleFrom(minimumSize: const Size(0, 32))),
        );
      default:
        return Align(
          alignment: Alignment.centerRight,
          child: OutlinedButton(
              onPressed: onView,
              style: OutlinedButton.styleFrom(minimumSize: const Size(0, 32)),
              child: const Text('View')),
        );
    }
  }
}

/// Diagonal-striped 44×44 placeholder + ticket glyph. Clicking opens the
/// full expense detail modal (where the real receipt is loaded).
class _ReceiptThumbButton extends StatelessWidget {
  final VoidCallback onTap;
  const _ReceiptThumbButton({required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.sm),
      child: Tooltip(
        message: 'View full details',
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(KsRadius.sm),
            border: Border.all(color: KsColors.border),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(children: [
            // Repeating diagonal stripes — same trick as the design's CSS.
            CustomPaint(size: const Size(44, 44), painter: const _StripePainter()),
            const Center(
              child: Icon(Icons.receipt_long, size: 16, color: KsColors.ink4),
            ),
          ]),
        ),
      ),
    );
  }
}

class _StripePainter extends CustomPainter {
  const _StripePainter();
  @override
  void paint(Canvas canvas, Size size) {
    final base = Paint()..color = KsColors.surface2;
    canvas.drawRect(Offset.zero & size, base);
    final stripe = Paint()..color = KsColors.surface3;
    const double step = 12;
    final diag = size.width + size.height;
    for (double x = -size.height; x < diag; x += step) {
      final path = Path()
        ..moveTo(x, 0)
        ..lineTo(x + 6, 0)
        ..lineTo(x + 6 + size.height, size.height)
        ..lineTo(x + size.height, size.height)
        ..close();
      canvas.drawPath(path, stripe);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
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
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
            color: bg, borderRadius: BorderRadius.circular(KsRadius.pill)),
        child: Text(label,
            style: TextStyle(color: fg, fontWeight: FontWeight.w800, fontSize: 11)),
      ),
    );
  }
}

// ============ Full detail modal ============

class _ExpenseDetailDialog extends ConsumerWidget {
  final Expense expense;
  final VoidCallback onApprove;
  final VoidCallback onReject;
  final VoidCallback onReimburse;
  const _ExpenseDetailDialog({
    required this.expense,
    required this.onApprove,
    required this.onReject,
    required this.onReimburse,
  });
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final api = ref.read(apiClientProvider);
    final df = DateFormat('EEE d MMM · HH:mm');
    final tone = HSLColor.fromAHSL(1, (expense.categoryTone % 360).toDouble(), 0.55, 0.55).toColor();
    return Container(
      width: 720,
      padding: const EdgeInsets.all(22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: KsColors.primaryTint,
                borderRadius: BorderRadius.circular(KsRadius.md),
              ),
              alignment: Alignment.center,
              child: const Icon(Icons.receipt_long, color: KsColors.primaryDeep),
            ),
            const SizedBox(width: 12),
            Text('Expense detail',
                style: GoogleFonts.plusJakartaSans(
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                    color: KsColors.ink,
                    letterSpacing: -0.4)),
            const Spacer(),
            IconButton(
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close)),
          ]),
          const SizedBox(height: 14),
          // Two columns: receipt + meta
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(KsRadius.lg),
                    child: Image.network(
                      api.receiptUrl(expense.id),
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
                ),
                const SizedBox(width: 18),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(children: [
                        Expanded(
                          child: Text(expense.instructorName,
                              style: GoogleFonts.plusJakartaSans(
                                  fontWeight: FontWeight.w800,
                                  color: KsColors.ink,
                                  fontSize: 16)),
                        ),
                        _StatusPill(status: expense.status),
                      ]),
                      const SizedBox(height: 8),
                      Row(children: [
                        Text('£${(expense.amountPence / 100).toStringAsFixed(2)}',
                            style: GoogleFonts.plusJakartaSans(
                                fontSize: 30,
                                fontWeight: FontWeight.w800,
                                color: KsColors.ink,
                                letterSpacing: -0.8)),
                        const SizedBox(width: 10),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                          decoration: BoxDecoration(
                            color: tone.withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(KsRadius.pill),
                          ),
                          child: Text(expense.categoryLabel,
                              style: TextStyle(
                                  color: tone, fontWeight: FontWeight.w800, fontSize: 12)),
                        ),
                      ]),
                      const SizedBox(height: 10),
                      _Field(label: 'When', value: df.format(expense.occurredAt)),
                      _Field(label: 'Where', value: expense.where.isEmpty ? '—' : expense.where),
                      if (expense.notes.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _SectionLabel('Instructor note'),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: KsColors.surface2,
                            borderRadius: BorderRadius.circular(KsRadius.md),
                          ),
                          child: Text(expense.notes,
                              style: const TextStyle(color: KsColors.ink2, fontSize: 13)),
                        ),
                      ],
                      if (expense.reviewerNote.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        _SectionLabel('Reviewer note'),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: expense.status == 'rejected'
                                ? KsColors.dangerTint
                                : KsColors.surface2,
                            borderRadius: BorderRadius.circular(KsRadius.md),
                          ),
                          child: Text(expense.reviewerNote,
                              style: const TextStyle(color: KsColors.ink2, fontSize: 13)),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          _Timeline(expense: expense),
          const SizedBox(height: 18),
          Row(children: [
            Expanded(
              child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close')),
            ),
            if (expense.status == 'pending') ...[
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: onReject,
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('Reject…'),
                  style: ElevatedButton.styleFrom(backgroundColor: KsColors.danger),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: onApprove,
                  icon: const Icon(Icons.check, size: 16),
                  label: const Text('Approve…'),
                  style: ElevatedButton.styleFrom(backgroundColor: KsColors.success),
                ),
              ),
            ],
            if (expense.status == 'approved') ...[
              const SizedBox(width: 8),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: onReimburse,
                  icon: const Icon(Icons.credit_card, size: 16),
                  label: const Text('Mark reimbursed'),
                ),
              ),
            ],
          ]),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  final String label;
  final String value;
  const _Field({required this.label, required this.value});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        SizedBox(
          width: 64,
          child: Text(label.toUpperCase(),
              style: const TextStyle(
                  color: KsColors.ink3,
                  fontWeight: FontWeight.w800,
                  fontSize: 10.5,
                  letterSpacing: 0.4)),
        ),
        Expanded(
          child: Text(value,
              style: const TextStyle(
                  color: KsColors.ink, fontSize: 13.5, fontWeight: FontWeight.w600)),
        ),
      ]),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 6),
        child: Text(label.toUpperCase(),
            style: const TextStyle(
                color: KsColors.ink3,
                fontWeight: FontWeight.w800,
                fontSize: 10.5,
                letterSpacing: 0.4)),
      );
}

class _Timeline extends StatelessWidget {
  final Expense expense;
  const _Timeline({required this.expense});
  @override
  Widget build(BuildContext context) {
    final df = DateFormat('d MMM · HH:mm');
    final items = <_TimelineEntry>[
      _TimelineEntry(
          label: 'Submitted',
          who: expense.instructorName,
          when: df.format(expense.submittedAt),
          icon: Icons.add,
          tone: KsColors.primary),
    ];
    if (expense.reviewedAt != null) {
      items.add(_TimelineEntry(
        label: expense.status == 'rejected' ? 'Rejected' : 'Approved',
        who: expense.reviewedByName.isEmpty ? 'Owner' : expense.reviewedByName,
        when: df.format(expense.reviewedAt!),
        icon: expense.status == 'rejected' ? Icons.cancel : Icons.check_circle,
        tone: expense.status == 'rejected' ? KsColors.danger : KsColors.success,
      ));
    }
    if (expense.paidAt != null) {
      items.add(_TimelineEntry(
        label: 'Reimbursed',
        who: expense.paidByName.isEmpty ? 'Owner' : expense.paidByName,
        when: '${df.format(expense.paidAt!)} · ${_methodLabel(expense.paidMethod)}',
        icon: Icons.credit_card,
        tone: KsColors.success,
      ));
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: KsColors.surface2, borderRadius: BorderRadius.circular(KsRadius.lg)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('Timeline'),
          for (final t in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: t.tone.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(KsRadius.pill),
                  ),
                  alignment: Alignment.center,
                  child: Icon(t.icon, color: t.tone, size: 14),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text.rich(TextSpan(children: [
                        TextSpan(
                            text: t.label,
                            style: const TextStyle(
                                color: KsColors.ink,
                                fontWeight: FontWeight.w800,
                                fontSize: 13.5)),
                        TextSpan(
                            text: ' · ${t.who}',
                            style: const TextStyle(
                                color: KsColors.ink3,
                                fontWeight: FontWeight.w600,
                                fontSize: 13)),
                      ])),
                      Text(t.when,
                          style: const TextStyle(
                              color: KsColors.ink4, fontSize: 12)),
                    ],
                  ),
                ),
              ]),
            ),
        ],
      ),
    );
  }
}

class _TimelineEntry {
  final String label;
  final String who;
  final String when;
  final IconData icon;
  final Color tone;
  _TimelineEntry({
    required this.label,
    required this.who,
    required this.when,
    required this.icon,
    required this.tone,
  });
}

// ============ Manage categories dialog ============

class _ManageCategoriesDialog extends ConsumerStatefulWidget {
  const _ManageCategoriesDialog();
  @override
  ConsumerState<_ManageCategoriesDialog> createState() =>
      _ManageCategoriesDialogState();
}

class _ManageCategoriesDialogState extends ConsumerState<_ManageCategoriesDialog> {
  List<ExpenseCategory>? _cats;
  bool _saving = false;
  String? _error;

  static const _icons = ['fuel', 'cap', 'pin', 'route', 'card', 'wrench', 'shield', 'building', 'phone', 'more-h'];
  static const _tones = [25, 70, 160, 200, 277];

  IconData _flutterIconFor(String n) {
    switch (n) {
      case 'fuel': return Icons.local_gas_station;
      case 'cap': return Icons.school_outlined;
      case 'pin': return Icons.place_outlined;
      case 'route': return Icons.route_outlined;
      case 'card': return Icons.credit_card;
      case 'wrench': return Icons.build_outlined;
      case 'shield': return Icons.shield_outlined;
      case 'building': return Icons.business_outlined;
      case 'phone': return Icons.phone_outlined;
      default: return Icons.more_horiz;
    }
  }

  Future<void> _save() async {
    if (_cats == null) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await ref.read(apiClientProvider).upsertExpenseCategories(_cats!);
      ref.invalidate(expenseCategoriesProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() {
        _error = '$e';
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(expenseCategoriesProvider);
    _cats ??= async.maybeWhen(data: (l) => l.toList(), orElse: () => null);
    return Container(
      width: 520,
      padding: const EdgeInsets.all(22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Reimbursement types',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 19,
                  fontWeight: FontWeight.w800,
                  color: KsColors.ink,
                  letterSpacing: -0.4)),
          const SizedBox(height: 6),
          const Text(
            'Pick which types your instructors can submit. Removing a type doesn’t change historical expenses tagged with it.',
            style: TextStyle(color: KsColors.ink3, fontSize: 13),
          ),
          const SizedBox(height: 14),
          if (_cats == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 22),
              child: Center(child: CircularProgressIndicator(color: KsColors.primary)),
            )
          else
            Column(
              children: [
                for (int i = 0; i < _cats!.length; i++) _row(i),
                OutlinedButton.icon(
                  onPressed: () => setState(() {
                    _cats = [
                      ..._cats!,
                      ExpenseCategory(
                        id: 'new_${DateTime.now().millisecondsSinceEpoch}',
                        label: 'New type',
                        icon: 'more-h',
                        tone: 277,
                        active: true,
                        sortOrder: _cats!.length,
                      ),
                    ];
                  }),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('Add type'),
                ),
              ],
            ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!, style: const TextStyle(color: KsColors.danger)),
          ],
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
                child: OutlinedButton(
                    onPressed: _saving ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'))),
            const SizedBox(width: 10),
            Expanded(
              child: ElevatedButton(
                onPressed: _saving || _cats == null ? null : _save,
                child: _saving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : const Text('Save changes'),
              ),
            ),
          ]),
        ],
      ),
    );
  }

  Widget _row(int i) {
    final c = _cats![i];
    final tone = HSLColor.fromAHSL(1, (c.tone % 360).toDouble(), 0.55, 0.55).toColor();
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(children: [
        InkWell(
          onTap: () => setState(() {
            final idx = (_icons.indexOf(c.icon) + 1) % _icons.length;
            _cats![i] = ExpenseCategory(
                id: c.id, label: c.label, icon: _icons[idx],
                tone: c.tone, active: c.active, sortOrder: c.sortOrder);
          }),
          borderRadius: BorderRadius.circular(KsRadius.md),
          child: Container(
            width: 38, height: 38,
            decoration: BoxDecoration(
                color: tone.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(KsRadius.md)),
            alignment: Alignment.center,
            child: Icon(_flutterIconFor(c.icon), color: tone, size: 18),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: TextField(
            controller: TextEditingController(text: c.label)
              ..selection = TextSelection.collapsed(offset: c.label.length),
            onChanged: (v) => _cats![i] = ExpenseCategory(
                id: c.id, label: v, icon: c.icon,
                tone: c.tone, active: c.active, sortOrder: c.sortOrder),
            decoration: const InputDecoration(isDense: true),
          ),
        ),
        const SizedBox(width: 8),
        Row(
          children: [
            for (final t in _tones)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: InkWell(
                  onTap: () => setState(() {
                    _cats![i] = ExpenseCategory(
                        id: c.id, label: c.label, icon: c.icon,
                        tone: t, active: c.active, sortOrder: c.sortOrder);
                  }),
                  child: Container(
                    width: 16, height: 16,
                    decoration: BoxDecoration(
                      color: HSLColor.fromAHSL(1, (t % 360).toDouble(), 0.55, 0.55).toColor(),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: c.tone == t ? KsColors.ink : Colors.transparent, width: 2),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(width: 6),
        IconButton(
            onPressed: () => setState(() => _cats!.removeAt(i)),
            icon: const Icon(Icons.delete_outline, size: 18, color: KsColors.ink3)),
      ]),
    );
  }
}

String _initials(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  if (parts.isEmpty) return '?';
  if (parts.length == 1) return parts.first.substring(0, parts.first.length.clamp(0, 2)).toUpperCase();
  return (parts.first[0] + parts.last[0]).toUpperCase();
}

String _methodLabel(String m) {
  switch (m) {
    case 'bank': return 'Bank transfer';
    case 'cash': return 'Cash';
    case 'other': return 'Other';
  }
  return m;
}
