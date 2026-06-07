// Kickstand — shared UI kit. Buttons, cards, badges, avatars, sheets, progress.
const { useState, useEffect, useRef } = React;

/* ---------- Button ---------- */
function Btn({ children, variant = 'primary', size = 'md', icon, iconRight, full, onClick, disabled, style }) {
  const [press, setPress] = useState(false);
  const pads = { sm: '8px 13px', md: '0 18px', lg: '0 22px' };
  const heights = { sm: 'auto', md: 44, lg: 52 };
  const fs = { sm: 13.5, md: 15, lg: 16 };
  const variants = {
    primary:   { background: 'var(--primary)', color: 'var(--on-primary)', boxShadow: 'var(--sh-primary)' },
    secondary: { background: 'var(--surface)', color: 'var(--ink)', border: '1px solid var(--border-2)', boxShadow: 'var(--sh-1)' },
    soft:      { background: 'var(--primary-tint)', color: 'var(--primary-deep)' },
    ghost:     { background: 'transparent', color: 'var(--ink-2)' },
    danger:    { background: 'var(--danger)', color: '#fff' },
    'danger-soft': { background: 'var(--danger-tint)', color: 'var(--danger)' },
    success:   { background: 'var(--success)', color: '#fff' },
    dark:      { background: 'var(--ink)', color: 'var(--surface)' },
  };
  return (
    <button
      onClick={disabled ? undefined : onClick}
      onPointerDown={() => setPress(true)}
      onPointerUp={() => setPress(false)}
      onPointerLeave={() => setPress(false)}
      disabled={disabled}
      style={{
        display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 8,
        height: heights[size], minHeight: size === 'sm' ? 34 : heights[size],
        padding: pads[size], width: full ? '100%' : undefined,
        borderRadius: size === 'lg' ? 'var(--r)' : 'var(--r-sm)', border: 'none',
        fontFamily: 'var(--font)', fontWeight: 700, fontSize: fs[size], letterSpacing: '-0.01em',
        transition: 'transform .12s, box-shadow .18s, background .18s, opacity .18s',
        transform: press ? 'scale(.96)' : 'none',
        opacity: disabled ? 0.45 : 1, cursor: disabled ? 'not-allowed' : 'pointer',
        whiteSpace: 'nowrap', ...variants[variant], ...style,
      }}>
      {icon && <Icon name={icon} size={size === 'sm' ? 16 : 19} sw={2.1} />}
      {children}
      {iconRight && <Icon name={iconRight} size={size === 'sm' ? 16 : 19} sw={2.1} />}
    </button>
  );
}

/* ---------- Avatar ---------- */
function Avatar({ initials, tone = 277, size = 38, ring }) {
  return (
    <div style={{
      width: size, height: size, borderRadius: '50%', flexShrink: 0,
      display: 'flex', alignItems: 'center', justifyContent: 'center',
      background: `oklch(0.90 0.055 ${tone})`, color: `oklch(0.42 0.13 ${tone})`,
      fontWeight: 700, fontSize: size * 0.38, letterSpacing: '-0.02em',
      border: ring ? '2px solid var(--surface)' : 'none',
      boxShadow: ring ? '0 0 0 1.5px var(--border-2)' : 'none',
    }}>{initials}</div>
  );
}

/* ---------- Card ---------- */
function Card({ children, pad = 16, style, onClick, hover, accent }) {
  const [h, setH] = useState(false);
  return (
    <div
      onClick={onClick}
      onMouseEnter={() => setH(true)} onMouseLeave={() => setH(false)}
      style={{
        background: 'var(--surface)', borderRadius: 'var(--r-lg)',
        border: '1px solid var(--border)', padding: pad,
        boxShadow: hover && h ? 'var(--sh-2)' : 'var(--sh-1)',
        transition: 'box-shadow .2s, transform .2s, border-color .2s',
        transform: hover && h ? 'translateY(-2px)' : 'none',
        cursor: onClick ? 'pointer' : 'default',
        borderLeft: accent ? `3px solid ${accent}` : undefined,
        ...style,
      }}>{children}</div>
  );
}

