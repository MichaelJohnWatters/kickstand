// Admin Audit Log — searchable timeline of every authenticated mutation.
//
// The data is written by the httpapi audit middleware (one row per
// POST/PUT/PATCH/DELETE through the server). This screen renders it
// in `at DESC` order with a thin filter row + pagination.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/empty_state.dart';

class _Filter {
  final String entity;
  final String actor;
  const _Filter({this.entity = '', this.actor = ''});
  _Filter copy({String? entity, String? actor}) => _Filter(
        entity: entity ?? this.entity,
        actor: actor ?? this.actor,
      );
}

// Non-autoDispose so the audit page survives a tab switch with its
// filter + paging intact (and silent-refreshes cached data via
// refresh.dart instead of throwing up a spinner on every visit).
final _filterProvider = StateProvider<_Filter>((_) => const _Filter());
final _pageProvider = StateProvider<int>((_) => 0);
const _pageSize = 50;

final auditPageProvider = FutureProvider<AuditPage>((ref) async {
  final f = ref.watch(_filterProvider);
  final page = ref.watch(_pageProvider);
  return ref.read(apiClientProvider).listAudit(
        entity: f.entity.isEmpty ? null : f.entity,
        actor: f.actor.isEmpty ? null : f.actor,
        limit: _pageSize,
        offset: page * _pageSize,
      );
});

class AdminAuditScreen extends ConsumerWidget {
  const AdminAuditScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(auditPageProvider);
    final filter = ref.watch(_filterProvider);
    final page = ref.watch(_pageProvider);
    final total = async.valueOrNull?.total ?? 0;

    return RefreshIndicator(
      color: KsColors.primary,
      onRefresh: () async => ref.invalidate(auditPageProvider),
      child: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Audit log',
              style: GoogleFonts.plusJakartaSans(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: KsColors.ink,
                  letterSpacing: -0.6)),
          const SizedBox(height: 4),
          Text(
            total == 0
                ? 'Every authenticated mutation lands here.'
                : '$total event${total == 1 ? '' : 's'} in this view.',
            style: const TextStyle(color: KsColors.ink3, fontSize: 13),
          ),
          const SizedBox(height: 18),
          _FilterBar(
            filter: filter,
            onChanged: (f) {
              ref.read(_filterProvider.notifier).state = f;
              ref.read(_pageProvider.notifier).state = 0;
            },
          ),
          const SizedBox(height: 14),
          async.when(
            loading: () => const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(
                  child: CircularProgressIndicator(color: KsColors.primary)),
            ),
            error: (e, _) => KsEmptyState.error(
              title: 'Couldn’t load activity',
              message: e.toString(),
            ),
            data: (data) {
              if (data.entries.isEmpty) {
                return _EmptyState(filter: filter);
              }
              return Container(
                decoration: BoxDecoration(
                  color: KsColors.surface,
                  borderRadius: BorderRadius.circular(KsRadius.lg),
                  border: Border.all(color: KsColors.border),
                  boxShadow: KsShadows.sh1,
                ),
                clipBehavior: Clip.antiAlias,
                child: Column(children: [
                  _HeaderRow(),
                  for (var i = 0; i < data.entries.length; i++)
                    _EntryRow(
                      entry: data.entries[i],
                      last: i == data.entries.length - 1,
                    ),
                ]),
              );
            },
          ),
          if (total > _pageSize) ...[
            const SizedBox(height: 14),
            _Pager(
              page: page,
              total: total,
              onPrev: page == 0
                  ? null
                  : () => ref.read(_pageProvider.notifier).state = page - 1,
              onNext: (page + 1) * _pageSize >= total
                  ? null
                  : () => ref.read(_pageProvider.notifier).state = page + 1,
            ),
          ],
        ],
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  final _Filter filter;
  final ValueChanged<_Filter> onChanged;
  const _FilterBar({required this.filter, required this.onChanged});

  static const _entities = <(String, String)>[
    ('', 'All entities'),
    ('students', 'Students'),
    ('bikes', 'Bikes'),
    ('bookings', 'Bookings'),
    ('instructors', 'Instructors'),
    ('locations', 'Locations'),
    ('course-types', 'Course types'),
    ('school', 'School settings'),
    ('signups', 'Sign-ups'),
    ('expenses', 'Expenses'),
    ('disruptions', 'Disruptions'),
  ];

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        for (final (key, label) in _entities)
          Padding(
            padding: const EdgeInsets.only(right: 6),
            child: _Chip(
              label: label,
              selected: filter.entity == key,
              onTap: () => onChanged(filter.copy(entity: key)),
            ),
          ),
      ]),
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip({required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(KsRadius.pill),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? KsColors.primary : KsColors.surface,
          borderRadius: BorderRadius.circular(KsRadius.pill),
          border: Border.all(
            color: selected ? KsColors.primary : KsColors.border,
          ),
        ),
        child: Text(label,
            style: TextStyle(
              color: selected ? Colors.white : KsColors.ink2,
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
            )),
      ),
    );
  }
}

