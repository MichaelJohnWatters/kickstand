// Kickstand — Admin web dashboard shell: sidebar nav, overview, master calendar,
// logistics, instructors, locations, course config. (Fleet + Disruptions in admin-fleet.jsx)
const { useState: useStateA } = React;

const ADMIN_TODAY = 1; // Tue 9 Jun
const NAV = [
  { id: 'overview', label: 'Overview', icon: 'grid' },
  { id: 'calendar', label: 'Master calendar', icon: 'calendar' },
  { id: 'students', label: 'Students', icon: 'cap' },
  { id: 'signups', label: 'Sign-ups', icon: 'user', badge: 3 },
  { id: 'fleet', label: 'Bike fleet', icon: 'moto' },
  { id: 'disruptions', label: 'Disruptions', icon: 'alert', badge: 2 },
  { id: 'logistics', label: 'Bike logistics', icon: 'route' },
  { id: 'instructors', label: 'Instructors', icon: 'users' },
  { id: 'pay', label: 'Instructor pay', icon: 'card' },
  { id: 'reimbursements', label: 'Reimbursements', icon: 'ticket', badge: 3 },
  { id: 'locations', label: 'Locations', icon: 'pin' },
  { id: 'courses', label: 'Course types', icon: 'book' },
];

function AdminApp({ theme }) {
  const [page, setPage] = useStateA('overview');
  const [toast, setToast] = useStateA(null);
  const [notif, setNotif] = useStateA(false);
  const [prefs, setPrefs] = useStateA(false);
  const fire = (msg, icon) => { setToast({ msg, icon }); setTimeout(() => setToast(null), 2200); };

  return (
    <ChromeWindow width={1320} height={860} url="app.kickstand.io/lagan-valley" tabs={[{ title: 'Kickstand · Admin' }, { title: 'DVA Booking' }]}>
      <div className="ks" data-theme={theme} style={{ display: 'flex', height: '100%', background: 'var(--bg)', fontFamily: 'var(--font)', position: 'relative' }}>
        <Sidebar page={page} setPage={setPage} onBell={() => setNotif(true)} onPrefs={() => setPrefs(true)} />
        <div style={{ flex: 1, overflowY: 'auto', padding: '28px 32px 40px' }}>
          {page === 'overview' && <Overview go={setPage} />}
          {page === 'calendar' && <MasterCalendar />}
          {page === 'students' && <StudentsScreen fire={fire} />}
          {page === 'signups' && <SignupsScreen fire={fire} />}
          {page === 'fleet' && <FleetScreen fire={fire} />}
          {page === 'disruptions' && <DisruptionScreen fire={fire} />}
          {page === 'logistics' && <Logistics fire={fire} />}
          {page === 'instructors' && <Instructors fire={fire} />}
          {page === 'pay' && <InstructorPayScreen fire={fire} />}
          {page === 'reimbursements' && <ReimbursementsScreen fire={fire} />}
          {page === 'locations' && <Locations fire={fire} />}
          {page === 'courses' && <Courses fire={fire} />}
        </div>
        <NotifCenter open={notif} onClose={() => setNotif(false)} role="admin" onOpenPrefs={() => { setNotif(false); setPrefs(true); }} />
        <NotifPrefs open={prefs} onClose={() => setPrefs(false)} />
        {toast && <div style={{ position: 'absolute', bottom: 24, left: '50%', transform: 'translateX(-50%)', zIndex: 400 }}><InlineToast {...toast} /></div>}
      </div>
    </ChromeWindow>
  );
}

function InlineToast({ msg, icon = 'check-circle' }) {
  return (
    <div style={{ background: 'var(--ink)', color: 'var(--surface)', padding: '12px 18px', borderRadius: 'var(--r)', display: 'flex', alignItems: 'center', gap: 9, fontWeight: 600, fontSize: 14, boxShadow: 'var(--sh-3)', animation: 'ks-pop .4s cubic-bezier(.22,1.2,.4,1)' }}>
      <span style={{ color: 'var(--success)', display: 'flex' }}><Icon name={icon} size={18} sw={2.4} /></span>{msg}
    </div>
  );
}

function Sidebar({ page, setPage, onBell, onPrefs }) {
  return (
    <div style={{ width: 244, flexShrink: 0, background: 'var(--surface)', borderRight: '1px solid var(--border)', display: 'flex', flexDirection: 'column', padding: '18px 14px' }}>
      {/* school switcher */}
      <button style={{ display: 'flex', alignItems: 'center', gap: 11, padding: 10, borderRadius: 'var(--r)', border: '1px solid var(--border)', background: 'var(--surface-2)', cursor: 'pointer', width: '100%', textAlign: 'left' }}>
        <div style={{ width: 36, height: 36, borderRadius: 10, background: 'var(--primary)', display: 'grid', placeItems: 'center', color: '#fff', flexShrink: 0, fontWeight: 800, fontSize: 15 }}>LV</div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontWeight: 800, fontSize: 13.5, color: 'var(--ink)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{SCHOOL.short}</div>
          <div style={{ fontSize: 11, color: 'var(--ink-4)' }}>3 sites · 12 staff</div>
        </div>
        <Icon name="down" size={15} style={{ color: 'var(--ink-4)' }} />
      </button>

      <div style={{ marginTop: 18, display: 'flex', flexDirection: 'column', gap: 3 }}>
        {NAV.map(n => {
          const on = page === n.id;
          return (
            <button key={n.id} onClick={() => setPage(n.id)} style={{
              display: 'flex', alignItems: 'center', gap: 11, padding: '10px 12px', borderRadius: 'var(--r-sm)', cursor: 'pointer',
              border: 'none', background: on ? 'var(--primary-tint)' : 'transparent', width: '100%', textAlign: 'left',
              color: on ? 'var(--primary-deep)' : 'var(--ink-2)', fontFamily: 'var(--font)', fontWeight: on ? 700 : 600, fontSize: 14, transition: 'all .14s',
            }}>
              <Icon name={n.icon} size={19} sw={on ? 2.3 : 2} />{n.label}
              {n.badge && <span style={{ marginLeft: 'auto', background: 'var(--danger)', color: '#fff', fontSize: 11, fontWeight: 800, borderRadius: 99, minWidth: 19, height: 19, display: 'grid', placeItems: 'center', padding: '0 5px' }}>{n.badge}</span>}
            </button>
          );
        })}
      </div>

      <div style={{ marginTop: 'auto', display: 'flex', alignItems: 'center', gap: 10, padding: 10, borderRadius: 'var(--r)', background: 'var(--surface-2)' }}>
        <Avatar initials="RB" tone={277} size={36} />
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ fontWeight: 700, fontSize: 13.5 }}>Rachel Burns</div>
          <div style={{ fontSize: 11.5, color: 'var(--ink-4)', display: 'flex', alignItems: 'center', gap: 4 }}><Icon name="crown" size={12} sw={2.2} style={{ color: 'oklch(0.6 0.13 70)' }} />Owner</div>
        </div>
        <NotifBell role="admin" onClick={onBell} style={{ width: 32, height: 32, borderRadius: 9, border: 'none', background: 'transparent', display: 'grid', placeItems: 'center', color: 'var(--ink-3)', cursor: 'pointer', position: 'relative' }} />
        <button onClick={onPrefs} style={{ width: 32, height: 32, borderRadius: 9, border: 'none', background: 'transparent', color: 'var(--ink-4)', cursor: 'pointer', display: 'grid', placeItems: 'center' }} title="Notification preferences"><Icon name="settings" size={17} /></button>
      </div>
    </div>
  );
}