/* ---------- Badge / Pill ---------- */
function Badge({ children, tone = 'neutral', solid, icon, size = 'md' }) {
  const tones = {
    neutral: ['var(--surface-3)', 'var(--ink-2)'],
    primary: ['var(--primary-tint)', 'var(--primary-deep)'],
    success: ['var(--success-tint)', 'var(--success)'],
    warning: ['var(--warning-tint)', 'oklch(0.50 0.13 70)'],
    danger:  ['var(--danger-tint)', 'var(--danger)'],
  };
  const [bg, fg] = tones[tone];
  return (
    <span style={{
      display: 'inline-flex', alignItems: 'center', gap: 5,
      padding: size === 'sm' ? '3px 8px' : '4px 10px',
      borderRadius: 'var(--r-pill)', fontWeight: 700,
      fontSize: size === 'sm' ? 11 : 12, letterSpacing: '0.01em',
      background: solid ? fg : bg, color: solid ? '#fff' : fg,
      whiteSpace: 'nowrap',
    }}>
      {icon && <Icon name={icon} size={size === 'sm' ? 12 : 13} sw={2.4} />}
      {children}
    </span>
  );
}

const BIKE_STATUS = {
  ready:    { tone: 'success', label: 'Ready', icon: 'check-circle' },
  mechanic: { tone: 'warning', label: 'At mechanic', icon: 'wrench' },
  damaged:  { tone: 'danger',  label: 'Damaged', icon: 'alert' },
  offroad:  { tone: 'neutral', label: 'Off-road', icon: 'ban' },
};
function BikeStatus({ status, size = 'md' }) {
  const s = BIKE_STATUS[status] || BIKE_STATUS.ready;
  return <Badge tone={s.tone} icon={s.icon} size={size}>{s.label}</Badge>;
}

/* ---------- Segmented control ---------- */
function Seg({ items, value, onChange, full }) {
  return (
    <div style={{
      display: 'inline-flex', background: 'var(--surface-3)', borderRadius: 'var(--r-sm)',
      padding: 3, gap: 2, width: full ? '100%' : undefined, border: '1px solid var(--border)',
    }}>
      {items.map(it => {
        const v = it.value ?? it;
        const label = it.label ?? it;
        const active = v === value;
        return (
          <button key={v} onClick={() => onChange(v)} style={{
            flex: full ? 1 : undefined, border: 'none', borderRadius: 9,
            padding: '7px 14px', fontFamily: 'var(--font)', fontWeight: 700, fontSize: 13.5,
            background: active ? 'var(--surface)' : 'transparent',
            color: active ? 'var(--ink)' : 'var(--ink-3)',
            boxShadow: active ? 'var(--sh-1)' : 'none',
            transition: 'all .18s', cursor: 'pointer', whiteSpace: 'nowrap',
            display: 'inline-flex', alignItems: 'center', justifyContent: 'center', gap: 6,
          }}>
            {it.icon && <Icon name={it.icon} size={15} sw={2.1} />}
            {label}
          </button>
        );
      })}
    </div>
  );
}

