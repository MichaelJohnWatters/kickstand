// Kickstand — app shell: brand, role launcher, role switcher, auto-fit stage.
const { useState: useStateSh, useRef: useRefSh, useEffect: useEffectSh } = React;

/* Scales child to fit the available area, letterboxed on the stage bg. */
function Fit({ w, h, children }) {
  const wrap = useRefSh(null);
  const [scale, setScale] = useStateSh(1);
  useEffectSh(() => {
    const el = wrap.current;
    if (!el) return;
    const ro = new ResizeObserver(() => {
      const aw = el.clientWidth - 48, ah = el.clientHeight - 48;
      setScale(Math.min(aw / w, ah / h, 1));
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, [w, h]);
  return (
    <div ref={wrap} style={{ flex: 1, minHeight: 0, display: 'grid', placeItems: 'center', overflow: 'hidden' }}>
      <div style={{ width: w, height: h, transform: `scale(${scale})`, transformOrigin: 'center', flexShrink: 0 }}>
        {children}
      </div>
    </div>
  );
}

const KSLogo = ({ size = 30, on = '#fff', bg = 'var(--primary)' }) => (
  <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
    <div style={{ width: size, height: size, borderRadius: size * 0.3, background: bg, display: 'grid', placeItems: 'center', color: on, boxShadow: 'var(--sh-primary)' }}>
      <Icon name="moto" size={size * 0.66} sw={1.9} />
    </div>
    <span style={{ fontWeight: 800, fontSize: size * 0.62, letterSpacing: '-0.04em', color: 'var(--ink)' }}>Kickstand</span>
  </div>
);

const ROLES = [
  { id: 'student',    label: 'Student',    icon: 'cap',        tone: 277, kind: 'Mobile app',     desc: 'Book training, track licence progress, manage bookings.' },
  { id: 'instructor', label: 'Instructor', icon: 'clipboard-check', tone: 160, kind: 'Mobile app', desc: 'Day schedule, set availability, mark attendance & sign off skills.' },
  { id: 'admin',      label: 'Admin',      icon: 'layers',     tone: 70,  kind: 'Web dashboard',  desc: 'Master calendar, fleet, disruptions & bike logistics.' },
];
const ONBOARD = { id: 'onboarding', label: 'Auth & onboarding', icon: 'key', tone: 305, kind: 'Entry flow', desc: 'Role-aware login, school selection & student licence setup.' };

function Launcher({ go }) {
  return (
    <div className="ks-screen" style={{ flex: 1, overflowY: 'auto', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', padding: '40px 24px' }}>
      <div style={{ maxWidth: 880, width: '100%' }}>
        <div style={{ textAlign: 'center', marginBottom: 38 }}>
          <div style={{ display: 'inline-flex' }}><KSLogo size={44} /></div>
          <div style={{ fontWeight: 800, fontSize: 'clamp(28px, 4vw, 40px)', letterSpacing: '-0.04em', marginTop: 22, lineHeight: 1.05 }}>
            Rider-training management,<br /><span style={{ color: 'var(--primary)' }}>honestly scheduled.</span>
          </div>
          <div style={{ fontSize: 16, color: 'var(--ink-3)', marginTop: 12, maxWidth: 520, marginInline: 'auto', lineHeight: 1.5 }}>
            A multi-tenant platform for UK motorcycle schools. Pick a role to explore the prototype.
          </div>
          <div style={{ display: 'inline-flex', alignItems: 'center', gap: 8, marginTop: 16, padding: '7px 14px', borderRadius: 99, background: 'var(--surface)', border: '1px solid var(--border)', fontSize: 13, fontWeight: 700, color: 'var(--ink-2)', boxShadow: 'var(--sh-1)' }}>
            <Icon name="building" size={15} sw={2.1} style={{ color: 'var(--primary)' }} /> Demo school: {SCHOOL.name}
          </div>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(230px, 1fr))', gap: 16 }}>
          {[...ROLES, ONBOARD].map(r => (
            <Card key={r.id} hover pad={0} onClick={() => go(r.id)} style={{ overflow: 'hidden' }}>
              <div style={{ height: 6, background: `oklch(0.6 0.13 ${r.tone})` }} />
              <div style={{ padding: 20 }}>
                <div style={{ width: 50, height: 50, borderRadius: 14, display: 'grid', placeItems: 'center', background: `oklch(0.93 0.05 ${r.tone})`, color: `oklch(0.45 0.13 ${r.tone})`, marginBottom: 16 }}><Icon name={r.icon} size={26} sw={2} /></div>
                <div style={{ fontSize: 11.5, fontWeight: 700, letterSpacing: '0.05em', textTransform: 'uppercase', color: 'var(--ink-4)' }}>{r.kind}</div>
                <div style={{ fontWeight: 800, fontSize: 21, letterSpacing: '-0.03em', margin: '3px 0 7px' }}>{r.label}</div>
                <div style={{ fontSize: 13.5, color: 'var(--ink-3)', lineHeight: 1.5, minHeight: 60 }}>{r.desc}</div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginTop: 8, color: `oklch(0.5 0.13 ${r.tone})`, fontWeight: 700, fontSize: 13.5 }}>
                  Open {r.label.toLowerCase()} <Icon name="arrow-right" size={16} sw={2.4} />
                </div>
              </div>
            </Card>
          ))}
        </div>
      </div>
    </div>
  );
}

const ACCENTS = [
  { id: 'indigo', label: 'Indigo', hue: 277 },
  { id: 'violet', label: 'Violet', hue: 305 },
  { id: 'blue',   label: 'Blue',   hue: 255 },
  { id: 'teal',   label: 'Teal',   hue: 195 },
  { id: 'green',  label: 'Green',  hue: 155 },
  { id: 'coral',  label: 'Coral',  hue: 35  },
];
const FONTS = {
  jakarta: "'Plus Jakarta Sans', system-ui, sans-serif",
  manrope: "'Manrope', system-ui, sans-serif",
  grotesk: "'Space Grotesk', system-ui, sans-serif",
};
const CORNERS = {
  rounded: { '--r-xs': '8px', '--r-sm': '11px', '--r': '14px', '--r-lg': '20px', '--r-xl': '28px' },
  soft:    { '--r-xs': '6px', '--r-sm': '8px',  '--r': '10px', '--r-lg': '13px', '--r-xl': '17px' },
  sharp:   { '--r-xs': '2px', '--r-sm': '3px',  '--r': '4px',  '--r-lg': '5px',  '--r-xl': '7px'  },
};

const TWEAK_DEFAULTS = /*EDITMODE-BEGIN*/{
  "dark": false,
  "accent": "indigo",
  "font": "jakarta",
  "corners": "rounded"
}/*EDITMODE-END*/;

// Wraps the Flutter web app's iframe with a brief overlay spinner.
// The iframe's `load` event fires when main.dart.js finishes
// downloading, but Flutter still needs ~300–700ms after that to
// bootstrap and paint its first frame — without an overlay the
// visitor sees a blank canvas during that window. Hide the overlay
// either on a postMessage('kickstand-ready') from inside the app
// (most accurate) or 700ms after the iframe loads as a fallback.
function FlutterDemoFrame({ role, src }) {
  const [loading, setLoading] = useStateSh(true);
  useEffectSh(() => {
    // Role switch — show the overlay again until the new Flutter app
    // posts its `kickstand-ready` signal (or the safety net below).
    setLoading(true);
    const onMsg = (e) => {
      if (e && e.data === 'kickstand-ready') setLoading(false);
    };
    window.addEventListener('message', onMsg);
    return () => window.removeEventListener('message', onMsg);
  }, [role, src]);
  // Safety net — main.dart fires `kickstand-ready` in addPostFrameCallback
  // which lands within ~400ms of the first frame painting on a warm
  // cache. A 2.5 s ceiling covers cold caches without leaving the
  // spinner up forever if the message never arrives.
  const onLoad = () => {
    setTimeout(() => setLoading(false), 2500);
  };
  return (
    <div style={{ position: 'relative', width: '100%', height: '100%' }}>
      <iframe
        key={role}
        src={src}
        title={`Kickstand ${role} demo`}
        onLoad={onLoad}
        style={{ width: '100%', height: '100%', border: 0, background: 'var(--app-bg)' }}
        loading="lazy"
        allow="clipboard-write"
      />
      {loading && (
        <div
          style={{
            position: 'absolute', inset: 0,
            background: 'var(--app-bg)',
            display: 'grid', placeItems: 'center',
            transition: 'opacity .25s ease',
            zIndex: 2,
          }}
        >
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 14 }}>
            <div
              style={{
                width: 36, height: 36, borderRadius: '50%',
                border: '3px solid var(--border)',
                borderTopColor: 'var(--primary)',
                animation: 'ks-spin .8s linear infinite',
              }}
            />
            <div style={{ color: 'var(--ink-3)', fontWeight: 700, fontSize: 13, letterSpacing: '0.02em' }}>
              Loading {role} app…
            </div>
          </div>
          <style>{`
            @keyframes ks-spin { to { transform: rotate(360deg); } }
          `}</style>
        </div>
      )}
    </div>
  );
}