/* ---------------- Overview ---------------- */
function Overview({ go }) {
  const today = SESSIONS.filter(s => s.day === ADMIN_TODAY);
  return (
    <div className="ks-screen">
      <PageHead title="Good morning, Rachel" sub="Tuesday 9 June · here's how today looks across Lagan Valley." />
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 14, marginBottom: 22 }}>
        <KPI tone={277} icon="calendar" value={today.length} label="Sessions today" foot="2 sites active" />
        <KPI tone={160} icon="check-circle" value="6" label="Bikes ready" foot="of 8 in fleet" />
        <KPI tone={70} icon="users" value="4" label="Instructors on" foot="1 on leave" />
        <KPI tone={25} icon="gauge" value="78%" label="Week occupancy" foot="↑ 6% vs last wk" />
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr', gap: 18 }}>
        {/* Needs attention */}
        <div>
          <SectionLabel>Needs attention</SectionLabel>
          <Card pad={0} style={{ overflow: 'hidden', borderColor: 'var(--danger)', marginBottom: 12 }}>
            <button onClick={() => go('disruptions')} style={{ display: 'flex', alignItems: 'center', gap: 14, padding: 16, width: '100%', textAlign: 'left', border: 'none', background: 'var(--danger-tint)', cursor: 'pointer' }}>
              <div style={{ width: 44, height: 44, borderRadius: 12, display: 'grid', placeItems: 'center', background: 'var(--danger)', color: '#fff', flexShrink: 0 }}><Icon name="alert" size={23} /></div>
              <div style={{ flex: 1 }}>
                <div style={{ fontWeight: 800, fontSize: 15 }}>Yamaha YBR125 down at Belfast</div>
                <div style={{ fontSize: 13, color: 'var(--ink-2)' }}>3 bookings affected · 1 swapped, 2 need action</div>
              </div>
              <Btn size="sm" variant="danger">Resolve</Btn>
            </button>
          </Card>
          <Card pad={0} style={{ overflow: 'hidden' }}>
            <button onClick={() => go('logistics')} style={{ display: 'flex', alignItems: 'center', gap: 14, padding: 16, width: '100%', textAlign: 'left', border: 'none', background: 'transparent', cursor: 'pointer' }}>
              <div style={{ width: 44, height: 44, borderRadius: 12, display: 'grid', placeItems: 'center', background: 'var(--warning-tint)', color: 'oklch(0.55 0.13 70)', flexShrink: 0 }}><Icon name="route" size={23} /></div>
              <div style={{ flex: 1 }}>
                <div style={{ fontWeight: 800, fontSize: 15 }}>3 bikes need moving for tomorrow</div>
                <div style={{ fontSize: 13, color: 'var(--ink-2)' }}>Cross-site moves — {SCHOOL.crossSiteNoticeHrs}h notice required</div>
              </div>
              <Icon name="right" size={20} style={{ color: 'var(--ink-4)' }} />
            </button>
          </Card>
        </div>
        {/* Today schedule */}
        <div>
          <SectionLabel action={<button onClick={() => go('calendar')} style={{ border: 'none', background: 'transparent', color: 'var(--primary)', fontWeight: 700, fontSize: 13, cursor: 'pointer' }}>Calendar</button>}>Today's sessions</SectionLabel>
          <Card pad={6}>
            {today.map((s, i) => {
              const c = CT[s.ct];
              return (
                <div key={s.id} style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '11px 10px', borderBottom: i < today.length - 1 ? '1px solid var(--border)' : 'none' }}>
                  <div style={{ width: 4, height: 38, borderRadius: 99, background: c.color, flexShrink: 0 }} />
                  <div style={{ flex: 1 }}>
                    <div style={{ fontWeight: 700, fontSize: 13.5 }}>{c.code} · {LOC[s.loc].short}</div>
                    <div style={{ fontSize: 12, color: 'var(--ink-3)' }}>{s.start} · {INST[s.inst].name.split(' ')[0]} · {s.booked}/{s.cap}</div>
                  </div>
                  <Avatar initials={INST[s.inst].initials} tone={INST[s.inst].tone} size={28} />
                </div>
              );
            })}
          </Card>
        </div>
      </div>
    </div>
  );
}
function KPI({ tone, icon, value, label, foot }) {
  return (
    <Card pad={16}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between' }}>
        <div style={{ width: 38, height: 38, borderRadius: 11, display: 'grid', placeItems: 'center', background: `oklch(0.93 0.05 ${tone})`, color: `oklch(0.46 0.13 ${tone})` }}><Icon name={icon} size={20} sw={2.1} /></div>
      </div>
      <div style={{ fontWeight: 800, fontSize: 30, letterSpacing: '-0.03em', marginTop: 12, lineHeight: 1 }}>{value}</div>
      <div style={{ fontWeight: 700, fontSize: 13.5, marginTop: 4 }}>{label}</div>
      <div style={{ fontSize: 12, color: 'var(--ink-4)', marginTop: 2 }}>{foot}</div>
    </Card>
  );
}

/* ---------------- Master calendar ---------------- */
const CAL_START = 8, CAL_END = 18, HOUR_H = 52;
function MasterCalendar() {
  const [loc, setLoc] = useStateA('all');
  const toMin = (t) => { const [h, m] = t.split(':').map(Number); return (h - CAL_START) * 60 + m; };
  const shown = SESSIONS.filter(s => loc === 'all' || s.loc === loc);
  return (
    <div className="ks-screen">
      <PageHead title="Master calendar" sub="All instructors, bikes & bookings · week of 8 June 2026"
        actions={<div style={{ display: 'flex', gap: 8 }}><Seg value={loc} onChange={setLoc} items={[{ value: 'all', label: 'All sites' }, ...LOCATIONS.map(l => ({ value: l.id, label: l.short }))]} /></div>} />
      <Card pad={0} style={{ overflow: 'hidden', marginBottom: 14, borderColor: 'oklch(0.7 0.135 70)' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '11px 16px', background: 'var(--warning-tint)' }}>
          <Icon name="route" size={18} sw={2.2} style={{ color: 'oklch(0.55 0.13 70)', flexShrink: 0 }} />
          <div style={{ flex: 1, fontSize: 13, color: 'var(--ink-2)', fontWeight: 600 }}>
            <b>Tight travel:</b> Mark Doherty — Belfast 12:30 → Lisburn 13:00 leaves 30 min, but it's ~{TRAVEL.belfast.lisburn} min + {TRAVEL_BUFFER} buffer. Worth a check.
          </div>
          <Badge tone="warning" size="sm">Non-blocking</Badge>
        </div>
      </Card>
      <Card pad={0} style={{ overflow: 'hidden' }}>
        {/* day headers */}
        <div style={{ display: 'grid', gridTemplateColumns: '56px repeat(7, 1fr)', borderBottom: '1px solid var(--border)', background: 'var(--surface-2)' }}>
          <div />
          {WEEK_DATES.map((d, i) => {
            const isToday = i === ADMIN_TODAY;
            return (
              <div key={i} style={{ padding: '11px 8px', textAlign: 'center', borderLeft: '1px solid var(--border)' }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: isToday ? 'var(--primary)' : 'var(--ink-4)', textTransform: 'uppercase' }}>{d.split(' ')[0]}</div>
                <div style={{ fontWeight: 800, fontSize: 16, color: isToday ? 'var(--primary)' : 'var(--ink)' }}>{d.split(' ')[1]}</div>
              </div>
            );
          })}
        </div>
        {/* grid */}
        <div style={{ display: 'grid', gridTemplateColumns: '56px repeat(7, 1fr)', position: 'relative' }}>
          {/* time axis */}
          <div>
            {Array.from({ length: CAL_END - CAL_START }, (_, i) => (
              <div key={i} style={{ height: HOUR_H, borderBottom: '1px solid var(--border)', position: 'relative' }}>
                <span style={{ position: 'absolute', top: -7, right: 8, fontSize: 10.5, color: 'var(--ink-4)', fontWeight: 600, fontFamily: 'var(--mono)' }}>{String(CAL_START + i).padStart(2, '0')}:00</span>
              </div>
            ))}
          </div>
          {/* day columns */}
          {WEEK_DATES.map((d, di) => (
            <div key={di} style={{ borderLeft: '1px solid var(--border)', position: 'relative', background: di === ADMIN_TODAY ? 'color-mix(in oklch, var(--primary) 4%, transparent)' : 'transparent' }}>
              {Array.from({ length: CAL_END - CAL_START }, (_, i) => (
                <div key={i} style={{ height: HOUR_H, borderBottom: '1px solid var(--border)' }} />
              ))}
              {shown.filter(s => s.day === di).map(s => {
                const c = CT[s.ct];
                const top = toMin(s.start) / 60 * HOUR_H;
                const h = Math.max((toMin(s.end) - toMin(s.start)) / 60 * HOUR_H - 4, 30);
                const full = s.booked >= s.cap;
                return (
                  <div key={s.id} title={`${c.name} · ${s.start}-${s.end}`} style={{
                    position: 'absolute', top: top + 2, left: 3, right: 3, height: h, overflow: 'hidden',
                    background: `color-mix(in oklch, ${c.color} 14%, var(--surface))`, borderLeft: `3px solid ${c.color}`,
                    borderRadius: 7, padding: '5px 7px', cursor: 'pointer',
                  }}>
                    <div style={{ fontWeight: 800, fontSize: 11, color: 'var(--ink)', display: 'flex', alignItems: 'center', gap: 4 }}>
                      <span className="mono" style={{ color: c.color }}>{c.code}</span>
                    </div>
                    <div style={{ fontSize: 10.5, color: 'var(--ink-2)', fontWeight: 600 }}>{s.start} · {INST[s.inst].initials}</div>
                    {h > 56 && <div style={{ fontSize: 10, color: 'var(--ink-3)', marginTop: 2, display: 'flex', alignItems: 'center', gap: 3 }}><Icon name="pin" size={11} sw={2.2} />{LOC[s.loc].short}</div>}
                    {h > 76 && <div style={{ position: 'absolute', bottom: 5, left: 7 }}><Badge tone={full ? 'neutral' : 'success'} size="sm">{full ? 'Full' : `${s.booked}/${s.cap}`}</Badge></div>}
                  </div>
                );
              })}
            </div>
          ))}
        </div>
      </Card>
      <div style={{ display: 'flex', gap: 18, marginTop: 14, flexWrap: 'wrap' }}>
        {COURSE_TYPES.map(c => (
          <div key={c.id} style={{ display: 'flex', alignItems: 'center', gap: 7, fontSize: 12.5, fontWeight: 600, color: 'var(--ink-2)' }}>
            <span style={{ width: 12, height: 12, borderRadius: 3, background: c.color }} />{c.name}
          </div>
        ))}
      </div>
    </div>
  );
}