/* ---------- Progress bar / ring ---------- */
function ProgressBar({ value, total, color = 'var(--primary)', height = 8 }) {
  const pct = total ? Math.round((value / total) * 100) : 0;
  return (
    <div style={{ background: 'var(--surface-3)', borderRadius: 99, height, overflow: 'hidden', width: '100%' }}>
      <div style={{ width: `${pct}%`, height: '100%', background: color, borderRadius: 99, transition: 'width .6s cubic-bezier(.22,.9,.3,1)' }} />
    </div>
  );
}
function ProgressRing({ value, total, size = 56, sw = 6, color = 'var(--primary)', children }) {
  const r = (size - sw) / 2, c = 2 * Math.PI * r;
  const pct = total ? value / total : 0;
  return (
    <div style={{ position: 'relative', width: size, height: size }}>
      <svg width={size} height={size} style={{ transform: 'rotate(-90deg)' }}>
        <circle cx={size/2} cy={size/2} r={r} fill="none" stroke="var(--surface-3)" strokeWidth={sw} />
        <circle cx={size/2} cy={size/2} r={r} fill="none" stroke={color} strokeWidth={sw}
          strokeLinecap="round" strokeDasharray={c} strokeDashoffset={c * (1 - pct)}
          style={{ transition: 'stroke-dashoffset .8s cubic-bezier(.22,.9,.3,1)' }} />
      </svg>
      <div style={{ position: 'absolute', inset: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', fontWeight: 800 }}>
        {children}
      </div>
    </div>
  );
}

/* ---------- Bottom sheet (mobile) ---------- */
function Sheet({ open, onClose, children, title }) {
  if (!open) return null;
  return (
    <div onClick={onClose} style={{
      position: 'absolute', inset: 0, zIndex: 200, display: 'flex', alignItems: 'flex-end',
      background: 'rgba(28,22,60,.42)', animation: 'ks-fade .22s', backdropFilter: 'blur(2px)',
    }}>
      <div onClick={e => e.stopPropagation()} style={{
        background: 'var(--surface)', width: '100%', borderRadius: '24px 24px 0 0',
        padding: '10px 18px calc(20px + env(safe-area-inset-bottom))', animation: 'ks-sheet-up .32s cubic-bezier(.22,.9,.3,1)',
        maxHeight: '88%', overflowY: 'auto', boxShadow: '0 -10px 40px rgba(28,22,60,.25)',
      }}>
        <div style={{ width: 38, height: 5, borderRadius: 99, background: 'var(--border-2)', margin: '4px auto 14px' }} />
        {title && <div style={{ fontWeight: 800, fontSize: 19, marginBottom: 14, letterSpacing: '-0.02em' }}>{title}</div>}
        {children}
      </div>
    </div>
  );
}

/* ---------- Centered modal (desktop) ---------- */
function Modal({ open, onClose, children, title, width = 460, icon, tone = 'primary' }) {
  if (!open) return null;
  const toneC = { primary: 'var(--primary)', danger: 'var(--danger)', warning: 'var(--warning)', success: 'var(--success)' }[tone];
  return (
    <div onClick={onClose} style={{
      position: 'absolute', inset: 0, zIndex: 300, display: 'flex', alignItems: 'center', justifyContent: 'center',
      background: 'rgba(28,22,60,.45)', animation: 'ks-fade .2s', backdropFilter: 'blur(3px)', padding: 24,
    }}>
      <div onClick={e => e.stopPropagation()} style={{
        background: 'var(--surface)', width, maxWidth: '100%', borderRadius: 'var(--r-xl)',
        boxShadow: 'var(--sh-3)', animation: 'ks-scale-in .26s cubic-bezier(.22,.9,.3,1)', overflow: 'hidden',
      }}>
        {title && (
          <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '20px 22px 0' }}>
            {icon && <div style={{ width: 40, height: 40, borderRadius: 12, display: 'grid', placeItems: 'center', background: `color-mix(in oklch, ${toneC} 14%, transparent)`, color: toneC }}><Icon name={icon} size={22} /></div>}
            <div style={{ fontWeight: 800, fontSize: 19, letterSpacing: '-0.02em' }}>{title}</div>
          </div>
        )}
        <div style={{ padding: 22 }}>{children}</div>
      </div>
    </div>
  );
}

