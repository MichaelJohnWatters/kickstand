// Email + password login. Errors come from the auth controller's state.
//
// In dev we pre-fill with the seeded student credentials so the loop is
// fast — comment those out for any real demo. There's also a dev-only
// account picker just below the password field (kDebugMode-gated) for
// rapid role switching against the Lagan Valley seed.

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import '../state/providers.dart';
import '../theme/tokens.dart';

class _DemoAccount {
  final String email;
  final String label;
  final String hint;
  const _DemoAccount(this.email, this.label, this.hint);
}

const List<_DemoAccount> _demoAccounts = [
  _DemoAccount('owen@lagan.test', 'Owen — Owner',
      'Admin web app, full sidebar'),
  _DemoAccount('dave@lagan.test', 'Dave — Instructor',
      'Belfast, past + future sessions'),
  _DemoAccount('priya@lagan.test', 'Priya — Instructor',
      'Lisburn, recorded competencies'),
  _DemoAccount('alex@test', 'Alex — Student',
      'Outstanding £30, disruption on next CBT'),
  _DemoAccount('maeve@test', 'Maeve — Student',
      'Safety flag, upcoming practical + test day'),
  _DemoAccount('rowan@test', 'Rowan — Student',
      'Pending approval state'),
  _DemoAccount('carlos@test', 'Carlos — Student',
      'Booked into the fully-booked CBT'),
];

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _email = TextEditingController(text: 'alex@test');
  final _password = TextEditingController(text: 'password');
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() {
    final email = _email.text.trim();
    final password = _password.text;
    if (email.isEmpty || password.isEmpty) return;
    ref.read(authControllerProvider.notifier).login(email, password);
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authControllerProvider);

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: KsColors.ink),
          onPressed: () => context.go('/welcome'),
        ),
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Sign in',
                  style: GoogleFonts.plusJakartaSans(
                    fontSize: 28, fontWeight: FontWeight.w800, letterSpacing: -0.8, color: KsColors.ink,
                  )),
              const SizedBox(height: 8),
              Text('Welcome back. Pick up where you left off.',
                  style: GoogleFonts.plusJakartaSans(fontSize: 15, color: KsColors.ink2)),
              const SizedBox(height: 28),
              TextField(
                controller: _email,
                keyboardType: TextInputType.emailAddress,
                autocorrect: false,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              const SizedBox(height: 14),
              TextField(
                controller: _password,
                obscureText: _obscure,
                decoration: InputDecoration(
                  labelText: 'Password',
                  suffixIcon: IconButton(
                    onPressed: () => setState(() => _obscure = !_obscure),
                    icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                        color: KsColors.ink3),
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),
              if (kDebugMode) ...[
                const SizedBox(height: 16),
                _DevAccountPicker(
                  onPick: (a) {
                    setState(() {
                      _email.text = a.email;
                      _password.text = 'password';
                    });
                  },
                ),
              ],
              if (auth.error != null) ...[
                const SizedBox(height: 16),
                _ErrorBanner(message: auth.error!),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: auth.loading ? null : _submit,
                child: auth.loading
                    ? const SizedBox(
                        width: 22, height: 22,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2.5),
                      )
                    : const Text('Sign in'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DevAccountPicker extends StatelessWidget {
  final ValueChanged<_DemoAccount> onPick;
  const _DevAccountPicker({required this.onPick});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: KsColors.surface,
        borderRadius: BorderRadius.circular(KsRadius.md),
        border: Border.all(color: KsColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bolt, size: 16, color: KsColors.ink3),
              const SizedBox(width: 6),
              Text('Dev quick-fill',
                  style: GoogleFonts.plusJakartaSans(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: KsColors.ink3)),
            ],
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<_DemoAccount>(
            isExpanded: true,
            initialValue: null,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              labelText: 'Pick a seeded account',
            ),
            // DropdownMenuItem constrains its child to a single-line height
            // (~24px with isDense). A 2-line label+hint Column overflowed
            // and cascaded into "infinite width" errors that broke every
            // subsequent page render — keep it as a single Row.
            items: _demoAccounts
                .map((a) => DropdownMenuItem<_DemoAccount>(
                      value: a,
                      child: Row(
                        children: [
                          Text(a.label,
                              style: GoogleFonts.plusJakartaSans(
                                  fontSize: 13.5, fontWeight: FontWeight.w700)),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text('· ${a.hint}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: GoogleFonts.plusJakartaSans(
                                    fontSize: 11.5, color: KsColors.ink3)),
                          ),
                        ],
                      ),
                    ))
                .toList(),
            onChanged: (a) {
              if (a != null) onPick(a);
            },
          ),
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  const _ErrorBanner({required this.message});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: KsColors.dangerTint,
        borderRadius: BorderRadius.circular(KsRadius.md),
        border: Border.all(color: KsColors.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: KsColors.danger, size: 20),
          const SizedBox(width: 10),
          Expanded(child: Text(message, style: const TextStyle(color: KsColors.danger, fontSize: 14))),
        ],
      ),
    );
  }
}