class _HeaderRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      // Left pad matches the stripe + icon circle (3 + 13 + 28 + 12) so
      // the "Activity" column lines up over the entry text below.
      padding: const EdgeInsets.fromLTRB(56, 11, 16, 11),
      decoration: const BoxDecoration(
        color: KsColors.surface2,
        border: Border(bottom: BorderSide(color: KsColors.border)),
      ),
      child: Row(children: const [
        Expanded(child: _Col('Activity')),
        SizedBox(width: 110, child: _Col('When')),
        SizedBox(width: 130, child: _Col('Result')),
      ]),
    );
  }
}

class _Col extends StatelessWidget {
  final String label;
  const _Col(this.label);
  @override
  Widget build(BuildContext context) => Text(label.toUpperCase(),
      style: GoogleFonts.plusJakartaSans(
          color: KsColors.ink3,
          fontSize: 11,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.5));
}

class _EntryRow extends StatelessWidget {
  final AuditEntry entry;
  final bool last;
  const _EntryRow({required this.entry, required this.last});

  @override
  Widget build(BuildContext context) {
    final actor = entry.actorName.isEmpty ? 'Someone' : entry.actorName;
    final relative = _relativeAge(entry.at);
    final absolute = DateFormat('d MMM HH:mm').format(entry.at);
    final detailPath = entry.pathPattern.isEmpty ? '' : entry.pathPattern;
    final detail = detailPath.isEmpty
        ? entry.method
        : '${entry.method} $detailPath';
    // Prefer the server-set summary (richer context). Fall back to
    // the verb-mapping lookup for routes the backend hasn't enriched
    // yet — still beats the raw HTTP line for the school owner.
    final useSummary = entry.summary.isNotEmpty;
    final phrase = useSummary
        ? const _Phrase('', '') // unused
        : _humanPhrase(entry);
    final visuals = _entityVisuals(entry.targetEntity);
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: last
              ? BorderSide.none
              : const BorderSide(color: KsColors.border),
          // Coloured left stripe by entity — gives the row at-a-glance
          // type recognition when the owner is scrolling a long list.
          left: BorderSide(color: visuals.colour, width: 3),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(13, 12, 16, 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        Container(
          width: 28,
          height: 28,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            color: visuals.colour.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(KsRadius.pill),
          ),
          alignment: Alignment.center,
          child: Icon(visuals.icon, size: 15, color: visuals.colour),
        ),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Headline sentence. If the backend handler set a
                // summary, render that verbatim with the actor in
                // bold; otherwise fall back to verb+target.
                if (useSummary)
                  _SummarySentence(
                    actor: actor,
                    role: entry.actorRole,
                    summary: entry.summary,
                    failed: !entry.succeeded,
                  )
                else
                  _Sentence(
                    actor: actor,
                    role: entry.actorRole,
                    verb: phrase.verb,
                    target: phrase.target,
                    failed: !entry.succeeded,
                  ),
                const SizedBox(height: 4),
                // Subtitle: raw method+path (for power users). Hidden
                // when the verb fully covers what happened.
                Text(detail,
                    style: ksMono(size: 11)
                        .copyWith(color: KsColors.ink4),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ]),
        ),
        SizedBox(
          width: 110,
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(relative,
                    style: GoogleFonts.plusJakartaSans(
                        fontWeight: FontWeight.w700,
                        fontSize: 12.5,
                        color: KsColors.ink2)),
                const SizedBox(height: 2),
                Text(absolute,
                    style: const TextStyle(
                        color: KsColors.ink3, fontSize: 11)),
              ]),
        ),
        SizedBox(
          width: 130,
          child: _StatusBadge(entry: entry),
        ),
      ]),
    );
  }
}