/* ---------- Mobile tab bar ---------- */
function TabBar({ tabs, active, onChange }) {
  return (
    <div style={{
      display: 'flex', background: 'var(--surface)', borderTop: '1px solid var(--border)',
      padding: '8px 8px 26px', position: 'relative', zIndex: 20,
    }}>
      {tabs.map(t => {
        const on = t.id === active;
        return (
          <button key={t.id} onClick={() => onChange(t.id)} style={{
            flex: 1, border: 'none', background: 'transparent', display: 'flex', flexDirection: 'column',
            alignItems: 'center', gap: 4, padding: '4px 0', cursor: 'pointer',
            color: on ? 'var(--primary)' : 'var(--ink-4)', transition: 'color .18s',
          }}>
            <div style={{ position: 'relative' }}>
              <Icon name={t.icon} size={23} sw={on ? 2.4 : 2} />
              {t.badge && <span style={{ position: 'absolute', top: -3, right: -5, width: 8, height: 8, borderRadius: 99, background: 'var(--danger)', border: '1.5px solid var(--surface)' }} />}
            </div>
            <span style={{ fontSize: 10.5, fontWeight: on ? 700 : 600, letterSpacing: '0.01em' }}>{t.label}</span>
          </button>
        );
      })}
    </div>
  );
}

/* ---------- Section label ---------- */
function SectionLabel({ children, action }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', margin: '2px 2px 10px' }}>
      <div style={{ fontSize: 13, fontWeight: 800, letterSpacing: '0.04em', textTransform: 'uppercase', color: 'var(--ink-3)' }}>{children}</div>
      {action}
    </div>
  );
}

/* ---------- Toast ---------- */
function Toast({ msg, icon = 'check-circle', tone = 'var(--success)' }) {
  if (!msg) return null;
  return (
    <div style={{
      position: 'absolute', bottom: 96, left: '50%', transform: 'translateX(-50%)', zIndex: 250,
      background: 'var(--ink)', color: 'var(--surface)', padding: '12px 18px', borderRadius: 'var(--r)',
      display: 'flex', alignItems: 'center', gap: 9, fontWeight: 600, fontSize: 14, boxShadow: 'var(--sh-3)',
      animation: 'ks-pop .4s cubic-bezier(.22,1.2,.4,1)', whiteSpace: 'nowrap',
    }}>
      <span style={{ color: tone, display: 'flex' }}><Icon name={icon} size={18} sw={2.4} /></span>{msg}
    </div>
  );
}

/* ---------- Bike avatar (category chip) ---------- */
function BikeGlyph({ cat, size = 40, trans }) {
  const tone = cat === 'A1' ? 277 : cat === 'A2' ? 70 : 25;
  return (
    <div style={{
      width: size, height: size, borderRadius: 12, flexShrink: 0,
      display: 'grid', placeItems: 'center',
      background: `oklch(0.93 0.05 ${tone})`, color: `oklch(0.45 0.13 ${tone})`,
    }}>
      <Icon name="moto" size={size * 0.6} sw={1.8} />
    </div>
  );
}

/* ---------- QR code + share sheet ---------- */
function QRCode({ value, size = 196 }) {
  const [url, setUrl] = useState('');
  useEffect(() => {
    try {
      const qr = window.qrcode(0, 'M');
      qr.addData(value);
      qr.make();
      const count = qr.getModuleCount();
      const cell = Math.max(2, Math.round(size / (count + 8)));
      setUrl(qr.createDataURL(cell, 4));
    } catch (e) { setUrl(''); }
  }, [value, size]);
  return url
    ? <img src={url} width={size} height={size} alt="QR code" style={{ imageRendering: 'pixelated', display: 'block', borderRadius: 6 }} />
    : <div style={{ width: size, height: size, display: 'grid', placeItems: 'center', color: 'var(--ink-4)' }}><Icon name="qr" size={40} /></div>;
}