/* ---------------- Logistics ---------------- */
function Logistics({ fire }) {
  const [moved, setMoved] = useStateA({});
  const totalNeeds = LOGISTICS.reduce((a, g) => a + g.need.length, 0);
  const doneCount = Object.keys(moved).length;
  return (
    <div className="ks-screen">
      <PageHead title="End-of-day bike logistics" sub={`Tomorrow (Wed 10 Jun): ${totalNeeds} bikes are at the wrong site for booked sessions.`} />
      <Card pad={13} style={{ background: 'var(--primary-tint)', border: 'none', display: 'flex', gap: 10, alignItems: 'center', marginBottom: 18 }}>
        <span style={{ color: 'var(--primary)', display: 'flex' }}><Icon name="info" size={19} sw={2.1} /></span>
        <div style={{ fontSize: 13, color: 'var(--primary-deep)', fontWeight: 600 }}>
          Derived live from current bike locations vs tomorrow's sessions. {SCHOOL.crossSiteNoticeHrs}h cross-site notice required. {doneCount}/{totalNeeds} arranged.
        </div>
      </Card>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
        {LOGISTICS.map(group => (
          <div key={group.dest}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 9, marginBottom: 10 }}>
              <div style={{ width: 32, height: 32, borderRadius: 9, display: 'grid', placeItems: 'center', background: 'var(--primary)', color: '#fff' }}><Icon name="pin" size={17} sw={2.2} /></div>
              <span style={{ fontWeight: 800, fontSize: 16 }}>{LOC[group.dest].name} needs</span>
              <Badge tone="primary">{group.need.length} {group.need.length === 1 ? 'bike' : 'bikes'}</Badge>
            </div>
            <Card pad={6}>
              {group.need.map((n, i) => {
                const bike = BIKE[n.bike], key = `${group.dest}-${n.bike}`, isMoved = moved[key];
                return (
                  <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 13, padding: '11px 12px', borderBottom: i < group.need.length - 1 ? '1px solid var(--border)' : 'none', opacity: isMoved ? 0.6 : 1 }}>
                    <BikeGlyph cat={bike.cat} size={38} />
                    <div style={{ flex: 1 }}>
                      <div style={{ fontWeight: 700, fontSize: 14.5 }}>{bike.name} <span className="mono" style={{ fontSize: 12, color: 'var(--ink-4)' }}>{bike.reg}</span></div>
                      <div style={{ fontSize: 12.5, color: 'var(--ink-3)', display: 'flex', alignItems: 'center', gap: 6, marginTop: 2 }}>
                        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}><Icon name="pin" size={13} sw={2.1} />{LOC[n.from].short}</span>
                        <Icon name="arrow-right" size={14} sw={2.2} style={{ color: 'var(--ink-4)' }} />
                        <span style={{ fontWeight: 700, color: 'var(--ink-2)' }}>{LOC[group.dest].short}</span>
                        <span style={{ color: 'var(--ink-4)' }}>· for {n.forSession}</span>
                      </div>
                    </div>
                    {isMoved
                      ? <Badge tone="success" icon="check">Arranged</Badge>
                      : <Btn size="sm" variant="secondary" icon="check" onClick={() => { setMoved(m => ({ ...m, [key]: 1 })); fire('Move scheduled', 'route'); }}>Mark moved</Btn>}
                  </div>
                );
              })}
            </Card>
          </div>
        ))}
      </div>
    </div>
  );
}

/* ---------------- Instructors ---------------- */
const INST_TONES = [277, 160, 70, 25, 195, 305, 340];
function Instructors({ fire }) {
  const [list, setList] = useStateA(INSTRUCTORS);
  const [add, setAdd] = useStateA(false);
  const [canPay, setCanPay] = useStateA(SCHOOL.instructorsCanRecordPayments);
  const togglePay = () => { const v = !canPay; setCanPay(v); SCHOOL.instructorsCanRecordPayments = v; fire(v ? 'Instructors can now record payments' : 'Payment recording turned off', 'check-circle'); };
  const save = (data) => { setList(x => [...x, { ...data, id: 'i' + Date.now(), tone: INST_TONES[x.length % INST_TONES.length] }]); setAdd(false); fire('Instructor added', 'check-circle'); };
  return (
    <div className="ks-screen">
      <PageHead title="Instructors" sub="Manage staff, qualifications & availability." actions={<Btn icon="plus" onClick={() => setAdd(true)}>Add instructor</Btn>} />
      <Card pad={16} style={{ marginBottom: 16, display: 'flex', alignItems: 'center', gap: 14 }}>
        <div style={{ width: 40, height: 40, borderRadius: 11, flexShrink: 0, display: 'grid', placeItems: 'center', background: 'var(--primary-tint)', color: 'var(--primary)' }}><Icon name="card" size={20} /></div>
        <div style={{ flex: 1 }}>
          <div style={{ fontWeight: 800, fontSize: 14.5 }}>Instructors can record payments</div>
          <div style={{ fontSize: 12.5, color: 'var(--ink-3)', lineHeight: 1.4 }}>Lets instructors take cash/card in the field (record-only — they can't void payments or edit charges). Recorded-by is logged.</div>
        </div>
        <Switch on={canPay} onClick={togglePay} />
      </Card>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 14 }}>
        {list.map(i => (
          <Card key={i.id} pad={16}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
              <Avatar initials={i.initials} tone={i.tone} size={46} />
              <div style={{ flex: 1 }}>
                <div style={{ fontWeight: 800, fontSize: 16 }}>{i.name}</div>
                <div style={{ fontSize: 12.5, color: 'var(--ink-3)', display: 'flex', alignItems: 'center', gap: 4 }}><Icon name="pin" size={13} sw={2.1} />Based at {LOC[i.home].short}</div>
              </div>
              {i.id === 'i2' ? <Badge tone="warning" icon="ban">On leave Sun</Badge> : <Badge tone="success" icon="check-circle">Available</Badge>}
            </div>
            <div style={{ display: 'flex', gap: 6, marginTop: 13, flexWrap: 'wrap' }}>
              {i.qualified.length ? i.qualified.map(q => <Badge key={q} tone="neutral" size="sm">{CT[q] ? CT[q].code : q}</Badge>) : <span style={{ fontSize: 12.5, color: 'var(--ink-4)' }}>No qualifications yet</span>}
            </div>
          </Card>
        ))}
      </div>
      <Modal open={add} onClose={() => setAdd(false)} title="Add instructor" icon="user" width={520}>
        {add && <InstructorEditor onSave={save} onCancel={() => setAdd(false)} />}
      </Modal>
    </div>
  );
}
function InstructorEditor({ onSave, onCancel }) {
  const [name, setName] = useStateA('');
  const [home, setHome] = useStateA('belfast');
  const [qualified, setQualified] = useStateA(['cbt125']);
  const initials = (name.trim().split(/\s+/).map(w => w[0]).slice(0, 2).join('') || '?').toUpperCase();
  const toggle = (id) => setQualified(q => q.includes(id) ? q.filter(x => x !== id) : [...q, id]);
  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: 12, borderRadius: 'var(--r)', background: 'var(--surface-2)', marginBottom: 18 }}>
        <Avatar initials={initials} tone={277} size={44} />
        <div style={{ fontSize: 13, color: 'var(--ink-3)', fontWeight: 600 }}>{name.trim() || 'New instructor'}</div>
      </div>
      <ALabel label="Full name"><AInput value={name} onChange={setName} placeholder="e.g. Aoife McGrath" /></ALabel>
      <div style={{ height: 16 }} />
      <ALabel label="Based at"><Seg value={home} onChange={setHome} items={LOCATIONS.map(l => ({ value: l.id, label: l.short }))} /></ALabel>
      <div style={{ height: 16 }} />
      <ALabel label="Qualified to teach">
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          {COURSE_TYPES.map(ct => {
            const on = qualified.includes(ct.id);
            return (
              <button key={ct.id} onClick={() => toggle(ct.id)} style={{
                display: 'inline-flex', alignItems: 'center', gap: 6, padding: '7px 12px', borderRadius: 'var(--r-pill)', cursor: 'pointer',
                fontFamily: 'var(--font)', fontWeight: 700, fontSize: 13, transition: 'all .14s',
                border: on ? 'none' : '1px solid var(--border-2)', background: on ? 'var(--primary)' : 'var(--surface)', color: on ? '#fff' : 'var(--ink-2)',
              }}><Icon name={on ? 'check' : 'plus'} size={14} sw={2.4} />{ct.name}</button>
            );
          })}
        </div>
      </ALabel>
      <div style={{ display: 'flex', gap: 10, marginTop: 22 }}>
        <Btn full variant="secondary" onClick={onCancel}>Cancel</Btn>
        <Btn full variant="primary" icon="check" disabled={!name.trim()} onClick={() => onSave({ name: name.trim(), initials, home, qualified })}>Add instructor</Btn>
      </div>
    </div>
  );
}

