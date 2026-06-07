// Kickstand — Notifications: centre (bell feed) + preferences. Shared by all roles.
const { useState: useStateN } = React;

const notifLink = { border: 'none', background: 'transparent', color: 'var(--primary)', fontWeight: 700, fontSize: 13, cursor: 'pointer', fontFamily: 'var(--font)', padding: 0 };

function unreadCount(role) { return (NOTIFS[role] || []).filter(n => n.unread).length; }

function NotifCenter({ open, onClose, role, mobile, onOpenPrefs }) {
  const [items, setItems] = useStateN(NOTIFS[role] || []);
  const markAll = () => setItems(x => x.map(n => ({ ...n, unread: false })));
  const toneC = { primary: 'var(--primary)', success: 'var(--success)', warning: 'oklch(0.55 0.13 70)', danger: 'var(--danger)', neutral: 'var(--ink-3)' };
  const toneBg = { primary: 'var(--primary-tint)', success: 'var(--success-tint)', warning: 'var(--warning-tint)', danger: 'var(--danger-tint)', neutral: 'var(--surface-3)' };

  const body = (
    <div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14 }}>
        <button onClick={markAll} style={notifLink}>Mark all read</button>
        <div style={{ flex: 1 }} />
        <button onClick={onOpenPrefs} style={{ ...notifLink, display: 'inline-flex', alignItems: 'center', gap: 5 }}><Icon name="sliders" size={15} sw={2.1} />Preferences</button>
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        {items.map(n => (
          <div key={n.id} style={{ display: 'flex', gap: 11, padding: 12, borderRadius: 'var(--r)', background: n.unread ? 'var(--surface-2)' : 'transparent', border: '1px solid var(--border)', position: 'relative' }}>
            <div style={{ width: 36, height: 36, borderRadius: 10, flexShrink: 0, display: 'grid', placeItems: 'center', background: toneBg[n.tone], color: toneC[n.tone] }}><Icon name={n.icon} size={18} sw={2.1} /></div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
                <span style={{ fontWeight: 800, fontSize: 14 }}>{n.title}</span>
                {n.unread && <span style={{ width: 7, height: 7, borderRadius: 99, background: 'var(--primary)', flexShrink: 0 }} />}
              </div>
              <div style={{ fontSize: 12.5, color: 'var(--ink-3)', lineHeight: 1.45, marginTop: 2 }}>{n.body}</div>
              <div style={{ fontSize: 11.5, color: 'var(--ink-4)', marginTop: 4, fontWeight: 600 }}>{n.time}</div>
            </div>
          </div>
        ))}
      </div>
    </div>
  );

  if (mobile) return <Sheet open={open} onClose={onClose} title="Notifications">{body}</Sheet>;
  return <Modal open={open} onClose={onClose} title="Notifications" icon="bell" width={480}>{body}</Modal>;
}

function Switch({ on, onClick }) {
  return (
    <button onClick={onClick} style={{
      width: 42, height: 25, borderRadius: 99, border: 'none', cursor: 'pointer', position: 'relative',
      background: on ? 'var(--primary)' : 'var(--border-2)', transition: 'background .18s', flexShrink: 0,
    }}>
      <span style={{ position: 'absolute', top: 3, left: on ? 20 : 3, width: 19, height: 19, borderRadius: 99, background: '#fff', transition: 'left .18s', boxShadow: '0 1px 3px rgba(0,0,0,.2)' }} />
    </button>
  );
}

function NotifPrefs({ open, onClose, mobile }) {
  const [prefs, setPrefs] = useStateN(NOTIF_PREFS_DEFAULT);
  const toggle = (cat, ch) => setPrefs(p => ({ ...p, [cat]: { ...p[cat], [ch]: !p[cat][ch] } }));
  const channels = [{ id: 'email', label: 'Email' }, { id: 'push', label: 'Push' }, { id: 'sms', label: 'SMS' }];

  const body = (
    <div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '9px 12px', borderRadius: 8, background: 'var(--surface-2)', marginBottom: 16, fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 600, lineHeight: 1.4 }}>
        <Icon name="info" size={15} sw={2.1} style={{ flexShrink: 0 }} />Routine reminders are kept separate from urgent issues — so you can mute the noise without missing what matters. SMS arrives in phase 2.
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        {NOTIF_CATEGORIES.map(cat => (
          <div key={cat.id} style={{ padding: 13, borderRadius: 'var(--r)', border: '1px solid var(--border)', background: 'var(--surface)' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <div style={{ flex: 1 }}>
                <div style={{ display: 'flex', alignItems: 'center', gap: 7 }}>
                  <span style={{ fontWeight: 800, fontSize: 14 }}>{cat.label}</span>
                  {cat.urgent && <Badge tone="danger" size="sm">Urgent</Badge>}
                </div>
                <div style={{ fontSize: 12, color: 'var(--ink-4)', marginTop: 1 }}>{cat.desc}</div>
              </div>
            </div>
            <div style={{ display: 'flex', gap: 18, marginTop: 11 }}>
              {channels.map(ch => (
                <label key={ch.id} style={{ display: 'flex', alignItems: 'center', gap: 8, cursor: 'pointer' }}>
                  <Switch on={prefs[cat.id][ch.id]} onClick={() => toggle(cat.id, ch.id)} />
                  <span style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--ink-2)' }}>{ch.label}{ch.id === 'sms' && <span style={{ color: 'var(--ink-4)', fontWeight: 600 }}> ·P2</span>}</span>
                </label>
              ))}
            </div>
          </div>
        ))}
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 14, fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 600 }}>
        <Icon name="moon" size={15} sw={2.1} />Quiet hours respected — no sends 21:00–07:00 or outside school hours.
      </div>
    </div>
  );

  if (mobile) return <Sheet open={open} onClose={onClose} title="Notification preferences">{body}</Sheet>;
  return <Modal open={open} onClose={onClose} title="Notification preferences" icon="sliders" width={500}>{body}</Modal>;
}

// Bell trigger (renders the button + unread dot). Pairs with NotifCenter.
function NotifBell({ role, onClick, style }) {
  const count = unreadCount(role);
  return (
    <button onClick={onClick} style={style || { width: 40, height: 40, borderRadius: 11, border: '1px solid var(--border)', background: 'var(--surface)', display: 'grid', placeItems: 'center', color: 'var(--ink-2)', cursor: 'pointer', position: 'relative' }}>
      <Icon name="bell" size={20} />
      {count > 0 && <span style={{ position: 'absolute', top: 7, right: 8, minWidth: 8, height: 8, borderRadius: 99, background: 'var(--danger)', border: '1.5px solid var(--surface)' }} />}
    </button>
  );
}

Object.assign(window, { NotifCenter, NotifPrefs, NotifBell, unreadCount });