function Shell() {
  const [role, setRole] = useStateSh('home');
  const [t, setTweak] = useTweaks(TWEAK_DEFAULTS);

  const theme = t.dark ? 'dark' : 'light';
  const hue = (ACCENTS.find(a => a.id === t.accent) || ACCENTS[0]).hue;
  const rootVars = { '--primary-h': hue, '--font': FONTS[t.font] || FONTS.jakarta, ...CORNERS[t.corners] };

  // The original prototype mounted role-specific JSX components here
  // (window.StudentApp etc). Post-Flutter-cutover, those are replaced
  // by an iframe pointing at the real app's web build, served at
  // /demo/. The role tiles + top bar + tweaks panel are still all the
  // hand-crafted design shell; only the inner stage changes.
  const [studentStatus, setStudentStatus] = useStateSh('active');
  // Use a query string (not the fragment) because go_router on web
  // owns the fragment for its own routing.
  const flutterDemoSrc = role === 'student'    ? 'demo/?role=student'
                       : role === 'instructor' ? 'demo/?role=instructor'
                       : role === 'admin'      ? 'demo/?role=owner'
                                               : null;

  return (
    <div className="ks" data-theme={theme}
      style={{ ...rootVars, height: '100vh', display: 'flex', flexDirection: 'column', background: 'var(--bg)' }}>
      {/* top bar */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 16, padding: '12px 18px', borderBottom: '1px solid var(--border)', background: 'var(--surface)', flexShrink: 0, zIndex: 10 }}>
        <button onClick={() => setRole('home')} style={{ border: 'none', background: 'transparent', cursor: 'pointer', padding: 0 }}><KSLogo size={28} /></button>
        <div style={{ flex: 1 }} />
        <Seg value={role === 'home' ? '' : role} onChange={setRole}
          items={ROLES.map(r => ({ value: r.id, label: r.label, icon: r.icon }))} />
        <button onClick={() => setTweak('dark', !t.dark)} title="Toggle theme"
          style={{ width: 40, height: 40, borderRadius: 11, border: '1px solid var(--border)', background: 'var(--surface)', display: 'grid', placeItems: 'center', color: 'var(--ink-2)', cursor: 'pointer' }}>
          <Icon name={theme === 'light' ? 'moon' : 'sun'} size={19} />
        </button>
      </div>

      {/* stage */}
      {role === 'home' && <Launcher go={setRole} />}
      {role === 'onboarding' && (
        <Fit w={402} h={874}>
          <window.AuthApp theme={theme} onFinish={(status) => { setStudentStatus(status || 'active'); setRole('student'); }} />
        </Fit>
      )}
      {role !== 'home' && role !== 'onboarding' && flutterDemoSrc && (
        <Fit w={role === 'admin' ? 1320 : 402} h={role === 'admin' ? 860 : 874}>
          <FlutterDemoFrame role={role} src={flutterDemoSrc} />
        </Fit>
      )}

      {/* Tweaks */}
      <TweaksPanel title="Tweaks">
        <TweakSection label="Theme" />
        <TweakRadio label="Mode" value={t.dark ? 'dark' : 'light'} options={['light', 'dark']} onChange={v => setTweak('dark', v === 'dark')} />
        <TweakRow label="Accent">
          <div style={{ display: 'flex', gap: 7, flexWrap: 'wrap' }}>
            {ACCENTS.map(a => (
              <button key={a.id} onClick={() => setTweak('accent', a.id)} title={a.label}
                style={{ width: 24, height: 24, borderRadius: 999, cursor: 'pointer', background: `oklch(0.6 0.19 ${a.hue})`,
                  border: t.accent === a.id ? '2px solid #fff' : '2px solid transparent',
                  boxShadow: t.accent === a.id ? `0 0 0 2px oklch(0.6 0.19 ${a.hue})` : '0 0 0 1px rgba(0,0,0,.12)' }} />
            ))}
          </div>
        </TweakRow>
        <TweakSection label="Type & shape" />
        <TweakSelect label="Typeface" value={t.font}
          options={[{ value: 'jakarta', label: 'Plus Jakarta Sans' }, { value: 'manrope', label: 'Manrope' }, { value: 'grotesk', label: 'Space Grotesk' }]}
          onChange={v => setTweak('font', v)} />
        <TweakRadio label="Corners" value={t.corners} options={['rounded', 'soft', 'sharp']} onChange={v => setTweak('corners', v)} />
      </TweaksPanel>
    </div>
  );
}

ReactDOM.createRoot(document.getElementById('root')).render(<Shell />);