/* ---------------- Locations ---------------- */
function Locations({ fire }) {
  const [list, setList] = useStateA(LOCATIONS);
  const [add, setAdd] = useStateA(false);
  const save = (data) => { setList(x => [...x, { ...data, id: 'loc' + Date.now() }]); setAdd(false); fire('Site added', 'check-circle'); };
  return (
    <div className="ks-screen">
      <PageHead title="Locations" sub="Your training sites." actions={<Btn icon="plus" onClick={() => setAdd(true)}>Add site</Btn>} />
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 14 }}>
        {list.map(l => {
          const here = BIKES.filter(b => b.loc === l.id).length;
          return (
            <Card key={l.id} pad={0} style={{ overflow: 'hidden' }}>
              <div style={{ height: 92, background: `repeating-linear-gradient(45deg, var(--surface-3), var(--surface-3) 10px, var(--surface-2) 10px, var(--surface-2) 20px)`, display: 'grid', placeItems: 'center', position: 'relative' }}>
                <span className="mono" style={{ fontSize: 11, color: 'var(--ink-4)' }}>site map placeholder</span>
                <div style={{ position: 'absolute', top: 12, left: 12, width: 36, height: 36, borderRadius: 10, background: 'var(--primary)', color: '#fff', display: 'grid', placeItems: 'center' }}><Icon name="pin" size={19} /></div>
              </div>
              <div style={{ padding: 16 }}>
                <div style={{ fontWeight: 800, fontSize: 16 }}>{l.name}</div>
                <div style={{ fontSize: 12.5, color: 'var(--ink-3)', marginTop: 2 }}>{l.pad}</div>
                <div style={{ display: 'flex', gap: 14, marginTop: 12, fontSize: 13, fontWeight: 600, color: 'var(--ink-2)' }}>
                  <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}><Icon name="moto" size={15} sw={1.8} />{here} bikes</span>
                </div>
              </div>
            </Card>
          );
        })}
      </div>
      <Modal open={add} onClose={() => setAdd(false)} title="Add training site" icon="pin" width={480}>
        {add && <LocationEditor onSave={save} onCancel={() => setAdd(false)} />}
      </Modal>

      {/* Travel-time matrix */}
      <div style={{ marginTop: 26 }}>
        <SectionLabel>Travel-time matrix</SectionLabel>
        <Card pad={0} style={{ overflow: 'hidden' }}>
          <div style={{ padding: '12px 16px', borderBottom: '1px solid var(--border)', fontSize: 12.5, color: 'var(--ink-3)', display: 'flex', alignItems: 'center', gap: 8 }}>
            <Icon name="route" size={16} sw={2.1} style={{ color: 'var(--primary)' }} />
            Approx minutes between sites — powers tight-travel warnings on the calendar and bike-logistics feasibility. Manager's common-sense call; non-blocking.
          </div>
          <div style={{ padding: 16, overflowX: 'auto' }}>
            <table style={{ borderCollapse: 'collapse', fontSize: 13 }}>
              <thead><tr>
                <th style={{ padding: 8 }}></th>
                {LOCATIONS.map(l => <th key={l.id} style={{ padding: '8px 14px', fontSize: 12, fontWeight: 700, color: 'var(--ink-3)' }}>{l.short}</th>)}
              </tr></thead>
              <tbody>
                {LOCATIONS.map(row => (
                  <tr key={row.id}>
                    <td style={{ padding: '8px 14px 8px 8px', fontSize: 12.5, fontWeight: 700, color: 'var(--ink-2)', whiteSpace: 'nowrap' }}>{row.short}</td>
                    {LOCATIONS.map(col => {
                      const v = TRAVEL[row.id] && TRAVEL[row.id][col.id];
                      const same = row.id === col.id;
                      return (
                        <td key={col.id} style={{ padding: 6, textAlign: 'center' }}>
                          <div style={{ minWidth: 56, padding: '8px 0', borderRadius: 8, fontWeight: 700, fontSize: 13, background: same ? 'transparent' : 'var(--surface-2)', color: same ? 'var(--ink-4)' : 'var(--ink)', border: same ? 'none' : '1px solid var(--border)' }}>
                            {same ? '—' : (v != null ? `${v}m` : '·')}
                          </div>
                        </td>
                      );
                    })}
                  </tr>
                ))}
              </tbody>
            </table>
            <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 14, paddingTop: 14, borderTop: '1px solid var(--border)' }}>
              <span style={{ fontSize: 13, fontWeight: 700, color: 'var(--ink-2)' }}>Setup buffer</span>
              <Badge tone="primary">{TRAVEL_BUFFER} min</Badge>
              <span style={{ fontSize: 12.5, color: 'var(--ink-4)' }}>added to drive time for parking/setup before flagging a gap as too tight.</span>
            </div>
          </div>
        </Card>
      </div>
    </div>
  );
}
function LocationEditor({ onSave, onCancel }) {
  const [name, setName] = useStateA('');
  const [short, setShort] = useStateA('');
  const [pad, setPad] = useStateA('');
  return (
    <div>
      <ALabel label="Site name"><AInput value={name} onChange={setName} placeholder="e.g. Bangor (Balloo)" /></ALabel>
      <div style={{ height: 16 }} />
      <ALabel label="Short label"><AInput value={short} onChange={setShort} placeholder="Bangor" /></ALabel>
      <div style={{ height: 16 }} />
      <ALabel label="Training pad / address"><AInput value={pad} onChange={setPad} placeholder="Balloo Industrial Estate" /></ALabel>
      <div style={{ display: 'flex', gap: 10, marginTop: 22 }}>
        <Btn full variant="secondary" onClick={onCancel}>Cancel</Btn>
        <Btn full variant="primary" icon="check" disabled={!name.trim()} onClick={() => onSave({ name: name.trim(), short: short.trim() || name.trim(), pad: pad.trim() })}>Add site</Btn>
      </div>
    </div>
  );
}

