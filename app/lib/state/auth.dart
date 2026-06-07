// Auth state: token + identity, with disk persistence.
//
// AuthState has three observable shapes:
//   - loading: app just started, we're checking the secure store
//   - signedOut: no token, or token invalid
//   - signedIn(identity): we have a valid identity
//
// The ApiClient pulls the token via a supplier so it always sees the
// current value without us rebuilding the client on every state change.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'token_storage.dart';

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
  final TokenStorage _store;
  String? _token;

  AuthController(this._api, this._store) : super(AuthState.loading()) {
    _api.setTokenSupplier(() => _token);
    _restore();
  }

  /// On boot: pull any persisted token and try /me to validate it. A 401
  /// from the server clears the token and lands us at signedOut without an
  /// error message (it's not a failure, the session just expired).
  Future<void> _restore() async {
    try {
      _token = await _store.read();
      if (_token == null || _token!.isEmpty) {
        state = AuthState.signedOut();
        return;
      }
      final id = await _api.me();
      state = AuthState.signedIn(id);
    } on ApiException catch (e) {
      if (e.statusCode == 401) {
        await _store.clear();
        _token = null;
        state = AuthState.signedOut();
      } else {
        state = AuthState.signedOut(error: e.message);
      }
    } catch (e) {
      // Network unreachable etc — surface gently and let them retry.
      state = AuthState.signedOut(error: 'Could not reach the server: $e');
    }
  }

  Future<void> login(String email, String password) async {
    state = AuthState.loading();
    try {
      final res = await _api.login(email, password);
      _token = res.token;
      await _store.write(res.token);
      state = AuthState.signedIn(res.identity);
    } on ApiException catch (e) {
      // Don't leak which field was wrong — server already obscures that.
      final msg = e.code == 'invalid_credentials'
          ? 'Email or password is incorrect.'
          : e.code == 'account_disabled'
              ? 'This account has been disabled. Contact your school.'
              : e.message;
      state = AuthState.signedOut(error: msg);
    } catch (e) {
      state = AuthState.signedOut(error: 'Could not reach the server.');
      if (kDebugMode) {
        debugPrint('login error: $e');
      }
    }
  }

  Future<void> logout() async {
    try {
      await _api.logout();
    } catch (_) {
      // Even if the call fails (already-expired session), clear locally.
    }
    await _store.clear();
    _token = null;
    state = AuthState.signedOut();
  }
}
