// Auth state: lifecycle wrapper around Firebase Auth.
//
// AuthState has three observable shapes:
//   - loading: app just started, or login in flight
//   - signedOut: no Firebase user, or sign-out triggered
//   - signedIn(identity): Firebase user present AND our /me lookup
//     resolved a local profile row
//
// The Firebase SDK manages token storage + refresh transparently. The
// `apiClientProvider` reads the ID token on every request via
// `getIdToken()`, so this controller doesn't touch tokens directly —
// it only mirrors the SDK's auth-state stream into our app-shaped
// `Identity`.

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'demo_mode.dart';

class AuthState {
  final bool loading;
  final Identity? identity;
  final String? error;

  const AuthState({required this.loading, this.identity, this.error});

  factory AuthState.loading() => const AuthState(loading: true);
  factory AuthState.signedOut({String? error}) => AuthState(loading: false, error: error);
  factory AuthState.signedIn(Identity id) => AuthState(loading: false, identity: id);

  bool get isSignedIn => identity != null;
}

class AuthController extends StateNotifier<AuthState> {
  final ApiClient _api;
  StreamSubscription<User?>? _sub;

  AuthController(this._api) : super(AuthState.loading()) {
    if (kDemoMode) {
      // Demo build — no Firebase. Sit in signed-out until the role
      // picker calls `setDemoIdentity` with the chosen role's seed.
      state = AuthState.signedOut();
      return;
    }
    // Single source of truth: whatever Firebase says about the current
    // session. Restart-survival is automatic — the SDK rehydrates on
    // start and fires this stream with the cached user (or null).
    _sub = FirebaseAuth.instance.authStateChanges().listen(_onAuthChange);
  }

  /// Demo-only — pin the identity returned by MockApiClient. Called
  /// from the role picker once the visitor chooses a tile. Real-mode
  /// callers should never invoke this.
  void setDemoIdentity(Identity id) {
    if (!kDemoMode) return;
    state = AuthState.signedIn(id);
  }

  /// Demo-only — return to the role picker. Used by the "switch role"
  /// affordance.
  void clearDemoIdentity() {
    if (!kDemoMode) return;
    state = AuthState.signedOut();
  }

  Future<void> _onAuthChange(User? user) async {
    if (user == null) {
      state = AuthState.signedOut();
      return;
    }
    try {
      // Fetch our local profile (school_id, role, account_status). This
      // is the same /me endpoint the legacy auth path used.
      final id = await _api.me();
      state = AuthState.signedIn(id);
    } on ApiException catch (e) {
      // The most common path here is a signup race (Firebase user
      // exists but the POST /auth/signup hasn't landed yet). Treat as
      // signed-out with a helpful nudge.
      if (e.code == 'not_found' || e.statusCode == 404) {
        state = AuthState.signedOut(
          error: 'Finishing your account setup… please try logging in again in a moment.',
        );
        await FirebaseAuth.instance.signOut();
        return;
      }
      state = AuthState.signedOut(error: e.message);
    } catch (e) {
      state = AuthState.signedOut(error: 'Could not reach the server.');
      if (kDebugMode) {
        debugPrint('auth /me failed: $e');
      }
    }
  }

  Future<void> login(String email, String password) async {
    state = AuthState.loading();
    try {
      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
      // _onAuthChange will fire and transition us to signedIn.
    } on FirebaseAuthException catch (e) {
      state = AuthState.signedOut(error: _humanError(e.code));
    } catch (e) {
      state = AuthState.signedOut(error: 'Could not reach the server.');
      if (kDebugMode) {
        debugPrint('login error: $e');
      }
    }
  }

  Future<void> logout() async {
    try {
      await FirebaseAuth.instance.signOut();
    } catch (_) {
      // Best-effort. The stream listener will land us at signedOut
      // either way.
    }
  }

  /// Send a password-reset email via Firebase. Returns true on success
  /// so the UI can show "check your inbox" copy.
  Future<bool> sendPasswordReset(String email) async {
    try {
      await FirebaseAuth.instance.sendPasswordResetEmail(email: email.trim());
      return true;
    } on FirebaseAuthException catch (e) {
      // Don't leak existence of an account — same message either way.
      if (e.code == 'user-not-found' || e.code == 'invalid-email') {
        return true;
      }
      return false;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  String _humanError(String code) {
    switch (code) {
      case 'user-not-found':
      case 'wrong-password':
      case 'invalid-credential':
      case 'invalid-email':
        return 'Email or password is incorrect.';
      case 'user-disabled':
        return 'This account has been disabled. Contact your school.';
      case 'too-many-requests':
        return 'Too many sign-in attempts. Try again in a minute.';
      case 'network-request-failed':
        return 'Couldn’t reach the server. Check your connection.';
      default:
        return 'Could not sign in. Try again.';
    }
  }
}