/* ---------------- Course types ---------------- */
const PREREQ_OPTS = ['Provisional licence', 'Valid CBT', 'Theory test passed', 'Aged 24+'];
const RATIO_OPTS = ['1:1', '2:1', '3:1', '4:1'];
const ICON_OPTS = ['cap', 'target', 'navigation', 'book', 'award', 'shield'];
const COLOR_OPTS = ['var(--primary)', 'var(--success)', 'var(--warning)', 'oklch(0.6 0.17 25)', 'oklch(0.56 0.15 300)'];
const blankCourse = () => ({ id: null, code: '', name: '', icon: 'book', color: 'var(--primary)', duration: 'Half day · 4hrs', durationShort: '4h', ratio: '1:1', cat: 'A1', non_teaching: false, prereqs: ['Provisional licence'], price: '£0', blurb: '' });

function Courses({ fire }) {
  const [courses, setCourses] = useStateA(COURSE_TYPES);
  const [editor, setEditor] = useStateA(null); // {mode, course}

  const save = (data) => {
    if (editor.mode === 'new') {
      setCourses(cs => [...cs, { ...data, id: 'c' + Date.now() }]);
      fire('Course type created', 'check-circle');
    } else {
      setCourses(cs => cs.map(c => c.id === data.id ? data : c));
      fire('Course type updated', 'check-circle');
    }
    setEditor(null);
  };

  return (
    <div className="ks-screen">
      <PageHead title="Course types" sub="Per-school definitions — durations, ratios, required bikes, prerequisites & policy."
        actions={<Btn icon="plus" onClick={() => setEditor({ mode: 'new', course: blankCourse() })}>New course</Btn>} />
      <Card pad={0} style={{ overflow: 'hidden', marginBottom: 16, background: 'var(--primary-tint)', border: 'none' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '11px 16px' }}>
          <Icon name="pin" size={17} sw={2.1} style={{ color: 'var(--primary)', flexShrink: 0 }} />
          <div style={{ flex: 1, fontSize: 13, color: 'var(--primary-deep)', fontWeight: 600 }}>
            <b>Region: Northern Ireland</b> — pathway is provisional → CBT → theory → practical test, with CBT run as bike-category variants. A GB tenant would configure CBT / Mod 1 / Mod 2 instead.
          </div>
          <Badge tone="primary">{SCHOOL.body}</Badge>
        </div>
      </Card>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
        {courses.map(c => (
          <Card key={c.id} pad={0} style={{ overflow: 'hidden' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 13, padding: 16, borderBottom: '1px solid var(--border)', background: `color-mix(in oklch, ${c.color} 7%, transparent)` }}>
              <div style={{ width: 42, height: 42, borderRadius: 11, display: 'grid', placeItems: 'center', background: c.color, color: '#fff' }}><Icon name={c.icon} size={21} /></div>
              <div style={{ flex: 1 }}>
                <span className="mono" style={{ fontSize: 11, fontWeight: 700, color: c.color }}>{c.code || 'CODE'}</span>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <div style={{ fontWeight: 800, fontSize: 16.5 }}>{c.name || 'Untitled course'}</div>
                  {c.non_teaching && <Badge tone="warning" size="sm" icon="flag">Test day · no assessment</Badge>}
                </div>
              </div>
              <Btn size="sm" variant="secondary" icon="edit" onClick={() => setEditor({ mode: 'edit', course: c })}>Edit</Btn>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 1, background: 'var(--border)' }}>
              <Field label="Duration" value={c.duration} />
              <Field label="Max ratio" value={`${c.ratio} (student:instructor)`} />
              <Field label="Required bike" value={`Category ${c.cat}`} />
              <Field label="Cancellation" value={`${SCHOOL.cancelCutoffHrs}h cutoff`} />
            </div>
            <div style={{ padding: '14px 16px', display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
              <span style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--ink-3)' }}>Prerequisites:</span>
              {c.prereqs.length ? c.prereqs.map(p => <Badge key={p} tone="primary" size="sm" icon="check">{p}</Badge>) : <span style={{ fontSize: 12.5, color: 'var(--ink-4)' }}>None</span>}
              <span style={{ marginLeft: 'auto', fontWeight: 800, fontSize: 15 }}>{c.price}</span>
            </div>
          </Card>
        ))}
      </div>

      <Modal open={!!editor} onClose={() => setEditor(null)} width={560}
        title={editor?.mode === 'new' ? 'New course type' : 'Edit course type'}
        icon={editor?.mode === 'new' ? 'plus' : 'edit'}>
        {editor && <CourseEditor key={editor.course.id || 'new'} initial={editor.course} onSave={save} onCancel={() => setEditor(null)} />}
      </Modal>
    </div>
  );
}

function CourseEditor({ initial, onSave, onCancel }) {
  const [c, setC] = useStateA(initial);
  const set = (k, v) => setC(x => ({ ...x, [k]: v }));
  const togglePrereq = (p) => setC(x => ({ ...x, prereqs: x.prereqs.includes(p) ? x.prereqs.filter(q => q !== p) : [...x.prereqs, p] }));
  const valid = c.name.trim() && c.code.trim();
  return (
    <div>
      {/* preview header */}
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: 12, borderRadius: 'var(--r)', background: `color-mix(in oklch, ${c.color} 9%, transparent)`, marginBottom: 18 }}>
        <div style={{ width: 42, height: 42, borderRadius: 11, display: 'grid', placeItems: 'center', background: c.color, color: '#fff', flexShrink: 0 }}><Icon name={c.icon} size={21} /></div>
        <div style={{ minWidth: 0 }}>
          <span className="mono" style={{ fontSize: 11, fontWeight: 700, color: c.color }}>{c.code || 'CODE'}</span>
          <div style={{ fontWeight: 800, fontSize: 16, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{c.name || 'Untitled course'}</div>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 16 }}>
        <ALabel label="Course name"><AInput value={c.name} onChange={v => set('name', v)} placeholder="e.g. CBT (650cc)" /></ALabel>
        <ALabel label="Short code"><AInput value={c.code} onChange={v => set('code', v.toUpperCase())} placeholder="CBT 650" /></ALabel>
      </div>

      <div style={{ display: 'flex', gap: 24, marginBottom: 16, flexWrap: 'wrap' }}>
        <div>
          <ALabel label="Icon">
            <div style={{ display: 'flex', gap: 6 }}>
              {ICON_OPTS.map(ic => (
                <button key={ic} onClick={() => set('icon', ic)} style={{ width: 34, height: 34, borderRadius: 9, cursor: 'pointer', display: 'grid', placeItems: 'center', border: c.icon === ic ? '2px solid var(--primary)' : '1px solid var(--border-2)', background: 'var(--surface)', color: 'var(--ink-2)' }}><Icon name={ic} size={18} /></button>
              ))}
            </div>
          </ALabel>
        </div>
        <div>
          <ALabel label="Accent">
            <div style={{ display: 'flex', gap: 7 }}>
              {COLOR_OPTS.map(col => (
                <button key={col} onClick={() => set('color', col)} title="accent" style={{ width: 28, height: 28, borderRadius: 999, cursor: 'pointer', background: col, border: c.color === col ? '2px solid var(--surface)' : '2px solid transparent', boxShadow: c.color === col ? `0 0 0 2px ${col}` : '0 0 0 1px var(--border-2)' }} />
              ))}
            </div>
          </ALabel>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 16 }}>
        <ALabel label="Duration"><AInput value={c.duration} onChange={v => set('duration', v)} placeholder="1 day · 8hrs" /></ALabel>
        <ALabel label="Price"><AInput value={c.price} onChange={v => set('price', v)} placeholder="£139" /></ALabel>
      </div>

      <div style={{ display: 'flex', gap: 24, marginBottom: 16, flexWrap: 'wrap' }}>
        <ALabel label="Max student : instructor ratio"><Seg value={c.ratio} onChange={v => set('ratio', v)} items={RATIO_OPTS} /></ALabel>
        <ALabel label="Required bike category"><Seg value={c.cat} onChange={v => set('cat', v)} items={['A1', 'A2', 'A']} /></ALabel>
      </div>

      <ALabel label="Prerequisites">
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          {PREREQ_OPTS.map(p => {
            const on = c.prereqs.includes(p);
            return (
              <button key={p} onClick={() => togglePrereq(p)} style={{
                display: 'inline-flex', alignItems: 'center', gap: 6, padding: '7px 12px', borderRadius: 'var(--r-pill)', cursor: 'pointer',
                fontFamily: 'var(--font)', fontWeight: 700, fontSize: 13, transition: 'all .14s',
                border: on ? 'none' : '1px solid var(--border-2)', background: on ? 'var(--primary)' : 'var(--surface)', color: on ? '#fff' : 'var(--ink-2)',
              }}>
                <Icon name={on ? 'check' : 'plus'} size={14} sw={2.4} />{p}
              </button>
            );
          })}
        </div>
      </ALabel>

      <label style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '11px 13px', borderRadius: 'var(--r-sm)', border: '1px solid var(--border-2)', cursor: 'pointer', marginTop: 16 }}>
        <input type="checkbox" checked={!!c.non_teaching} onChange={e => set('non_teaching', e.target.checked)} style={{ width: 17, height: 17, accentColor: 'var(--primary)' }} />
        <div>
          <div style={{ fontSize: 13.5, fontWeight: 700, color: 'var(--ink)' }}>Test day (non-teaching)</div>
          <div style={{ fontSize: 12, color: 'var(--ink-4)' }}>Reserves a bike + escort and charges like any course, but skips competency assessment.</div>
        </div>
      </label>

      <div style={{ display: 'flex', gap: 10, marginTop: 22 }}>
        <Btn full variant="secondary" onClick={onCancel}>Cancel</Btn>
        <Btn full variant="primary" icon="check" disabled={!valid} onClick={() => onSave(c)}>{initial.id ? 'Save changes' : 'Create course'}</Btn>
      </div>
    </div>
  );
}
function ALabel({ label, children }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <span style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--ink-2)' }}>{label}</span>
      {children}
    </div>
  );
}
function AInput({ value, onChange, placeholder }) {
  return (
    <input value={value} onChange={e => onChange(e.target.value)} placeholder={placeholder}
      style={{ width: '100%', height: 42, padding: '0 13px', borderRadius: 'var(--r-sm)', border: '1px solid var(--border-2)', background: 'var(--surface)', fontFamily: 'var(--font)', fontSize: 14.5, fontWeight: 500, color: 'var(--ink)', outline: 'none', boxSizing: 'border-box' }} />
  );
}
function Field({ label, value }) {
  return (
    <div style={{ background: 'var(--surface)', padding: '13px 16px' }}>
      <div style={{ fontSize: 11, fontWeight: 700, letterSpacing: '0.03em', textTransform: 'uppercase', color: 'var(--ink-4)' }}>{label}</div>
      <div style={{ fontWeight: 700, fontSize: 14, marginTop: 3 }}>{value}</div>
    </div>
  );
}