/// Renders a server-supplied summary as "Actor [role-pill] [summary]".
/// The handler already wrote the verb and the target into the
/// summary string, so we just attach the actor headline.
class _SummarySentence extends StatelessWidget {
  final String actor;
  final String role;
  final String summary;
  final bool failed;
  const _SummarySentence({
    required this.actor,
    required this.role,
    required this.summary,
    required this.failed,
  });

  @override
  Widget build(BuildContext context) {
    final base = GoogleFonts.plusJakartaSans(
        fontSize: 13.5, color: KsColors.ink, height: 1.35);
    final emphasised = base.copyWith(fontWeight: FontWeight.w800);
    final attempt = failed ? ' tried to: ' : ' ';
    // Lowercase first letter so "Owen … took bike X offline" reads
    // naturally — backend summaries are written as sentences ("Took
    // bike X offline") to be readable on their own too.
    final phrased = summary.isEmpty
        ? summary
        : summary[0].toLowerCase() + summary.substring(1);
    return RichText(
      text: TextSpan(style: base, children: [
        TextSpan(text: actor, style: emphasised),
        const WidgetSpan(child: SizedBox(width: 6)),
        WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _RolePill(role: role)),
        TextSpan(text: attempt),
        TextSpan(text: phrased),
      ]),
    );
  }
}

/// Renders "Owen O'Neill added a new bike — Honda CB650R" as a single
/// flowing TextSpan so the target word ends up emphasised but the
/// whole line wraps naturally.
class _Sentence extends StatelessWidget {
  final String actor;
  final String role;
  final String verb;
  final String target;
  final bool failed;
  const _Sentence({
    required this.actor,
    required this.role,
    required this.verb,
    required this.target,
    required this.failed,
  });

  @override
  Widget build(BuildContext context) {
    final base = GoogleFonts.plusJakartaSans(
        fontSize: 13.5, color: KsColors.ink, height: 1.35);
    final emphasised = base.copyWith(fontWeight: FontWeight.w800);
    final attempt = failed ? ' tried to ' : ' ';
    return RichText(
      text: TextSpan(style: base, children: [
        TextSpan(text: actor, style: emphasised),
        const WidgetSpan(child: SizedBox(width: 6)),
        WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _RolePill(role: role)),
        TextSpan(text: attempt),
        TextSpan(text: verb),
        if (target.isNotEmpty) ...[
          const TextSpan(text: ' — '),
          TextSpan(text: target, style: emphasised),
        ],
      ]),
    );
  }
}

/// Compact coloured pill that identifies the actor's role at a glance:
/// owner → deep purple, admin/manager → indigo, instructor → teal,
/// student → sky blue. Other/unknown roles fall back to a neutral grey
/// so a future role doesn't break the row.
class _RolePill extends StatelessWidget {
  final String role;
  const _RolePill({required this.role});

  @override
  Widget build(BuildContext context) {
    final (fg, bg, label) = _roleVisuals(role);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(KsRadius.pill),
      ),
      child: Text(label,
          style: GoogleFonts.plusJakartaSans(
              color: fg,
              fontWeight: FontWeight.w800,
              fontSize: 10.5,
              letterSpacing: 0.3)),
    );
  }
}

