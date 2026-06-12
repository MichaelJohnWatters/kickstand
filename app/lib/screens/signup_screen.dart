// Student self-signup screen.
//
// Flow (Phase 4 of firebase-auth-migration.md):
//   1. Pick a school from the public catalog (GET /schools).
//   2. Fill in name, email, password, phone, category, transmission.
//   3. Submit:
//      a. `FirebaseAuth.createUserWithEmailAndPassword(email, password)`
//         — Firebase generates the UID, manages the password.
//      b. `POST /auth/firebase-signup` with the JWT in the Authorization
//         header and the profile body — our Go server writes the local
//         users + student_profiles row keyed on the verified UID.
//      c. `user.sendEmailVerification()` — Google handles the email.
//   4. AuthController's authStateChanges listener fires on (a), our /me
//      lookup picks up the freshly-created row from (b), and the
//      route redirect lands the user at /student (open mode) or the
//      pending-approval landing page (approval mode).

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../api/models.dart';
import '../state/providers.dart';
import '../theme/tokens.dart';

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});
  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _phone = TextEditingController();
  SchoolLite? _school;
  String _category = 'A1';
  String _transmission = 'manual';
  bool _submitting = false;
  String? _error;

  late final Future<List<SchoolLite>> _schoolsFuture =
      ref.read(apiClientProvider).listSchools();

  @override
  void dispose() {
    _name.dispose();
    _email.dispose();
    _password.dispose();
    _phone.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    if (_school == null) {
      setState(() => _error = 'Pick your school first.');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });

    final api = ref.read(apiClientProvider);
    final email = _email.text.trim();
    final password = _password.text;
    User? firebaseUser;
    try {
      // 1. Create the Firebase identity.
      final cred = await FirebaseAuth.instance
          .createUserWithEmailAndPassword(email: email, password: password);
      firebaseUser = cred.user;
      if (firebaseUser == null) {
        throw FirebaseAuthException(
            code: 'no-user', message: 'Could not create account.');
      }
      // 2. Force a fresh ID token so the Dio interceptor picks it up on
      //    the very next request. (Without this the supplier might still
      //    be holding a stale `null` from before `createUser` resolved.)
      await firebaseUser.getIdToken(true);

      // 3. Write the local profile row.
      await api.firebaseSignup(
        schoolId: _school!.id,
        name: _name.text.trim(),
        email: email,
        phone: _phone.text.trim(),
        transmissionPreference: _transmission,
        licenceCategoryPursued: _category,
      );

      // 4. Best-effort verification email; non-blocking.
      try {
        await firebaseUser.sendEmailVerification();
      } catch (_) {}

      // 5. AuthController's authStateChanges listener has already fired
      //    or will any moment now — it loads /me and the router gate
      //    redirects to the role landing. Nothing else to do here.
    } on FirebaseAuthException catch (e) {
      setState(() {
        _error = _humanFirebaseError(e.code);
        _submitting = false;
      });
    } on ApiException catch (e) {
      // Profile-write failed — roll back the Firebase user so the email
      // is free for a retry.
      if (firebaseUser != null) {
        try {
          await firebaseUser.delete();
        } catch (_) {}
      }
      setState(() {
        _error = e.message;
        _submitting = false;
      });
    } catch (e) {
      if (firebaseUser != null) {
        try {
          await firebaseUser.delete();
        } catch (_) {}
      }
      setState(() {
        _error = 'Could not complete signup. Try again.';
        _submitting = false;
      });
    }
  }

  String _humanFirebaseError(String code) {
    switch (code) {
      case 'email-already-in-use':
        return 'An account with that email already exists. Try signing in.';
      case 'invalid-email':
        return 'That doesn’t look like a valid email.';
      case 'weak-password':
        return 'Pick a stronger password (8+ characters).';
      case 'network-request-failed':
        return 'Couldn’t reach the server. Check your connection.';
      default:
        return 'Could not create account. Try again.';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: KsColors.bg,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/welcome'),
        ),
        backgroundColor: KsColors.surface,
        elevation: 0,
      ),
      body: SafeArea(
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(22, 8, 22, 24),
            children: [
              Text('Create your account',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: KsColors.ink,
                      letterSpacing: -0.6)),
              const SizedBox(height: 4),
              const Text(
                'Pick your school, tell us a bit about you, and we’ll get you set up.',
                style: TextStyle(color: KsColors.ink3, fontSize: 13.5),
              ),
              const SizedBox(height: 20),

              _label('School'),
              FutureBuilder<List<SchoolLite>>(
                future: _schoolsFuture,
                builder: (ctx, snap) {
                  if (snap.connectionState != ConnectionState.done) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: LinearProgressIndicator(color: KsColors.primary),
                    );
                  }
                  if (snap.hasError || (snap.data ?? []).isEmpty) {
                    return Text('Couldn’t load schools: ${snap.error ?? 'empty list'}',
                        style: const TextStyle(color: KsColors.danger));
                  }
                  return DropdownButtonFormField<SchoolLite>(
                    initialValue: _school,
                    decoration: const InputDecoration(
                        hintText: 'Pick your training school'),
                    items: snap.data!
                        .map((s) => DropdownMenuItem(
                              value: s,
                              child: Text('${s.name} · ${s.region}'),
                            ))
                        .toList(),
                    onChanged: (v) => setState(() => _school = v),
                  );
                },
              ),
              const SizedBox(height: 16),

              _label('Full name'),
              TextFormField(
                controller: _name,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(hintText: 'Jordan Reid'),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Name required.' : null,
              ),
              const SizedBox(height: 14),

              _label('Email'),
              TextFormField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: const InputDecoration(hintText: 'you@example.com'),
                validator: (v) {
                  final s = v?.trim() ?? '';
                  if (s.isEmpty) return 'Email required.';
                  if (!s.contains('@') || !s.contains('.')) {
                    return 'That doesn’t look like a valid email.';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 14),

              _label('Password'),
              TextFormField(
                controller: _password,
                obscureText: true,
                decoration: const InputDecoration(hintText: 'At least 8 characters'),
                validator: (v) =>
                    (v?.length ?? 0) < 8 ? 'At least 8 characters.' : null,
              ),
              const SizedBox(height: 14),

              _label('Phone (optional)'),
              TextFormField(
                controller: _phone,
                keyboardType: TextInputType.phone,
                decoration: const InputDecoration(hintText: '07700 900 000'),
              ),
              const SizedBox(height: 18),

              _label('Licence you’re pursuing'),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'A1', label: Text('A1 (125 cc)')),
                  ButtonSegment(value: 'A2', label: Text('A2 (650 cc)')),
                  ButtonSegment(value: 'A', label: Text('A (full)')),
                ],
                selected: {_category},
                onSelectionChanged: (s) => setState(() => _category = s.first),
              ),
              const SizedBox(height: 18),

              _label('Transmission'),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'manual', label: Text('Manual')),
                  ButtonSegment(value: 'auto', label: Text('Auto')),
                ],
                selected: {_transmission},
                onSelectionChanged: (s) => setState(() => _transmission = s.first),
              ),

              if (_error != null) ...[
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: KsColors.dangerTint,
                    borderRadius: BorderRadius.circular(KsRadius.md),
                  ),
                  child: Text(_error!,
                      style: const TextStyle(color: KsColors.danger)),
                ),
              ],
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _submitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(KsRadius.md)),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                              color: Colors.white, strokeWidth: 2.5))
                      : const Text('Create account'),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Text('Already have an account?',
                      style: TextStyle(color: KsColors.ink3)),
                  TextButton(
                    onPressed: () => context.go('/login'),
                    child: const Text('Sign in'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6, top: 4),
        child: Text(text,
            style: const TextStyle(
                color: KsColors.ink2,
                fontWeight: FontWeight.w800,
                fontSize: 13)),
      );
}
