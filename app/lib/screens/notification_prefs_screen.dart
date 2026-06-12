// Notification preferences — per-category × per-channel opt-outs.
// Plan §10b: separate routine reminders from urgent issues so users
// can mute the noise without missing safety-relevant alerts.
//
// Channel reality today: in-app is live; email / push / SMS are
// stored but not delivered (FCM + SMS provider land in Phase 2).
// The screen flags the upcoming channels honestly so users aren't
// fooled into thinking they're enabled.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';
import '../widgets/empty_state.dart';

class NotificationPrefsScreen extends ConsumerStatefulWidget {
  const NotificationPrefsScreen({super.key});

  @override
  ConsumerState<NotificationPrefsScreen> createState() =>
      _NotificationPrefsScreenState();
}

class _NotificationPrefsScreenState
    extends ConsumerState<NotificationPrefsScreen> {
  // Local editable copy so toggles feel instant; we PUT on every flip
  // and the server is the source of truth.
  List<NotificationPrefs>? _local;
  bool _saving = false;

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(notificationPrefsProvider);
    return Scaffold(
      backgroundColor: KsColors.bg,
      appBar: AppBar(
        title: Text('Notification preferences',
            style: GoogleFonts.plusJakartaSans(
                fontWeight: FontWeight.w800, fontSize: 20)),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: KsColors.ink),
          onPressed: () => context.pop(),
        ),
      ),
      body: async.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: KsColors.primary)),
        error: (e, _) => KsEmptyState.error(message: e.toString()),
        data: (prefs) {
          _local ??= List.of(prefs);
          return _Body(
            prefs: _local!,
            saving: _saving,
            onToggle: _onToggle,
          );
        },
      ),
    );
  }

  Future<void> _onToggle(int index, NotificationPrefs updated) async {
    final previous = _local![index];
    setState(() {
      _local![index] = updated;
      _saving = true;
    });
    try {
      await ref.read(apiClientProvider).updateNotificationPrefs(_local!);
      ref.invalidate(notificationPrefsProvider);
    } catch (e) {
      // Roll back the local toggle and surface the error.
      setState(() => _local![index] = previous);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Couldn't save: $e")),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _Body extends StatelessWidget {
  final List<NotificationPrefs> prefs;
  final bool saving;
  final Future<void> Function(int index, NotificationPrefs updated) onToggle;
  const _Body({
    required this.prefs,
    required this.saving,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Choose which notifications you want to receive. In-app is live now; '
          'email, push and SMS are saved and will switch on automatically when '
          'we light up those channels.',
          style: GoogleFonts.plusJakartaSans(
              color: KsColors.ink2, fontSize: 13),
        ),
        const SizedBox(height: 14),
        for (var i = 0; i < prefs.length; i++)
          _CategoryCard(
            pref: prefs[i],
            onChanged: (updated) => onToggle(i, updated),
          ),
        if (saving)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text('Saving…',
                  style: TextStyle(color: KsColors.ink3, fontSize: 12)),
            ),
          ),
      ],
    );
  }
}

class _CategoryCard extends StatelessWidget {
  final NotificationPrefs pref;
  final ValueChanged<NotificationPrefs> onChanged;
  const _CategoryCard({required this.pref, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: KsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            _categoryIcon(pref.category),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_categoryLabel(pref.category),
                      style: GoogleFonts.plusJakartaSans(
                          fontWeight: FontWeight.w700, color: KsColors.ink)),
                  Text(_categoryHint(pref.category),
                      style: const TextStyle(
                          color: KsColors.ink3, fontSize: 12)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: 12),
          _ChannelRow(
            label: 'In-app',
            value: pref.inApp,
            onChanged: (v) => onChanged(pref.copyWith(inApp: v)),
          ),
          _ChannelRow(
            label: 'Email',
            value: pref.email,
            comingSoon: true,
            onChanged: (v) => onChanged(pref.copyWith(email: v)),
          ),
          _ChannelRow(
            label: 'Push',
            value: pref.push,
            comingSoon: true,
            onChanged: (v) => onChanged(pref.copyWith(push: v)),
          ),
          _ChannelRow(
            label: 'SMS',
            value: pref.sms,
            comingSoon: true,
            onChanged: (v) => onChanged(pref.copyWith(sms: v)),
          ),
        ],
      ),
    );
  }
}

class _ChannelRow extends StatelessWidget {
  final String label;
  final bool value;
  final bool comingSoon;
  final ValueChanged<bool> onChanged;
  const _ChannelRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.comingSoon = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(children: [
        Text(label,
            style: const TextStyle(
                color: KsColors.ink, fontWeight: FontWeight.w600)),
        if (comingSoon) ...[
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: KsColors.surface3,
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Text('Coming soon',
                style: TextStyle(
                    color: KsColors.ink3,
                    fontSize: 10,
                    fontWeight: FontWeight.w600)),
          ),
        ],
        const Spacer(),
        Switch(
          value: value,
          activeThumbColor: KsColors.primary,
          onChanged: onChanged,
        ),
      ]),
    );
  }
}

Widget _categoryIcon(String category) {
  IconData iconData;
  Color colour;
  switch (category) {
    case 'booking':
      iconData = Icons.event_available_outlined;
      colour = KsColors.primary;
      break;
    case 'disruption':
      iconData = Icons.report_outlined;
      colour = KsColors.warning;
      break;
    case 'payment':
      iconData = Icons.payments_outlined;
      colour = KsColors.success;
      break;
    case 'reminder':
      iconData = Icons.alarm;
      colour = KsColors.ink2;
      break;
    default:
      iconData = Icons.notifications_none;
      colour = KsColors.ink3;
  }
  return Container(
    width: 32,
    height: 32,
    decoration: BoxDecoration(
      color: colour.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Icon(iconData, color: colour, size: 18),
  );
}

String _categoryLabel(String category) {
  switch (category) {
    case 'booking':
      return 'Booking activity';
    case 'disruption':
      return 'Disruptions';
    case 'payment':
      return 'Payments';
    case 'reminder':
      return 'Session reminders';
    default:
      return category;
  }
}

String _categoryHint(String category) {
  switch (category) {
    case 'booking':
      return 'Confirmations, cancellations, reschedules.';
    case 'disruption':
      return 'Bike issues affecting your session.';
    case 'payment':
      return 'Charges, payments, balances.';
    case 'reminder':
      return '24 h and 2 h before-session pings.';
    default:
      return '';
  }
}