(Color, Color, String) _roleVisuals(String role) {
  switch (role) {
    case 'owner':
      return (const Color(0xFF6D28D9), const Color(0xFFEDE7FB), 'OWNER');
    case 'admin':
      return (KsColors.primaryDeep, KsColors.primaryTint, 'ADMIN');
    case 'instructor':
      return (const Color(0xFF0F766E), const Color(0xFFD4F1EC), 'INSTRUCTOR');
    case 'student':
      return (const Color(0xFF0369A1), const Color(0xFFDCEEFB), 'STUDENT');
  }
  return (KsColors.ink3, KsColors.surface3, role.toUpperCase());
}

/// Result of mapping an audit entry to natural language.
class _Phrase {
  final String verb;   // e.g. "added a new bike"
  final String target; // e.g. "Honda CB650R" (may be empty)
  const _Phrase(this.verb, [this.target = '']);
}

/// Maps (method, pathPattern) → human verb. Missing entries fall back
/// to a generic "performed an action on the entity" — uncommon paths
/// degrade gracefully rather than printing a 404.
_Phrase _humanPhrase(AuditEntry e) {
  final tgt = e.targetLabel.isNotEmpty ? e.targetLabel : e.targetId;
  final key = '${e.method} ${e.pathPattern}';
  final verb = _verbs[key];
  if (verb != null) return _Phrase(verb, tgt);
  // Final fallback: synthesise from the entity name.
  if (e.targetEntity.isEmpty) {
    return _Phrase(e.method.toLowerCase(), tgt);
  }
  final entity = e.targetEntity.replaceAll('-', ' ');
  switch (e.method) {
    case 'POST':
      return _Phrase('added a $entity entry', tgt);
    case 'PUT':
    case 'PATCH':
      return _Phrase('updated $entity', tgt);
    case 'DELETE':
      return _Phrase('removed $entity', tgt);
  }
  return _Phrase('changed $entity', tgt);
}

