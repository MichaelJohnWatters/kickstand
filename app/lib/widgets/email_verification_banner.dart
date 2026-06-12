// Verify-your-email banner.
//
// Phase 5 of firebase-auth-migration.md. Sits at the top of every role
// shell. Shown when:
//   - There's a signed-in Firebase user
//   - The user's emailVerified flag is false
//   - The user hasn't dismissed it in this app session
//
// Actions:
//   - "Resend email"  → user.sendEmailVerification(); 60 s cooldown.
//   - "I've verified" → user.reload() then read emailVerified again. If
//     still false, show a hint that the email hasn't been clicked yet.
//
// Why dismissible: the Firebase Auth Emulator marks users unverified
// but doesn't actually send mail, so during dev/demo the banner would
// otherwise sit on every screen forever. Memory-only dismissal — it
// comes back next launch until the user actually verifies.

import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../state/demo_mode.dart';
import '../theme/tokens.dart';

/// Session-only dismissal flag. We don't persist it: if you ignore the
/// banner today, you'll see it tomorrow — which is the right behaviour
/// for something that protects your account.
final emailBannerDismissedProvider = StateProvider<bool>((_) => false);

class EmailVerificationBanner extends ConsumerStatefulWidget {
  const EmailVerificationBanner({super.key});

  @override
  ConsumerState<EmailVerificationBanner> createState() =>
      _EmailVerificationBannerState();
}

class _EmailVerificationBannerState
    extends ConsumerState<EmailVerificationBanner> {
  bool _sending = false;
  bool _checking = false;
  int _cooldown = 0;
  String? _flash;
  Timer? _cooldownTimer;
  StreamSubscription<User?>? _userSub;
  User? _user;

  @override
  void initState() {
    super.initState();
    if (kDemoMode) {
      // Demo build — Firebase isn't initialised. Skip the subscription;
      // build() short-circuits to SizedBox.shrink() anyway.
      return;
    }
    _user = FirebaseAuth.instance.currentUser;
    // userChanges fires on emailVerified flips too (unlike authStateChanges).
    _userSub = FirebaseAuth.instance.userChanges().listen((u) {
      if (!mounted) return;
      setState(() => _user = u);
    });
  }

  @override
  void dispose() {
    _cooldownTimer?.cancel();
    _userSub?.cancel();
    super.dispose();
  }

  Future<void> _resend() async {
    final user = _user;
    if (user == null || _sending || _cooldown > 0) return;
    setState(() {
      _sending = true;
      _flash = null;
    });
    try {
      await user.sendEmailVerification();
      if (!mounted) return;
      setState(() {
        _flash = 'Verification email sent. Check your inbox.';
        _cooldown = 60;
      });
      _cooldownTimer?.cancel();
      _cooldownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() {
          _cooldown -= 1;
          if (_cooldown <= 0) t.cancel();
        });
      });
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _flash = e.code == 'too-many-requests'
            ? 'Too many requests. Try again in a minute.'
            : 'Could not send email. Try again.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _flash = 'Could not send email. Try again.');
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  Future<void> _checkVerified() async {
    final user = _user;
    if (user == null || _checking) return;
    setState(() {
      _checking = true;
      _flash = null;
    });
    try {
      await user.reload();
      final fresh = FirebaseAuth.instance.currentUser;
      if (!mounted) return;
      if (fresh?.emailVerified ?? false) {
        // Banner will self-hide on the next userChanges tick. No flash
        // needed — disappearing is the success signal.
      } else {
        setState(() =>
            _flash = 'Still unverified. Click the link in the email first.');
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _flash = 'Could not check status. Try again.');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = _user;
    final dismissed = ref.watch(emailBannerDismissedProvider);
    if (user == null || user.emailVerified || dismissed) {
      return const SizedBox.shrink();
    }
    final tight = MediaQuery.of(context).size.width < 600;

    return Material(
      color: KsColors.warningTint,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(Icons.mark_email_unread_outlined,
                color: KsColors.warning, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Verify your email (${user.email ?? 'check your inbox'})',
                    style: const TextStyle(
                      color: KsColors.ink,
                      fontWeight: FontWeight.w700,
                      fontSize: 13.5,
                    ),
                  ),
                  if (_flash != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(_flash!,
                          style: const TextStyle(
                              color: KsColors.ink2, fontSize: 12)),
                    )
                  else if (!tight)
                    const Padding(
                      padding: EdgeInsets.only(top: 2),
                      child: Text(
                        'We sent a link when you signed up. Click it to confirm this is you.',
                        style: TextStyle(color: KsColors.ink2, fontSize: 12),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: (_sending || _cooldown > 0) ? null : _resend,
              style: TextButton.styleFrom(
                foregroundColor: KsColors.primaryDeep,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 36),
              ),
              child: _sending
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(_cooldown > 0
                      ? 'Resend (${_cooldown}s)'
                      : 'Resend'),
            ),
            TextButton(
              onPressed: _checking ? null : _checkVerified,
              style: TextButton.styleFrom(
                foregroundColor: KsColors.primaryDeep,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: const Size(0, 36),
              ),
              child: _checking
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('I’ve verified'),
            ),
            IconButton(
              tooltip: 'Hide for now',
              icon: const Icon(Icons.close, size: 18, color: KsColors.ink3),
              onPressed: () => ref
                  .read(emailBannerDismissedProvider.notifier)
                  .state = true,
            ),
          ],
        ),
      ),
    );
  }
}