/* =============================================================== */
/* Reimbursements — admin review of instructor expenses               */
/* =============================================================== */

function ReimbursementsScreen({ fire }) {
  const [tab, setTab] = useStateA('pending');
  const [open, setOpen] = useStateA(null);  // expense being viewed (any state)
  const [rejectFor, setRejectFor] = useStateA(null);
  const [approveFor, setApproveFor] = useStateA(null); // optional approval note
  const [manageCats, setManageCats] = useStateA(false);

  const pending = EXPENSES.filter(e => e.status === 'pending');
  const approved = EXPENSES.filter(e => e.status === 'approved');
  const reimbursed = EXPENSES.filter(e => e.status === 'reimbursed');
  const rejected = EXPENSES.filter(e => e.status === 'rejected');

  const pendingTotal = pending.reduce((s, e) => s + e.amount, 0);
  const approvedTotal = approved.reduce((s, e) => s + e.amount, 0);
  const monthSpend = [...reimbursed, ...approved].reduce((s, e) => s + e.amount, 0);

  const rows = tab === 'pending' ? pending
              : tab === 'approved' ? approved
              : tab === 'reimbursed' ? reimbursed
              : rejected;

  return (
    <div className="ks-screen">
      <PageHead title="Reimbursements" sub="Instructor-submitted expenses: review, approve, and mark reimbursed." actions={<Btn variant="secondary" icon="sliders" onClick={() => setManageCats(true)}>Manage types</Btn>} />

      {/* KPI row */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 14, marginBottom: 18 }}>
        <ReimbKPI tone="warning" label="Pending review" value={`£${pendingTotal.toFixed(2)}`} foot={`${pending.length} item${pending.length === 1 ? '' : 's'}`} icon="alert" />
        <ReimbKPI tone="primary" label="Approved, owed" value={`£${approvedTotal.toFixed(2)}`} foot={`${approved.length} item${approved.length === 1 ? '' : 's'} · ready to pay`} icon="card" />
        <ReimbKPI tone="success" label="This month" value={`£${monthSpend.toFixed(2)}`} foot="Approved + reimbursed" icon="check-circle" />
      </div>

      {/* Tabs */}
      <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
        <Seg value={tab} onChange={setTab} items={[
          { value: 'pending',    label: `Pending (${pending.length})` },
          { value: 'approved',   label: `Approved (${approved.length})` },
          { value: 'reimbursed', label: `Reimbursed (${reimbursed.length})` },
          { value: 'rejected',   label: `Rejected (${rejected.length})` },
        ]} />
      </div>

      <Card pad={0} style={{ overflow: 'hidden' }}>
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13.5 }}>
          <thead>
            <tr style={{ background: 'var(--surface-2)', textAlign: 'left' }}>
              {['Instructor', 'Receipt', 'Category', 'Amount', 'When · Where', tab === 'reimbursed' ? 'Paid' : tab === 'rejected' ? 'Rejected' : 'Status', ''].map((h, i) => (
                <th key={i} style={{ padding: '11px 16px', fontSize: 11.5, fontWeight: 700, letterSpacing: '0.04em', textTransform: 'uppercase', color: 'var(--ink-3)' }}>{h}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {rows.map(e => {
              const inst = INST[e.instr];
              const cat = expenseCat(e.cat);
              const catColour = `oklch(0.55 0.14 ${cat.tone})`;
              return (
                <tr key={e.id} style={{ borderTop: '1px solid var(--border)' }}>
                  <td style={{ padding: '12px 16px' }}>
                    <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                      <Avatar initials={inst.initials} tone={inst.tone} size={32} />
                      <div>
                        <div style={{ fontWeight: 700 }}>{inst.name}</div>
                        <div style={{ fontSize: 11.5, color: 'var(--ink-3)' }}>{LOC[inst.home].short}</div>
                      </div>
                    </div>
                  </td>
                  <td style={{ padding: '12px 16px' }}>
                    <button onClick={() => setOpen(e)} title="View full details" style={{ width: 44, height: 44, borderRadius: 8, background: `repeating-linear-gradient(135deg, var(--surface-3) 0 6px, var(--surface-2) 6px 12px)`, border: '1px solid var(--border)', cursor: 'pointer', padding: 0, position: 'relative' }}>
                      <div style={{ position: 'absolute', inset: 0, display: 'grid', placeItems: 'center', color: 'var(--ink-4)' }}><Icon name="ticket" size={16} sw={1.8} /></div>
                    </button>
                  </td>
                  <td style={{ padding: '12px 16px' }}>
                    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '4px 10px', borderRadius: 99, background: `color-mix(in oklch, ${catColour} 14%, transparent)`, color: catColour, fontWeight: 800, fontSize: 12 }}>
                      <Icon name={cat.icon} size={13} sw={2.2} />{cat.label}
                    </span>
                  </td>
                  <td style={{ padding: '12px 16px', fontWeight: 800 }}>£{e.amount.toFixed(2)}</td>
                  <td style={{ padding: '12px 16px', color: 'var(--ink-2)' }}>
                    <div>{e.when}</div>
                    <div style={{ fontSize: 12, color: 'var(--ink-3)' }}>{e.where || '—'}</div>
                  </td>
                  <td style={{ padding: '12px 16px' }}>
                    {e.status === 'reimbursed' ? <span style={{ fontSize: 12.5, color: 'var(--ink-2)', fontWeight: 700 }}>{e.paidOn || ''} · {e.paidVia || ''}</span>
                      : e.status === 'rejected' ? <span style={{ fontSize: 12.5, color: 'var(--danger)', fontWeight: 700 }}>{e.rejectReason || 'Rejected'}</span>
                      : statusPill(e.status)}
                  </td>
                  <td style={{ padding: '12px 16px', textAlign: 'right', whiteSpace: 'nowrap' }}>
                    {e.status === 'pending' && (
                      <div style={{ display: 'inline-flex', gap: 6 }}>
                        <Btn size="sm" variant="secondary" icon="x" onClick={() => setRejectFor(e)}>Reject</Btn>
                        <Btn size="sm" variant="success" icon="check" onClick={() => setApproveFor(e)}>Approve</Btn>
                      </div>
                    )}
                    {e.status === 'approved' && (
                      <Btn size="sm" variant="primary" icon="card" onClick={() => fire(`Marked £${e.amount.toFixed(2)} as reimbursed`, 'check-circle')}>Mark reimbursed</Btn>
                    )}
                    {(e.status === 'reimbursed' || e.status === 'rejected') && (
                      <Btn size="sm" variant="soft" onClick={() => setOpen(e)}>View</Btn>
                    )}
                  </td>
                </tr>
              );
            })}
            {rows.length === 0 && (
              <tr><td colSpan={7} style={{ padding: 32, textAlign: 'center', color: 'var(--ink-3)', fontSize: 13.5 }}>Nothing to show here.</td></tr>
            )}
          </tbody>
        </table>
      </Card>

      {/* Full expense detail modal — shown when clicking any row */}
      <Modal open={!!open} onClose={() => setOpen(null)} title="Expense detail" icon="ticket" width={720}>
        {open && <ExpenseDetailBody expense={open} onClose={() => setOpen(null)} onApprove={() => { setOpen(null); setApproveFor(open); }} onReject={() => { setOpen(null); setRejectFor(open); }} onReimburse={() => { setOpen(null); fire(`Marked £${open.amount.toFixed(2)} as reimbursed`, 'check-circle'); }} />}
      </Modal>

      {/* Approve with optional note */}
      <Modal open={!!approveFor} onClose={() => setApproveFor(null)} title="Approve expense" icon="check-circle" tone="success" width={440}>
        {approveFor && <ApproveBody expense={approveFor} onClose={() => setApproveFor(null)} onDone={() => { setApproveFor(null); fire(`Approved £${approveFor.amount.toFixed(2)} · instructor notified`, 'check-circle'); }} />}
      </Modal>

      {/* Reject reason modal */}
      <Modal open={!!rejectFor} onClose={() => setRejectFor(null)} title="Reject expense" icon="x-circle" tone="danger" width={440}>
        {rejectFor && <RejectBody expense={rejectFor} onClose={() => setRejectFor(null)} onDone={() => { setRejectFor(null); fire(`Rejected £${rejectFor.amount.toFixed(2)} · instructor notified`, 'x-circle'); }} />}
      </Modal>

      {/* Manage categories modal — admin curates the list shown to instructors */}
      <Modal open={manageCats} onClose={() => setManageCats(false)} title="Reimbursement types" icon="sliders" width={520}>
        {manageCats && <ManageCategoriesBody onClose={() => setManageCats(false)} onDone={() => { setManageCats(false); fire('Categories saved', 'check-circle'); }} />}
      </Modal>
    </div>
  );
}