/// Verb map — keyed by `METHOD /pattern`. Phrasing aims for the
/// school owner's vocabulary, not the API surface. New routes added
/// here should follow the same active-voice style ("did X", not
/// "X was done"). Keep it short — overflow runs into the subtitle.
const _verbs = <String, String>{
  // Bookings
  'POST /bookings': 'booked a session',
  'DELETE /bookings/{id}': 'cancelled a booking',
  'POST /bookings/{id}/reschedule': 'rescheduled a booking',
  // Sessions + waitlist
  'POST /sessions': 'scheduled a new session',
  'POST /sessions/{id}/waitlist': 'joined the waitlist for',
  'DELETE /sessions/{id}/waitlist': 'left the waitlist for',
  // Bikes
  'POST /bikes': 'added a new bike',
  'PUT /bikes/{id}': 'updated bike details',
  'DELETE /bikes/{id}': 'deleted a bike',
  'POST /bikes/{id}/offline': 'took a bike offline',
  'POST /bikes/{id}/restore': 'restored a bike to service',
  'POST /bikes/{id}/move': 'moved a bike',
  'POST /bikes/{id}/mileage': 'recorded mileage for',
  'POST /bikes/{id}/expenses': 'logged maintenance on',
  // Locations
  'POST /locations': 'added a location',
  'PUT /locations/{id}': 'updated a location',
  'DELETE /locations/{id}': 'removed a location',
  'PUT /travel-times': 'updated travel times',
  'DELETE /travel-times/{from}/{to}': 'cleared a travel time',
  // Course types
  'POST /course-types': 'added a course type',
  'PUT /course-types/{id}': 'updated a course type',
  'DELETE /course-types/{id}': 'removed a course type',
  'POST /course-types/{id}/competencies': 'added a competency to',
  'DELETE /competencies/{id}': 'removed a competency',
  // Students
  'POST /students': 'added a student',
  'POST /auth/firebase-signup': 'signed up',
  'POST /students/{id}/charges': 'added a charge for',
  'DELETE /charges/{chargeId}': 'voided a charge',
  'POST /students/{id}/payments': 'recorded a payment for',
  'DELETE /payments/{paymentId}': 'voided a payment',
  'POST /students/{id}/notes': 'added a note about',
  'DELETE /notes/{noteId}': 'removed a note',
  'POST /students/{id}/tests': 'recorded a test result for',
  // Instructors
  'POST /instructors': 'invited an instructor',
  'PUT /instructors/{id}/qualifications': 'updated qualifications for',
  'PUT /instructors/{id}/accreditation': 'updated accreditation for',
  'PUT /instructors/{id}/pay-model': 'updated pay model for',
  'POST /instructors/{id}/earnings': 'recorded earnings for',
  'POST /instructors/{id}/payments': 'paid',
  'DELETE /earnings/{id}': 'voided an earning',
  // Sign-ups
  'POST /signups/{id}/approve': 'approved sign-up',
  'POST /signups/{id}/reject': 'rejected sign-up',
  // Disruptions
  'POST /disruptions/{id}/bookings/{bookingId}/resolve': 'resolved a bike disruption',
  // Expenses
  'POST /me/expenses': 'submitted an expense',
  'DELETE /me/expenses/{id}': 'withdrew an expense',
  'POST /expenses/{id}/approve': 'approved an expense',
  'POST /expenses/{id}/reject': 'rejected an expense',
  'POST /expenses/{id}/reimburse': 'marked an expense reimbursed',
  'PUT /expense-categories': 'updated expense categories',
  // School + compliance
  'PATCH /school': 'updated school settings',
  'PUT /school/insurance': 'updated insurance expiry',
  // Session templates
  'POST /session-templates': 'created a session template',
  'DELETE /session-templates/{id}': 'deleted a session template',
  'POST /session-templates/materialise': 'generated sessions from templates',
  'POST /session-templates/materialisations/{id}/undo': 'undid a generation',
};

/// Colour + icon picked per target entity, so a long audit list is
/// visually grouped at a glance — fleet ops in orange, money in green,
/// people in indigo, etc. Falls back to a neutral grey for entities
/// the backend may add later without breaking the screen.
class _EntityVisuals {
  final Color colour;
  final IconData icon;
  const _EntityVisuals(this.colour, this.icon);
}

const _entityPaletteOps = Color(0xFFE07A1F);          // bikes / fleet
const _entityPaletteMoney = Color(0xFF1F9D6B);         // payments / charges / expenses / earnings
const _entityPaletteBooking = Color(0xFF0EA5E9);       // sessions / bookings / templates
const _entityPalettePeople = Color(0xFF6366F1);        // students / instructors / signups
const _entityPaletteSetup = Color(0xFF9333EA);         // course-types / competencies / locations
const _entityPaletteRisk = Color(0xFFD64242);          // disruptions / incidents
const _entityPaletteMisc = Color(0xFF8786A0);          // fallback (ink3-ish)

