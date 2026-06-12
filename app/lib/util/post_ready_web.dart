// Web implementation of postReady — posts a `kickstand-ready` message
// to window.parent so the surrounding marketing wrapper (the JSX
// launcher in design_handoff_kickstand/Kickstand.html) can take its
// loading overlay down at the exact moment Flutter paints. The
// fallback iframe-onLoad+timeout in the wrapper covers anything
// that fails to deliver this.

// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

void postReady() {
  try {
    html.window.parent?.postMessage('kickstand-ready', '*');
  } catch (_) {
    // Top-level frame, no parent — fine, just don't fire.
  }
}
