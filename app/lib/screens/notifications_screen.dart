// Notification centre — list of recent notifications with mark-read and
// mark-all-read.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/notifications.dart';
import '../theme/tokens.dart';

class NotificationsScreen extends ConsumerWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(notificationsControllerProvider);
    final controller = ref.read(notificationsControllerProvider.notifier);

    return Scaffold(
      backgroundColor: KsColors.bg,
      appBar: AppBar(
        title: Text('Notifications',
            style: GoogleFonts.plusJakartaSans(fontWeight: FontWeight.w800, fontSize: 22)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: KsColors.ink),
          onPressed: () => context.pop(),
        ),
        actions: [
          if (state.unreadCount > 0)
            TextButton(
              onPressed: controller.markAllRead,
              child: Text('Mark all read',
                  style: GoogleFonts.plusJakartaSans(color: KsColors.primary, fontWeight: FontWeight.w700)),
            ),
        ],
      ),
      body: RefreshIndicator(
        color: KsColors.primary,
        onRefresh: controller.refresh,
        child: state.notifications.isEmpty
            ? ListView(children: const [_EmptyState()])
            : ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: state.notifications.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (ctx, i) => _NotifTile(state.notifications[i], onRead: controller.markRead),
              ),
      ),
    );
  }
}

class _NotifTile extends StatelessWidget {
  final AppNotification n;
  final Future<void> Function(String) onRead;
  const _NotifTile(this.n, {required this.onRead});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: n.isRead ? null : () => onRead(n.id),
      borderRadius: BorderRadius.circular(KsRadius.lg),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: n.isRead ? KsColors.surface : KsColors.primaryTint,
          borderRadius: BorderRadius.circular(KsRadius.lg),
          border: Border.all(color: n.isRead ? KsColors.border : KsColors.primary.withValues(alpha: 0.25)),
          boxShadow: n.isRead ? KsShadows.sh1 : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _categoryIcon(n.category),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_title(n),
                      style: GoogleFonts.plusJakartaSans(
                          color: KsColors.ink, fontWeight: FontWeight.w700, fontSize: 14)),
                  if (_body(n).isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(_body(n), style: const TextStyle(color: KsColors.ink2, fontSize: 13)),
                  ],
                  const SizedBox(height: 6),
                  Text(DateFormat('d MMM · HH:mm').format(n.sentAt),
                      style: const TextStyle(color: KsColors.ink3, fontSize: 11)),
                ],
              ),
            ),
            if (!n.isRead) ...[
              const SizedBox(width: 8),
              Container(
                width: 8, height: 8,
                margin: const EdgeInsets.only(top: 6),
                decoration: const BoxDecoration(color: KsColors.primary, shape: BoxShape.circle),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _categoryIcon(String c) {
    late IconData icon;
    late Color color;
    switch (c) {
      case 'disruption': icon = Icons.report_outlined; color = KsColors.warning; break;
      case 'payment': icon = Icons.payments_outlined; color = KsColors.primary; break;
      case 'reminder': icon = Icons.alarm; color = KsColors.primary; break;
      default: icon = Icons.event_note_outlined; color = KsColors.primary;
    }
    return Container(
      width: 36, height: 36,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(KsRadius.sm),
      ),
      child: Icon(icon, color: color, size: 18),
    );
  }

  /// Friendly heading per event kind. Falls back to the kind itself.
  String _title(AppNotification n) {
    final p = n.payload;
    switch (n.eventKind) {
      case 'booking.created':
        return 'Booking confirmed';
      case 'booking.cancelled':
        return 'Booking cancelled';
      case 'booking.rescheduled':
        return 'Booking rescheduled';
      case 'bike.offline':
        return 'A bike is down · ${p['affectedCount'] ?? 0} affected';
      case 'disruption.affected_booking':
        return 'Your booking needs reassignment';
      case 'disruption.resolved':
        return p['resolution'] == 'swapped' ? 'Bike swapped for your booking' : 'Booking cancelled (bike issue)';
    }
    return n.eventKind;
  }

  String _body(AppNotification n) {
    final p = n.payload;
    if (p['courseName'] != null) return p['courseName'].toString();
    if (p['newCourseName'] != null) return p['newCourseName'].toString();
    return '';
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 80, 32, 24),
      child: Column(
        children: [
          const Icon(Icons.notifications_none_rounded, size: 56, color: KsColors.ink4),
          const SizedBox(height: 12),
          Text('No notifications yet',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 16, fontWeight: FontWeight.w700, color: KsColors.ink)),
          const SizedBox(height: 4),
          const Text(
            'Confirmations, reminders, and changes will show up here.',
            textAlign: TextAlign.center, style: TextStyle(color: KsColors.ink2),
          ),
        ],
      ),
    );
  }
}