function ShareSheet({ open, onClose, title = 'Share', subtitle, url, caption }) {
  const [copied, setCopied] = useState(false);
  const copy = () => { try { navigator.clipboard.writeText(url); } catch (e) {} setCopied(true); setTimeout(() => setCopied(false), 1600); };
  return (
    <Sheet open={open} onClose={onClose} title={title}>
      {subtitle && <div style={{ fontSize: 14, color: 'var(--ink-3)', marginTop: -6, marginBottom: 18, lineHeight: 1.45 }}>{subtitle}</div>}
      <div style={{ display: 'flex', justifyContent: 'center', marginBottom: 18 }}>
        <div style={{ padding: 16, background: '#fff', borderRadius: 'var(--r-lg)', border: '1px solid var(--border)', boxShadow: 'var(--sh-2)' }}>
          {open && <QRCode value={url} size={200} />}
        </div>
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '11px 14px', borderRadius: 'var(--r)', background: 'var(--surface-2)', border: '1px solid var(--border)', marginBottom: 12 }}>
        <span style={{ color: 'var(--primary)', display: 'flex' }}><Icon name="link" size={18} sw={2} /></span>
        <span className="mono" style={{ flex: 1, fontSize: 12.5, color: 'var(--ink-2)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{caption || url}</span>
      </div>
      <Btn full size="lg" icon={copied ? 'check' : 'clipboard'} variant={copied ? 'success' : 'primary'} onClick={copy}>
        {copied ? 'Copied to clipboard' : 'Copy link'}
      </Btn>
    </Sheet>
  );
}

/* ---------- Form inputs (shared) ---------- */
function KField({ label, hint, optional, children }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 7 }}>
      {label && (
        <span style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 8 }}>
          <span style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--ink-2)' }}>{label}</span>
          {optional && <span style={{ fontSize: 11.5, fontWeight: 600, color: 'var(--ink-4)' }}>Optional</span>}
        </span>
      )}
      {children}
      {hint && <span style={{ fontSize: 11.5, color: 'var(--ink-4)', lineHeight: 1.4 }}>{hint}</span>}
    </div>
  );
}
const kInputStyle = { width: '100%', height: 42, padding: '0 13px', borderRadius: 'var(--r-sm)', border: '1px solid var(--border-2)', background: 'var(--surface)', fontFamily: 'var(--font)', fontSize: 14.5, fontWeight: 500, color: 'var(--ink)', outline: 'none', boxSizing: 'border-box' };
function KInput({ value, onChange, placeholder, prefix, type = 'text' }) {
  if (prefix) return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 7, ...kInputStyle, padding: '0 13px' }}>
      <span style={{ color: 'var(--ink-3)', fontWeight: 700 }}>{prefix}</span>
      <input type={type} value={value} onChange={e => onChange(e.target.value)} placeholder={placeholder}
        style={{ flex: 1, border: 'none', outline: 'none', background: 'transparent', fontFamily: 'var(--font)', fontSize: 14.5, fontWeight: 500, color: 'var(--ink)', minWidth: 0 }} />
    </div>
  );
  return <input type={type} value={value} onChange={e => onChange(e.target.value)} placeholder={placeholder} style={kInputStyle} />;
}
function KArea({ value, onChange, placeholder, rows = 3 }) {
  return <textarea value={value} onChange={e => onChange(e.target.value)} placeholder={placeholder} rows={rows}
    style={{ ...kInputStyle, height: 'auto', padding: '11px 13px', resize: 'vertical', lineHeight: 1.5 }} />;
}
function KSelect({ value, onChange, options }) {
  return (
    <select value={value} onChange={e => onChange(e.target.value)} style={{ ...kInputStyle, cursor: 'pointer' }}>
      {options.map(o => <option key={o.value ?? o} value={o.value ?? o}>{o.label ?? o}</option>)}
    </select>
  );
}

Object.assign(window, {
  Btn, Avatar, Card, Badge, BikeStatus, BIKE_STATUS, Seg, ProgressBar, ProgressRing,
  Sheet, Modal, TabBar, SectionLabel, Toast, BikeGlyph, QRCode, ShareSheet,
  KField, KInput, KArea, KSelect,
});