/* ---- Full expense detail modal (used in admin queue) ---- */

function ExpenseDetailBody({ expense, onClose, onApprove, onReject, onReimburse }) {
  const inst = INST[expense.instr];
  const cat = expenseCat(expense.cat);
  const catColour = `oklch(0.55 0.14 ${cat.tone})`;

  // Build a status timeline: every state transition we know about.
  const timeline = [
    { label: 'Submitted', who: inst.name, when: expense.submittedAt || expense.when, icon: 'plus', tone: 'var(--primary)' },
  ];
  if (expense.reviewedOn) {
    timeline.push({
      label: expense.status === 'rejected' ? 'Rejected' : 'Approved',
      who: expense.reviewedBy || 'Owner',
      when: expense.reviewedOn,
      icon: expense.status === 'rejected' ? 'x-circle' : 'check-circle',
      tone: expense.status === 'rejected' ? 'var(--danger)' : 'var(--success)',
    });
  }
  if (expense.paidOn) {
    timeline.push({
      label: 'Reimbursed',
      who: expense.paidBy || 'Owner',
      when: `${expense.paidOn} · ${expense.paidVia || ''}`,
      icon: 'card',
      tone: 'var(--success)',
    });
  }

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 18 }}>
        {/* Left column — receipt */}
        <div>
          <div style={{ width: '100%', height: 320, borderRadius: 'var(--r)', background: `repeating-linear-gradient(135deg, var(--surface-3) 0 8px, var(--surface-2) 8px 16px)`, position: 'relative', overflow: 'hidden' }}>
            <div style={{ position: 'absolute', inset: 0, display: 'grid', placeItems: 'center', color: 'var(--ink-4)' }}><Icon name="ticket" size={72} sw={1.3} /></div>
            <div style={{ position: 'absolute', top: 10, left: 10, padding: '4px 9px', borderRadius: 99, background: 'var(--surface)', color: 'var(--ink-2)', fontSize: 11.5, fontWeight: 800, boxShadow: 'var(--sh-1)' }}>Receipt.jpg</div>
          </div>
          <div style={{ marginTop: 10, fontSize: 12, color: 'var(--ink-4)', textAlign: 'center' }}>Click to view full size · download original</div>
        </div>

        {/* Right column — meta */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <Avatar initials={inst.initials} tone={inst.tone} size={40} />
            <div style={{ flex: 1 }}>
              <div style={{ fontWeight: 800, fontSize: 15 }}>{inst.name}</div>
              <div style={{ fontSize: 12, color: 'var(--ink-3)' }}>{LOC[inst.home].short}</div>
            </div>
            {statusPill(expense.status)}
          </div>

          <div style={{ display: 'flex', alignItems: 'baseline', gap: 12, marginTop: 4 }}>
            <span style={{ fontWeight: 800, fontSize: 32, letterSpacing: '-0.04em' }}>£{expense.amount.toFixed(2)}</span>
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, padding: '4px 10px', borderRadius: 99, background: `color-mix(in oklch, ${catColour} 14%, transparent)`, color: catColour, fontWeight: 800, fontSize: 12 }}><Icon name={cat.icon} size={13} sw={2.2} />{cat.label}</span>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginTop: 6 }}>
            <Field label="When" value={expense.when} />
            <Field label="Where" value={expense.where || '—'} />
          </div>

          {expense.note && (
            <div>
              <div style={{ fontSize: 11.5, fontWeight: 800, color: 'var(--ink-3)', letterSpacing: 0.3, textTransform: 'uppercase', marginBottom: 4 }}>Instructor note</div>
              <div style={{ padding: 12, borderRadius: 'var(--r-sm)', background: 'var(--surface-2)', fontSize: 13.5, color: 'var(--ink-2)' }}>{expense.note}</div>
            </div>
          )}

          {expense.reviewerNote && (
            <div>
              <div style={{ fontSize: 11.5, fontWeight: 800, color: 'var(--ink-3)', letterSpacing: 0.3, textTransform: 'uppercase', marginBottom: 4 }}>Reviewer note</div>
              <div style={{ padding: 12, borderRadius: 'var(--r-sm)', background: expense.status === 'rejected' ? 'color-mix(in oklch, var(--danger) 7%, transparent)' : 'var(--surface-2)', fontSize: 13.5, color: 'var(--ink-2)' }}>{expense.reviewerNote}</div>
            </div>
          )}
        </div>
      </div>

      {/* Timeline */}
      <div style={{ marginTop: 18, padding: '14px 16px', borderRadius: 'var(--r)', background: 'var(--surface-2)' }}>
        <div style={{ fontSize: 11.5, fontWeight: 800, color: 'var(--ink-3)', letterSpacing: 0.3, textTransform: 'uppercase', marginBottom: 10 }}>Timeline</div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {timeline.map((t, i) => (
            <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 11 }}>
              <div style={{ width: 28, height: 28, borderRadius: 99, display: 'grid', placeItems: 'center', background: `color-mix(in oklch, ${t.tone} 14%, transparent)`, color: t.tone, flexShrink: 0 }}><Icon name={t.icon} size={15} sw={2.2} /></div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontWeight: 700, fontSize: 13.5 }}>{t.label} <span style={{ color: 'var(--ink-3)', fontWeight: 600 }}>· {t.who}</span></div>
                <div style={{ fontSize: 12, color: 'var(--ink-4)' }}>{t.when}</div>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* Actions footer */}
      <div style={{ display: 'flex', gap: 10, marginTop: 18 }}>
        <Btn variant="secondary" onClick={onClose} style={{ flex: 1 }}>Close</Btn>
        {expense.status === 'pending' && (
          <div style={{ display: 'contents' }}>
            <Btn variant="danger" icon="x" onClick={onReject} style={{ flex: 1 }}>Reject…</Btn>
            <Btn variant="success" icon="check" onClick={onApprove} style={{ flex: 1 }}>Approve…</Btn>
          </div>
        )}
        {expense.status === 'approved' && (
          <Btn variant="primary" icon="card" onClick={onReimburse} style={{ flex: 1 }}>Mark reimbursed</Btn>
        )}
      </div>
    </div>
  );
}

