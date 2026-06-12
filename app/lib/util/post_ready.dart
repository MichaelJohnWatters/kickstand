// Conditional re-export — `postReady()` resolves to the web
// implementation that talks to window.parent, or a no-op stub on
// mobile/desktop where there's no parent window to post to.

export 'post_ready_stub.dart' if (dart.library.html) 'post_ready_web.dart';