_EntityVisuals _entityVisuals(String entity) {
  switch (entity) {
    case 'bikes':
      return const _EntityVisuals(_entityPaletteOps, Icons.two_wheeler);
    case 'students':
      return const _EntityVisuals(_entityPalettePeople, Icons.school_outlined);
    case 'instructors':
      return const _EntityVisuals(_entityPalettePeople, Icons.badge_outlined);
    case 'bookings':
      return const _EntityVisuals(_entityPaletteBooking, Icons.event_available_outlined);
    case 'sessions':
      return const _EntityVisuals(_entityPaletteBooking, Icons.event_outlined);
    case 'session-templates':
      return const _EntityVisuals(_entityPaletteBooking, Icons.copy_all_outlined);
    case 'locations':
      return const _EntityVisuals(_entityPaletteSetup, Icons.place_outlined);
    case 'travel-times':
      return const _EntityVisuals(_entityPaletteSetup, Icons.alt_route_outlined);
    case 'course-types':
      return const _EntityVisuals(_entityPaletteSetup, Icons.menu_book_outlined);
    case 'competencies':
      return const _EntityVisuals(_entityPaletteSetup, Icons.checklist_outlined);
    case 'school':
      return const _EntityVisuals(_entityPaletteSetup, Icons.apartment_outlined);
    case 'signups':
      return const _EntityVisuals(_entityPalettePeople, Icons.how_to_reg_outlined);
    case 'charges':
    case 'payments':
      return const _EntityVisuals(_entityPaletteMoney, Icons.payments_outlined);
    case 'expenses':
    case 'expense-categories':
      return const _EntityVisuals(_entityPaletteMoney, Icons.receipt_long_outlined);
    case 'earnings':
      return const _EntityVisuals(_entityPaletteMoney, Icons.account_balance_wallet_outlined);
    case 'disruptions':
    case 'incidents':
      return const _EntityVisuals(_entityPaletteRisk, Icons.warning_amber_outlined);
    case 'notes':
      return const _EntityVisuals(_entityPaletteMisc, Icons.sticky_note_2_outlined);
    case 'tests':
      return const _EntityVisuals(_entityPaletteRisk, Icons.assignment_outlined);
  }
  return const _EntityVisuals(_entityPaletteMisc, Icons.bolt_outlined);
}

String _relativeAge(DateTime at) {
  final delta = DateTime.now().difference(at);
  if (delta.inSeconds < 60) return 'just now';
  if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
  if (delta.inHours < 24) return '${delta.inHours}h ago';
  if (delta.inDays < 7) return '${delta.inDays}d ago';
  return DateFormat('d MMM').format(at);
}

class _StatusBadge extends StatelessWidget {
  final AuditEntry entry;
  const _StatusBadge({required this.entry});
  @override
  Widget build(BuildContext context) {
    final ok = entry.succeeded;
    final fg = ok ? KsColors.success : KsColors.danger;
    final bg = ok ? KsColors.successTint : KsColors.dangerTint;
    final label = ok
        ? entry.statusCode.toString()
        : '${entry.statusCode} ${entry.errorCode.isEmpty ? '' : '· ${entry.errorCode}'}'.trim();
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
            color: bg, borderRadius: BorderRadius.circular(KsRadius.pill)),
        child: Text(label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.plusJakartaSans(
                color: fg, fontWeight: FontWeight.w700, fontSize: 11)),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final _Filter filter;
  const _EmptyState({required this.filter});
  @override
  Widget build(BuildContext context) {
    final msg = filter.entity.isEmpty
        ? 'No activity recorded yet.'
        : 'No activity for ${filter.entity}.';
    return Container(
      padding: const EdgeInsets.all(40),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.lg),
        border: Border.all(color: KsColors.border),
      ),
      child: Column(children: [
        const Icon(Icons.history, size: 48, color: KsColors.ink4),
        const SizedBox(height: 12),
        Text(msg,
            style: GoogleFonts.plusJakartaSans(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: KsColors.ink)),
      ]),
    );
  }
}

class _Pager extends StatelessWidget {
  final int page;
  final int total;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  const _Pager({
    required this.page,
    required this.total,
    required this.onPrev,
    required this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    final from = page * _pageSize + 1;
    final to = ((page + 1) * _pageSize).clamp(0, total);
    return Row(children: [
      Text('$from–$to of $total',
          style: const TextStyle(color: KsColors.ink3, fontSize: 12.5)),
      const Spacer(),
      OutlinedButton.icon(
        onPressed: onPrev,
        icon: const Icon(Icons.chevron_left, size: 16),
        label: const Text('Previous'),
      ),
      const SizedBox(width: 8),
      OutlinedButton.icon(
        onPressed: onNext,
        icon: const Icon(Icons.chevron_right, size: 16),
        label: const Text('Next'),
      ),
    ]);
  }
}