function ApproveBody({ expense, onClose, onDone }) {
  const [reviewerNote, setReviewerNote] = useStateA('');
  return (
    <div>
      <div style={{ padding: 12, borderRadius: 'var(--r)', background: 'var(--surface-2)', display: 'flex', alignItems: 'center', gap: 11, marginBottom: 16 }}>
        <Avatar initials={INST[expense.instr].initials} tone={INST[expense.instr].tone} size={34} />
        <div style={{ flex: 1 }}><div style={{ fontWeight: 800 }}>{INST[expense.instr].name}</div><div style={{ fontSize: 12, color: 'var(--ink-3)' }}>£{expense.amount.toFixed(2)} · {expenseCat(expense.cat).label} · {expense.when}</div></div>
      </div>
      <ALabel label="Note (optional)"><AInput value={reviewerNote} onChange={setReviewerNote} placeholder="e.g. Include in next payroll only." /></ALabel>
      <div style={{ fontSize: 12, color: 'var(--ink-4)', fontWeight: 600, marginTop: 10 }}>Visible to {INST[expense.instr].name} on their expense detail.</div>
      <div style={{ display: 'flex', gap: 10, marginTop: 16 }}>
        <Btn full variant="secondary" onClick={onClose}>Cancel</Btn>
        <Btn full variant="success" icon="check" onClick={onDone}>Approve expense</Btn>
      </div>
    </div>
  );
}

function ReimbKPI({ tone, label, value, foot, icon }) {
  const colour = tone === 'warning' ? 'var(--warning)' : tone === 'primary' ? 'var(--primary)' : 'var(--success)';
  return (
    <Card pad={16}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <div style={{ width: 36, height: 36, borderRadius: 10, background: `color-mix(in oklch, ${colour} 14%, transparent)`, color: colour, display: 'grid', placeItems: 'center' }}><Icon name={icon} size={18} sw={2.1} /></div>
        <div style={{ fontSize: 12, color: 'var(--ink-3)', fontWeight: 700, letterSpacing: 0.3, textTransform: 'uppercase' }}>{label}</div>
      </div>
      <div style={{ fontWeight: 800, fontSize: 26, letterSpacing: '-0.04em', marginTop: 8 }}>{value}</div>
      <div style={{ fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 600, marginTop: 2 }}>{foot}</div>
    </Card>
  );
}

function RejectBody({ expense, onClose, onDone }) {
  const [reason, setReason] = useStateA('');
  return (
    <div>
      <div style={{ padding: 12, borderRadius: 'var(--r)', background: 'var(--surface-2)', display: 'flex', alignItems: 'center', gap: 11, marginBottom: 16 }}>
        <Avatar initials={INST[expense.instr].initials} tone={INST[expense.instr].tone} size={34} />
        <div style={{ flex: 1 }}><div style={{ fontWeight: 800 }}>{INST[expense.instr].name}</div><div style={{ fontSize: 12, color: 'var(--ink-3)' }}>£{expense.amount.toFixed(2)} · {expenseCat(expense.cat).label} · {expense.when}</div></div>
      </div>
      <ALabel label="Reason"><AInput value={reason} onChange={setReason} placeholder="Outside policy, missing receipt, duplicate…" /></ALabel>
      <div style={{ fontSize: 12, color: 'var(--ink-4)', fontWeight: 600, marginTop: 10 }}>The instructor will see this on their expense detail screen.</div>
      <div style={{ display: 'flex', gap: 10, marginTop: 16 }}>
        <Btn full variant="secondary" onClick={onClose}>Cancel</Btn>
        <Btn full variant="danger" icon="x" disabled={!reason.trim()} onClick={onDone}>Reject expense</Btn>
      </div>
    </div>
  );
}

/* ---- Manage categories (admin curates the list of reimbursable types) ---- */

const CAT_ICONS = ['fuel', 'cap', 'pin', 'route', 'card', 'wrench', 'shield', 'building', 'phone', 'more-h'];
const CAT_TONES = [25, 70, 160, 200, 277];

function ManageCategoriesBody({ onClose, onDone }) {
  const [cats, setCats] = useStateA(EXPENSE_CATEGORIES.map(c => ({ ...c })));
  const add = () => setCats(xs => [...xs, { id: 'new' + Date.now(), label: 'New type', icon: 'more-h', tone: 277 }]);
  const remove = (id) => setCats(xs => xs.filter(c => c.id !== id));
  const updateRow = (id, patch) => setCats(xs => xs.map(c => c.id === id ? { ...c, ...patch } : c));

  return (
    <div>
      <div style={{ fontSize: 13, color: 'var(--ink-2)', marginBottom: 12 }}>
        Pick which reimbursement types your instructors can submit. Existing expenses already tagged with a type are unaffected if you remove it.
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        {cats.map(c => {
          const colour = `oklch(0.55 0.14 ${c.tone})`;
          return (
            <div key={c.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 10px', borderRadius: 'var(--r-sm)', border: '1px solid var(--border)', background: 'var(--surface)' }}>
              {/* icon picker — click to cycle */}
              <button onClick={() => updateRow(c.id, { icon: CAT_ICONS[(CAT_ICONS.indexOf(c.icon) + 1) % CAT_ICONS.length] })} title="Cycle icon" style={{ width: 38, height: 38, borderRadius: 10, background: `color-mix(in oklch, ${colour} 14%, transparent)`, color: colour, border: 'none', cursor: 'pointer', display: 'grid', placeItems: 'center' }}>
                <Icon name={c.icon} size={18} sw={2.1} />
              </button>
              {/* label */}
              <input value={c.label} onChange={e => updateRow(c.id, { label: e.target.value })} style={{ flex: 1, height: 38, padding: '0 12px', borderRadius: 'var(--r-sm)', border: '1px solid var(--border-2)', background: 'var(--surface-2)', fontSize: 14, fontWeight: 600, fontFamily: 'var(--font)', color: 'var(--ink)' }} />
              {/* tone picker — small dots */}
              <div style={{ display: 'flex', gap: 4 }}>
                {CAT_TONES.map(t => {
                  const dot = `oklch(0.55 0.14 ${t})`;
                  return (
                    <button key={t} onClick={() => updateRow(c.id, { tone: t })} title={`Tone ${t}`} style={{ width: 18, height: 18, borderRadius: 99, background: dot, border: c.tone === t ? '2px solid var(--ink)' : '2px solid transparent', cursor: 'pointer', padding: 0 }} />
                  );
                })}
              </div>
              {/* delete */}
              <button onClick={() => remove(c.id)} title="Delete" style={{ width: 32, height: 32, borderRadius: 8, border: '1px solid var(--border)', background: 'transparent', color: 'var(--ink-3)', cursor: 'pointer', display: 'grid', placeItems: 'center' }}>
                <Icon name="trash" size={15} sw={2} />
              </button>
            </div>
          );
        })}
      </div>
      <button onClick={add} style={{ marginTop: 10, display: 'flex', alignItems: 'center', gap: 6, padding: '9px 12px', borderRadius: 'var(--r-sm)', border: '1.5px dashed var(--border-2)', background: 'transparent', color: 'var(--ink-2)', cursor: 'pointer', fontWeight: 700, fontSize: 13, fontFamily: 'var(--font)' }}>
        <Icon name="plus" size={15} sw={2.4} /> Add type
      </button>
      <div style={{ display: 'flex', gap: 10, marginTop: 18 }}>
        <Btn full variant="secondary" onClick={onClose}>Cancel</Btn>
        <Btn full variant="primary" icon="check" onClick={onDone}>Save changes</Btn>
      </div>
    </div>
  );
}

Object.assign(window, { AdminApp });
