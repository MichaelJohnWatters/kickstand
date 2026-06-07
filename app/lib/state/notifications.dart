// Notifications state — polls /me/notifications and exposes the unread count
// so the bell badge can react in real time.
//
// Polling is the MVP delivery model; once FCM is wired we'd push refreshes
// here on receipt of a foreground message.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'providers.dart';

class NotificationsState {
  final List<AppNotification> notifications;
  final int unreadCount;
  final bool loading;
  final String? error;
  const NotificationsState({
    required this.notifications,
    required this.unreadCount,
    required this.loading,
    this.error,
  });

  factory NotificationsState.initial() =>
      const NotificationsState(notifications: [], unreadCount: 0, loading: false);

  NotificationsState copyWith({
    List<AppNotification>? notifications,
    int? unreadCount,
    bool? loading,
    String? error,
  }) =>
      NotificationsState(
        notifications: notifications ?? this.notifications,
        unreadCount: unreadCount ?? this.unreadCount,
        loading: loading ?? this.loading,
        error: error,
      );
}

class NotificationsController extends StateNotifier<NotificationsState> {
  final ApiClient _api;
  final Ref _ref;
  Timer? _ticker;
  NotificationsController(this._api, this._ref)
      : super(NotificationsState.initial()) {
    refresh();
    // Poll every 60s while signed in. The bell badge updates without
    // user-driven refreshes; foreground FCM later replaces this.
    _ticker = Timer.periodic(const Duration(seconds: 60), (_) => refresh());
  }

  Future<void> refresh() async {
    // Skip the poll until auth is resolved — otherwise pre-login ticks and
    // post-signout ticks fire 401s into the network panel for no reason.
    if (!_ref.read(authControllerProvider).isSignedIn) return;
    try {
      state = state.copyWith(loading: true, error: null);
      final res = await _api.listNotifications();
      state = NotificationsState(
        notifications: res.notifications,
        unreadCount: res.unreadCount,
        loading: false,
      );
    } catch (e) {
      state = state.copyWith(loading: false, error: e.toString());
    }
  }

  Future<void> markRead(String id) async {
    // Optimistic: drop unread count immediately so the badge feels responsive.
    final updated = state.notifications
        .map<AppNotification>((AppNotification n) => n.id == id
            ? AppNotification(
                id: n.id, eventId: n.eventId, eventKind: n.eventKind,
                category: n.category, status: 'read',
                sentAt: n.sentAt, readAt: DateTime.now(), payload: n.payload,
              )
            : n)
        .toList();
    final newUnread = updated.where((n) => !n.isRead).length;
    state = state.copyWith(notifications: updated, unreadCount: newUnread);
    try {
      await _api.markNotificationRead(id);
    } catch (_) {
      // Roll back by re-fetching if the server disagrees.
      await refresh();
    }
  }

  Future<void> markAllRead() async {
    final updated = state.notifications
        .map<AppNotification>((AppNotification n) => AppNotification(
              id: n.id, eventId: n.eventId, eventKind: n.eventKind,
              category: n.category, status: 'read',
              sentAt: n.sentAt, readAt: DateTime.now(), payload: n.payload,
            ))
        .toList();
    state = state.copyWith(notifications: updated, unreadCount: 0);
    try {
      await _api.markAllNotificationsRead();
    } catch (_) {
      await refresh();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }
}

final notificationsControllerProvider =
    StateNotifierProvider<NotificationsController, NotificationsState>((ref) {
  return NotificationsController(ref.read(apiClientProvider), ref);
});
