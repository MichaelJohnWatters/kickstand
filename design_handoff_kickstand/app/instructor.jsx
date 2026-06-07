// Kickstand — Instructor app: schedule (day/week), session detail, attendance,
// competency sign-off, availability editor.
const { useState: useStateI } = React;

const THIS_INST = INSTRUCTORS[0]; // Mark Doherty

// Mark's week (Mon=0..Sun=6). today = Tue (1).
const INST_WEEK = [
  { day: 1, ct: 'cbt125',  start: '08:30', end: '16:30', loc: 'belfast', roster: [
    { s: 's2', bike: 'b1', attend: 'present' },
    { s: 's3', bike: 'b4', attend: 'present' },
    { s: 's6', bike: 'b3', attend: null },
  ]},
  { day: 2, ct: 'practical', start: '09:00', end: '13:00', loc: 'belfast', roster: [{ s: 's5', bike: 'b5', attend: null }] },
  { day: 2, ct: 'practicaltest', start: '10:15', end: '11:15', loc: 'belfast', roster: [{ s: 's7', bike: 'b5', attend: null }] },
  { day: 4, ct: 'practical', start: '13:30', end: '17:30', loc: 'belfast', roster: [{ s: 's7', bike: 'b5', attend: null }] },
];
const TODAY = 1;

function InstructorApp({ theme }) {
  const [tab, setTab] = useStateI('schedule');
  const [detail, setDetail] = useStateI(null);   // session obj
  const [capture, setCapture] = useStateI(null);  // {session, studentId}
  const [toast, setToast] = useStateI(null);
  const [share, setShare] = useStateI(null);
  const [notif, setNotif] = useStateI(false);
  const [prefs, setPrefs] = useStateI(false);
  const [pay, setPay] = useStateI(null); // {studentId}
  const [expFlow, setExpFlow] = useStateI(null); // null | 'add' | { id } (detail)
  const fire = (msg, icon) => { setToast({ msg, icon }); setTimeout(() => setToast(null), 2000); };

  const tabs = [
    { id: 'schedule', label: 'Schedule', icon: 'calendar' },
    { id: 'avail',    label: 'Availability', icon: 'clock' },
    { id: 'expenses', label: 'Expenses', icon: 'card' },
    { id: 'profile',  label: 'Profile', icon: 'user' },
  ];

  let body;
  if (capture) body = <CompetencyCapture session={capture.session} studentId={capture.studentId} onBack={() => setCapture(null)} onSave={() => { setCapture(null); fire('Progress saved', 'check-circle'); }} theme={theme} />;
  else if (detail) body = <SessionDetail session={detail} onBack={() => setDetail(null)} onCapture={(sid) => setCapture({ session: detail, studentId: sid })} fire={fire} onShare={setShare} onPay={setPay} />;
  else if (expFlow === 'add') body = <ExpenseAdd onBack={() => setExpFlow(null)} onSubmit={() => { setExpFlow(null); fire('Expense submitted for review', 'check-circle'); }} />;
  else if (expFlow && expFlow.id) body = <ExpenseDetail expense={EXPENSES.find(e => e.id === expFlow.id)} onBack={() => setExpFlow(null)} fire={fire} onWithdraw={() => { setExpFlow(null); fire('Expense withdrawn', 'check-circle'); }} />;
  else if (tab === 'schedule') body = <InstSchedule onOpen={setDetail} onShare={setShare} onBell={() => setNotif(true)} />;
  else if (tab === 'avail') body = <Availability fire={fire} />;
  else if (tab === 'expenses') body = <InstExpenses onAdd={() => setExpFlow('add')} onOpen={(id) => setExpFlow({ id })} />;
  else if (tab === 'profile') body = <InstProfile onPrefs={() => setPrefs(true)} />;

  const showTabs = !detail && !capture && expFlow == null;
  return (
    <IOSDevice dark={theme === 'dark'}>
      <div style={{ height: '100%', display: 'flex', flexDirection: 'column', background: 'var(--bg)' }}>
        <div style={{ flex: 1, overflowY: 'auto', paddingTop: 54 }}>{body}</div>
        {showTabs && <TabBar tabs={tabs} active={tab} onChange={setTab} />}
      </div>
      {toast && <Toast {...toast} />}
      {share && <ShareSheet open={!!share} onClose={() => setShare(null)} {...share} />}
      <Sheet open={!!pay} onClose={() => setPay(null)} title="Record a payment">
        {pay && <InstrPaymentForm studentId={pay.studentId} onClose={() => setPay(null)} onDone={() => { setPay(null); fire('Payment recorded · by you', 'check-circle'); }} />}
      </Sheet>
      <NotifCenter open={notif} onClose={() => setNotif(false)} role="instructor" mobile onOpenPrefs={() => { setNotif(false); setPrefs(true); }} />
      <NotifPrefs open={prefs} onClose={() => setPrefs(false)} mobile />
    </IOSDevice>
  );
}

/* ---------------- Schedule ---------------- */
function InstSchedule({ onOpen, onShare, onBell }) {
  const [view, setView] = useStateI('day');
  return (
    <div className="ks-screen" style={{ padding: '0 18px 20px' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '4px 0 14px' }}>
        <div>
          <div style={{ fontSize: 13.5, color: 'var(--ink-3)', fontWeight: 600 }}>{THIS_INST.name}</div>
          <div style={{ fontWeight: 800, fontSize: 25, letterSpacing: '-0.03em' }}>Schedule</div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
          <NotifBell role="instructor" onClick={onBell} style={iIconBtn} />
          <button onClick={() => onShare({ title: `Join ${SCHOOL.short}`, subtitle: 'Show a new rider this code — they scan to sign up and book with your school.', url: typeof window !== 'undefined' ? window.location.href : '', caption: 'lagan-valley.kickstand.app/join' })}
            style={iIconBtn} title="Show join code"><Icon name="qr" size={19} /></button>
          <Avatar initials={THIS_INST.initials} tone={THIS_INST.tone} size={42} />
        </div>
      </div>
      <Seg full value={view} onChange={setView} items={[{ value: 'day', label: 'Day' }, { value: 'week', label: 'Week' }]} />
      {view === 'day' ? <DayView onOpen={onOpen} /> : <WeekView onOpen={onOpen} />}
    </div>
  );
}

function DayView({ onOpen }) {
  const today = INST_WEEK.filter(s => s.day === TODAY);
  return (
    <div style={{ marginTop: 16 }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 14 }}>
        <Badge tone="primary" icon="calendar">Today</Badge>
        <span style={{ fontWeight: 700, fontSize: 15 }}>Tuesday 9 June</span>
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        {today.map((s, i) => <SessionCard key={i} s={s} onOpen={onOpen} live />)}
      </div>
      <div style={{ marginTop: 22 }}><SectionLabel>Coming up this week</SectionLabel></div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        {INST_WEEK.filter(s => s.day > TODAY).map((s, i) => <SessionCard key={i} s={s} onOpen={onOpen} />)}
      </div>
    </div>
  );
}

function SessionCard({ s, onOpen, live }) {
  const c = CT[s.ct];
  const present = s.roster.filter(r => r.attend === 'present').length;
  return (
    <Card pad={0} hover onClick={() => onOpen(s)} style={{ overflow: 'hidden' }}>
      <div style={{ display: 'flex' }}>
        <div style={{ width: 5, background: c.color }} />
        <div style={{ flex: 1, padding: 15 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <span className="mono" style={{ fontSize: 10.5, fontWeight: 700, color: c.color }}>{c.code}</span>
                {live && <Badge tone="success" size="sm">In progress</Badge>}
              </div>
              <div style={{ fontWeight: 800, fontSize: 16.5, letterSpacing: '-0.02em', marginTop: 2 }}>{c.name}</div>
            </div>
            <Icon name="right" size={20} style={{ color: 'var(--ink-4)' }} />
          </div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '7px 15px', marginTop: 11, fontSize: 13, color: 'var(--ink-2)', fontWeight: 600 }}>
            <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}><Icon name="clock" size={15} sw={2} />{s.start}–{s.end}</span>
            <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}><Icon name="pin" size={15} sw={2} />{LOC[s.loc].short}</span>
            <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}><Icon name="users" size={15} sw={2} />{s.roster.length} {s.roster.length === 1 ? 'student' : 'students'}</span>
          </div>
          {/* avatars */}
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 12 }}>
            <div style={{ display: 'flex' }}>
              {s.roster.map((r, i) => (
                <div key={i} style={{ marginLeft: i ? -8 : 0 }}><Avatar initials={STU[r.s].initials} tone={(i*60+277)%360} size={28} ring /></div>
              ))}
            </div>
            {live && <span style={{ fontSize: 12, color: 'var(--ink-3)', fontWeight: 600 }}>{present}/{s.roster.length} checked in</span>}
          </div>
        </div>
      </div>
    </Card>
  );
}

function WeekView({ onOpen }) {
  return (
    <div style={{ marginTop: 16, display: 'flex', flexDirection: 'column', gap: 6 }}>
      {WEEK_DATES.map((d, idx) => {
        const items = INST_WEEK.filter(s => s.day === idx);
        const isToday = idx === TODAY;
        return (
          <div key={idx} style={{ display: 'flex', gap: 12 }}>
            <div style={{ width: 44, textAlign: 'center', flexShrink: 0, paddingTop: 8 }}>
              <div style={{ fontSize: 11, fontWeight: 700, color: isToday ? 'var(--primary)' : 'var(--ink-4)', textTransform: 'uppercase' }}>{d.split(' ')[0]}</div>
              <div style={{ width: 34, height: 34, borderRadius: 10, margin: '2px auto 0', display: 'grid', placeItems: 'center', fontWeight: 800, fontSize: 16, background: isToday ? 'var(--primary)' : 'transparent', color: isToday ? '#fff' : 'var(--ink-2)' }}>{d.split(' ')[1]}</div>
            </div>
            <div style={{ flex: 1, paddingBottom: 6, minHeight: 50, borderBottom: '1px solid var(--border)' }}>
              {items.length === 0 ? <div style={{ paddingTop: 14, fontSize: 12.5, color: 'var(--ink-4)', fontWeight: 600 }}>No sessions</div> :
                items.map((s, i) => {
                  const c = CT[s.ct];
                  return (
                    <button key={i} onClick={() => onOpen(s)} style={{ display: 'block', width: '100%', textAlign: 'left', border: 'none', cursor: 'pointer', background: `color-mix(in oklch, ${c.color} 12%, var(--surface))`, borderLeft: `3px solid ${c.color}`, borderRadius: 8, padding: '8px 11px', marginTop: 6 }}>
                      <div style={{ fontWeight: 800, fontSize: 13.5, color: 'var(--ink)' }}>{c.code} · {s.start}</div>
                      <div style={{ fontSize: 12, color: 'var(--ink-3)', fontWeight: 600 }}>{LOC[s.loc].short} · {s.roster.length} student{s.roster.length>1?'s':''}</div>
                    </button>
                  );
                })}
            </div>
          </div>
        );
      })}
    </div>
  );
}

/* ---------------- Session detail ---------------- */
function SessionDetail({ session, onBack, onCapture, fire, onShare, onPay }) {
  const c = CT[session.ct];
  const nonTeaching = CT[session.ct] && CT[session.ct].non_teaching;
  const canPay = SCHOOL.instructorsCanRecordPayments;
  const [roster, setRoster] = useStateI(session.roster);
  const setAttend = (sid, val) => setRoster(r => r.map(x => x.s === sid ? { ...x, attend: val } : x));
  return (
    <div className="ks-screen" style={{ padding: '6px 18px 24px', minHeight: '100%', background: 'var(--bg)' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 11, marginBottom: 16 }}>
        <button onClick={onBack} style={iIconBtn}><Icon name="left" size={19} /></button>
        <div style={{ flex: 1 }}>
          <span className="mono" style={{ fontSize: 10.5, fontWeight: 700, color: c.color }}>{c.code}</span>
          <div style={{ fontWeight: 800, fontSize: 19, letterSpacing: '-0.02em', lineHeight: 1.05 }}>{c.name}</div>
        </div>
        <button onClick={() => onShare({ title: 'Session check-in', subtitle: `Students scan this to check in to today's ${c.code} session.`, url: typeof window !== 'undefined' ? window.location.href : '', caption: 'lagan-valley.kickstand.app/checkin' })}
          style={iIconBtn} title="Show check-in code"><Icon name="qr" size={19} /></button>
      </div>
      <Card pad={15} style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', gap: '8px 18px', flexWrap: 'wrap', fontSize: 13.5, fontWeight: 600, color: 'var(--ink-2)' }}>
          <span style={{ display: 'flex', alignItems: 'center', gap: 6 }}><Icon name="calendar" size={16} sw={2} />Tue 9 Jun</span>
          <span style={{ display: 'flex', alignItems: 'center', gap: 6 }}><Icon name="clock" size={16} sw={2} />{session.start}–{session.end}</span>
          <span style={{ display: 'flex', alignItems: 'center', gap: 6 }}><Icon name="pin" size={16} sw={2} />{LOC[session.loc].name}</span>
        </div>
      </Card>
      {CT[session.ct] && CT[session.ct].non_teaching && (
        <Card pad={12} style={{ marginBottom: 16, background: 'var(--warning-tint)', border: 'none', display: 'flex', gap: 9, alignItems: 'flex-start' }}>
          <span style={{ color: 'oklch(0.55 0.13 70)', display: 'flex', marginTop: 1 }}><Icon name="flag" size={17} sw={2.1} /></span>
          <div style={{ fontSize: 12.5, color: 'var(--ink-2)', fontWeight: 600, lineHeight: 1.45 }}>Test day — bike & escort are reserved for the DVA test. No competency assessment to capture.</div>
        </Card>
      )}
      <SectionLabel>Roster · {roster.length} students</SectionLabel>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 11 }}>
        {roster.map((r, i) => {
          const stu = STU[r.s], bike = BIKE[r.bike];
          const flags = (SREC[r.s] && SREC[r.s].flags) || [];
          const phone = (SREC[r.s] && SREC[r.s].phone) || '';
          return (
            <Card key={r.s} pad={14}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 11 }}>
                <Avatar initials={stu.initials} tone={(i * 60 + 277) % 360} size={42} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ fontWeight: 800, fontSize: 15.5 }}>{stu.name}</div>
                  <div style={{ fontSize: 12.5, color: 'var(--ink-3)', display: 'flex', alignItems: 'center', gap: 5, marginTop: 1 }}>
                    <Icon name="moto" size={14} sw={1.8} />{bike.name} <span className="mono" style={{ fontSize: 11, color: 'var(--ink-4)' }}>{bike.reg}</span>
                  </div>
                </div>
                {phone && <a href={`tel:${phone.replace(/\s/g, '')}`} style={{ width: 38, height: 38, borderRadius: 11, border: '1px solid var(--border)', background: 'var(--surface)', display: 'grid', placeItems: 'center', color: 'var(--primary)', flexShrink: 0 }} title={`Call ${stu.name}`}><Icon name="phone" size={17} /></a>}
              </div>
              {flags.length > 0 && (
                <div style={{ marginTop: 11, padding: '9px 11px', borderRadius: 10, background: 'var(--warning-tint)', display: 'flex', flexDirection: 'column', gap: 6 }}>
                  {flags.map(f => (
                    <div key={f.id} style={{ display: 'flex', alignItems: 'flex-start', gap: 7, fontSize: 12.5, fontWeight: 600, color: 'var(--ink)' }}>
                      <Icon name="shield" size={14} sw={2.2} style={{ color: 'oklch(0.55 0.13 70)', flexShrink: 0, marginTop: 1 }} />{f.text}
                    </div>
                  ))}
                </div>
              )}
              {canPay && SREC[r.s] && balanceOf(r.s) > 0 && (
                <div style={{ marginTop: 11, display: 'flex', alignItems: 'center', gap: 10, padding: '9px 11px', borderRadius: 10, background: 'var(--surface-2)' }}>
                  <Icon name="card" size={16} sw={2.1} style={{ color: 'var(--ink-4)' }} />
                  <span style={{ fontSize: 13, color: 'var(--ink-2)', fontWeight: 600, flex: 1 }}>Outstanding <b style={{ color: 'var(--danger)' }}>£{balanceOf(r.s)}</b></span>
                  <Btn size="sm" variant="success" icon="plus" onClick={() => onPay({ studentId: r.s })}>Record payment</Btn>
                </div>
              )}
              <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
                <AttendBtn active={r.attend === 'present'} tone="success" icon="check" label="Present" onClick={() => setAttend(r.s, 'present')} />
                <AttendBtn active={r.attend === 'noshow'} tone="danger" icon="x" label="No-show" onClick={() => setAttend(r.s, 'noshow')} />
                {CT[session.ct] && CT[session.ct].non_teaching
                  ? <span style={{ marginLeft: 'auto', alignSelf: 'center', fontSize: 12, fontWeight: 700, color: 'var(--ink-4)', display: 'inline-flex', alignItems: 'center', gap: 5 }}><Icon name="flag" size={14} sw={2.2} />Test day</span>
                  : <Btn size="sm" variant="soft" icon="clipboard-check" onClick={() => onCapture(r.s)} style={{ marginLeft: 'auto' }}>Assess</Btn>}
              </div>
            </Card>
          );
        })}
      </div>
    </div>
  );
}
function AttendBtn({ active, tone, icon, label, onClick }) {
  const col = `var(--${tone})`;
  return (
    <button onClick={onClick} style={{
      display: 'inline-flex', alignItems: 'center', gap: 6, padding: '8px 13px', borderRadius: 'var(--r-sm)',
      fontFamily: 'var(--font)', fontWeight: 700, fontSize: 13, cursor: 'pointer',
      border: active ? 'none' : '1px solid var(--border-2)',
      background: active ? col : 'var(--surface)', color: active ? '#fff' : 'var(--ink-3)', transition: 'all .15s',
    }}>
      <Icon name={icon} size={15} sw={2.4} />{label}
    </button>
  );
}

/* ---------------- Competency capture ---------------- */
function CompetencyCapture({ session, studentId, onBack, onSave }) {
  const c = CT[session.ct], stu = STU[studentId];
  const comps = compsFor(session.ct);
  const [done, setDone] = useStateI(() => session.ct === 'practical' ? { p1: true, p2: true, p3: true, p4: true } : {});
  const [notes, setNotes] = useStateI('');
  const count = comps.filter(x => done[x.id]).length;
  return (
    <div className="ks-screen" style={{ padding: '6px 18px 24px', minHeight: '100%', background: 'var(--bg)' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 11, marginBottom: 16 }}>
        <button onClick={onBack} style={iIconBtn}><Icon name="left" size={19} /></button>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 600 }}>Assess · {c.name}</div>
          <div style={{ fontWeight: 800, fontSize: 19, letterSpacing: '-0.02em', lineHeight: 1.05 }}>{stu.name}</div>
        </div>
        <ProgressRing value={count} total={comps.length} size={46} sw={5} color={c.color}>
          <span style={{ fontSize: 12 }}>{count}/{comps.length}</span>
        </ProgressRing>
      </div>
      <SectionLabel>{session.ct.startsWith('cbt') ? 'CBT elements' : 'Practical skills'}</SectionLabel>
      <Card pad={6}>
        {comps.map((it, i) => {
          const on = done[it.id];
          return (
            <button key={it.id} onClick={() => setDone(d => ({ ...d, [it.id]: !d[it.id] }))} style={{
              display: 'flex', alignItems: 'center', gap: 12, width: '100%', textAlign: 'left', cursor: 'pointer',
              border: 'none', background: 'transparent', padding: '12px 10px',
              borderBottom: i < comps.length - 1 ? '1px solid var(--border)' : 'none',
            }}>
              <div style={{ width: 26, height: 26, borderRadius: 8, flexShrink: 0, display: 'grid', placeItems: 'center', background: on ? 'var(--success)' : 'var(--surface-3)', color: '#fff', border: on ? 'none' : '1.5px solid var(--border-2)', transition: 'all .15s' }}>
                {on && <Icon name="check" size={16} sw={3} />}
              </div>
              <span style={{ fontSize: 14.5, fontWeight: 600, color: on ? 'var(--ink)' : 'var(--ink-2)' }}>{it.label}</span>
            </button>
          );
        })}
      </Card>
      <div style={{ marginTop: 16 }}><SectionLabel>Session notes</SectionLabel></div>
      <textarea value={notes} onChange={e => setNotes(e.target.value)} placeholder="How did they get on? What to work on next…"
        style={{ width: '100%', minHeight: 90, padding: 14, borderRadius: 'var(--r)', border: '1px solid var(--border-2)', background: 'var(--surface)', fontFamily: 'var(--font)', fontSize: 14, color: 'var(--ink)', resize: 'none', outline: 'none', lineHeight: 1.5 }} />
      <div style={{ position: 'sticky', bottom: 0, paddingTop: 16 }}>
        <Btn full size="lg" icon="check" onClick={onSave}>Save assessment</Btn>
      </div>
    </div>
  );
}

/* ---------------- Availability ---------------- */
const SLOTS = ['Morning', 'Afternoon', 'Evening'];
function Availability({ fire }) {
  const [grid, setGrid] = useStateI(() => ({
    '0-0': 1, '0-1': 1, '1-0': 1, '1-1': 1, '2-0': 1, '2-1': 1, '3-0': 1, '3-1': 1, '4-0': 1, '4-1': 1, '5-0': 1,
  }));
  const toggle = (k) => setGrid(g => ({ ...g, [k]: g[k] ? 0 : 1 }));
  return (
    <div className="ks-screen" style={{ padding: '4px 18px 24px' }}>
      <div style={{ padding: '4px 0 6px' }}>
        <div style={{ fontWeight: 800, fontSize: 25, letterSpacing: '-0.03em' }}>Availability</div>
        <div style={{ fontSize: 13.5, color: 'var(--ink-3)', marginTop: 2 }}>Tap blocks to offer or remove time. Recurring weekly.</div>
      </div>
      <Card pad={14} style={{ marginTop: 14 }}>
        <div style={{ display: 'grid', gridTemplateColumns: '64px repeat(3, 1fr)', gap: 6, alignItems: 'center' }}>
          <div />
          {SLOTS.map(s => <div key={s} style={{ textAlign: 'center', fontSize: 11, fontWeight: 700, color: 'var(--ink-3)' }}>{s}</div>)}
          {WEEK_DATES.map((d, di) => (
            <React.Fragment key={di}>
              <div style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--ink-2)' }}>{d.split(' ')[0]}</div>
              {SLOTS.map((s, si) => {
                const k = `${di}-${si}`, on = grid[k];
                return (
                  <button key={k} onClick={() => toggle(k)} style={{
                    height: 38, borderRadius: 9, cursor: 'pointer', transition: 'all .15s',
                    border: on ? 'none' : '1.5px dashed var(--border-2)',
                    background: on ? 'var(--primary)' : 'transparent',
                    color: on ? '#fff' : 'var(--ink-4)', display: 'grid', placeItems: 'center',
                  }}>{on ? <Icon name="check" size={15} sw={3} /> : null}</button>
                );
              })}
            </React.Fragment>
          ))}
        </div>
      </Card>
      <div style={{ marginTop: 16 }}><SectionLabel>Time off</SectionLabel></div>
      <Card pad={14} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 40, height: 40, borderRadius: 11, display: 'grid', placeItems: 'center', background: 'var(--warning-tint)', color: 'oklch(0.55 0.13 70)' }}><Icon name="ban" size={20} /></div>
        <div style={{ flex: 1 }}>
          <div style={{ fontWeight: 700, fontSize: 14.5 }}>Sun 14 Jun — all day</div>
          <div style={{ fontSize: 12.5, color: 'var(--ink-3)' }}>Annual leave</div>
        </div>
        <button style={iIconBtn}><Icon name="trash" size={17} /></button>
      </Card>
      <Btn full variant="soft" icon="plus" style={{ marginTop: 12 }} onClick={() => fire('Time off added', 'check-circle')}>Add time off</Btn>
      <div style={{ position: 'sticky', bottom: 0, paddingTop: 16 }}>
        <Btn full size="lg" icon="check" onClick={() => fire('Availability saved', 'check-circle')}>Save availability</Btn>
      </div>
    </div>
  );
}

/* ---------------- Profile ---------------- */
function InstProfile({ onPrefs }) {
  return (
    <div className="ks-screen" style={{ padding: '6px 18px 24px' }}>
      <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', textAlign: 'center', padding: '14px 0 22px' }}>
        <Avatar initials={THIS_INST.initials} tone={THIS_INST.tone} size={84} />
        <div style={{ fontWeight: 800, fontSize: 22, letterSpacing: '-0.03em', marginTop: 14 }}>{THIS_INST.name}</div>
        <div style={{ fontSize: 13.5, color: 'var(--ink-3)' }}>Instructor · {LOC[THIS_INST.home].short}</div>
      </div>
      <SectionLabel>Qualified to teach</SectionLabel>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        {THIS_INST.qualified.map(id => {
          const c = CT[id];
          return (
            <Card key={id} pad={14} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
              <div style={{ width: 40, height: 40, borderRadius: 11, display: 'grid', placeItems: 'center', background: `color-mix(in oklch, ${c.color} 14%, transparent)`, color: c.color }}><Icon name={c.icon} size={20} /></div>
              <div style={{ flex: 1 }}><div style={{ fontWeight: 700, fontSize: 14.5 }}>{c.name}</div><div style={{ fontSize: 12.5, color: 'var(--ink-3)' }}>{c.cat} · {c.ratio}</div></div>
              <span style={{ color: 'var(--success)', display: 'flex' }}><Icon name="check-circle" size={20} /></span>
            </Card>
          );
        })}
      </div>
      <button onClick={onPrefs} style={{ ...iLinkRow, marginTop: 16 }}><Icon name="bell" size={18} style={{ color: 'var(--primary)' }} />Notification preferences<Icon name="right" size={17} style={{ marginLeft: 'auto', color: 'var(--ink-4)' }} /></button>
      <button style={{ ...iLinkRow, marginTop: 10, color: 'var(--danger)' }}><Icon name="logout" size={18} />Sign out</button>
    </div>
  );
}

const iIconBtn = { width: 38, height: 38, borderRadius: 11, border: '1px solid var(--border)', background: 'var(--surface)', display: 'grid', placeItems: 'center', color: 'var(--ink-2)', cursor: 'pointer', flexShrink: 0 };
const iLinkRow = { display: 'flex', alignItems: 'center', justifyContent: 'center', gap: 9, width: '100%', padding: 14, borderRadius: 'var(--r)', border: '1px solid var(--border)', background: 'var(--surface)', fontWeight: 700, fontSize: 14.5, cursor: 'pointer', fontFamily: 'var(--font)', boxShadow: 'var(--sh-1)' };

function InstrPaymentForm({ studentId, onClose, onDone }) {
  const stu = STU[studentId], bal = balanceOf(studentId);
  const [amount, setAmount] = useStateI(bal > 0 ? String(bal) : '');
  const [method, setMethod] = useStateI('cash');
  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 11, padding: 12, borderRadius: 'var(--r)', background: 'var(--surface-2)', marginBottom: 16 }}>
        <Avatar initials={stu.initials} tone={277} size={38} />
        <div style={{ flex: 1 }}><div style={{ fontWeight: 800, fontSize: 15 }}>{stu.name}</div><div style={{ fontSize: 12.5, color: 'var(--ink-3)' }}>Outstanding £{bal}</div></div>
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
        <KField label="Amount received"><KInput prefix="£" value={amount} onChange={v => setAmount(v.replace(/[^0-9.]/g, ''))} placeholder="0" /></KField>
        <KField label="Method"><KSelect value={method} onChange={setMethod} options={PAY_METHODS} /></KField>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12.5, color: 'var(--ink-4)', fontWeight: 600 }}>
          <Icon name="shield" size={14} sw={2.1} /> Recorded by {THIS_INST.name} · {new Date().toLocaleDateString('en-GB', { day: 'numeric', month: 'short' })}
        </div>
        <div style={{ display: 'flex', gap: 10, marginTop: 2 }}>
          <Btn full variant="secondary" onClick={onClose}>Cancel</Btn>
          <Btn full variant="success" icon="check" disabled={!amount} onClick={onDone}>Record payment</Btn>
        </div>
      </div>
    </div>
  );
}

/* =============================================================== */
/* Expenses — instructor side (list / add / detail)                  */
/* =============================================================== */

function statusPill(s) {
  const map = {
    pending:    { label: 'Pending review', tone: 'var(--warning)',  bg: 'var(--warning-tint, color-mix(in oklch, var(--warning) 14%, transparent))' },
    approved:   { label: 'Approved',       tone: 'var(--primary)',  bg: 'var(--primary-tint)' },
    reimbursed: { label: 'Reimbursed',     tone: 'var(--success)',  bg: 'color-mix(in oklch, var(--success) 14%, transparent)' },
    rejected:   { label: 'Rejected',       tone: 'var(--danger)',   bg: 'color-mix(in oklch, var(--danger) 14%, transparent)' },
  };
  const p = map[s] || map.pending;
  return (
    <span style={{ padding: '3px 9px', borderRadius: 99, background: p.bg, color: p.tone, fontWeight: 800, fontSize: 11.5, letterSpacing: 0.2 }}>{p.label}</span>
  );
}

function ExpenseRow({ e, onClick }) {
  const cat = expenseCat(e.cat);
  return (
    <button onClick={onClick} style={{ width: '100%', textAlign: 'left', cursor: 'pointer', border: 'none', background: 'transparent', padding: 0 }}>
      <Card pad={12} style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
        {/* receipt thumbnail — striped placeholder with a category glyph */}
        <div style={{ width: 44, height: 44, borderRadius: 10, background: `repeating-linear-gradient(135deg, var(--surface-3) 0 6px, var(--surface-2) 6px 12px)`, position: 'relative', flexShrink: 0, display: 'grid', placeItems: 'center' }}>
          <div style={{ position: 'absolute', inset: 0, display: 'grid', placeItems: 'center', color: `oklch(0.6 0.14 ${cat.tone})` }}><Icon name={cat.icon} size={18} sw={2.1} /></div>
        </div>
        <div style={{ flex: 1, minWidth: 0 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <span style={{ fontWeight: 800, fontSize: 14.5 }}>£{e.amount.toFixed(2)}</span>
            <span style={{ fontSize: 12, color: 'var(--ink-3)', fontWeight: 600 }}>· {cat.label}</span>
          </div>
          <div style={{ fontSize: 12, color: 'var(--ink-3)', marginTop: 2, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{e.where || '—'} · {e.when}</div>
        </div>
        {statusPill(e.status)}
      </Card>
    </button>
  );
}

function InstExpenses({ onAdd, onOpen }) {
  const mine = expensesForInstr('i1');
  const pending = mine.filter(e => e.status === 'pending');
  const approved = mine.filter(e => e.status === 'approved');
  const reimbursed = mine.filter(e => e.status === 'reimbursed');
  const rejected = mine.filter(e => e.status === 'rejected');
  const pendingTotal = pending.reduce((s, e) => s + e.amount, 0) + approved.reduce((s, e) => s + e.amount, 0);

  return (
    <div className="ks-screen" style={{ padding: '6px 18px 24px' }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 10, padding: '4px 0 14px' }}>
        <div>
          <div style={{ fontSize: 13.5, color: 'var(--ink-3)', fontWeight: 600 }}>{THIS_INST.name}</div>
          <div style={{ fontWeight: 800, fontSize: 25, letterSpacing: '-0.03em' }}>Expenses</div>
        </div>
        <button onClick={onAdd} style={{ ...iIconBtn, width: 'auto', padding: '0 14px', height: 38, display: 'flex', alignItems: 'center', gap: 7, background: 'var(--primary)', color: '#fff', border: 'none' }}>
          <Icon name="plus" size={17} sw={2.4} /><span style={{ fontWeight: 800, fontSize: 13 }}>Add expense</span>
        </button>
      </div>

      {/* Outstanding hero */}
      <Card pad={16} style={{ background: 'var(--primary-tint)', borderColor: 'transparent', marginBottom: 16 }}>
        <div style={{ fontSize: 12, color: 'var(--primary-deep)', fontWeight: 700, letterSpacing: 0.4, textTransform: 'uppercase' }}>Awaiting reimbursement</div>
        <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, marginTop: 4 }}>
          <span style={{ fontWeight: 800, fontSize: 30, letterSpacing: '-0.04em', color: 'var(--primary-deep)' }}>£{pendingTotal.toFixed(2)}</span>
          <span style={{ fontSize: 12.5, color: 'var(--ink-2)', fontWeight: 600 }}>across {pending.length + approved.length} item{pending.length + approved.length === 1 ? '' : 's'}</span>
        </div>
      </Card>

      {pending.length > 0 && (
        <div>
          <SectionLabel>Pending review</SectionLabel>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            {pending.map(e => <ExpenseRow key={e.id} e={e} onClick={() => onOpen(e.id)} />)}
          </div>
        </div>
      )}

      {approved.length > 0 && (
        <div>
          <div style={{ height: 18 }} />
          <SectionLabel>Approved — awaiting payment</SectionLabel>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            {approved.map(e => <ExpenseRow key={e.id} e={e} onClick={() => onOpen(e.id)} />)}
          </div>
        </div>
      )}

      {reimbursed.length > 0 && (
        <div>
          <div style={{ height: 18 }} />
          <SectionLabel>Reimbursed</SectionLabel>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            {reimbursed.map(e => <ExpenseRow key={e.id} e={e} onClick={() => onOpen(e.id)} />)}
          </div>
        </div>
      )}

      {rejected.length > 0 && (
        <div>
          <div style={{ height: 18 }} />
          <SectionLabel>Rejected</SectionLabel>
          <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
            {rejected.map(e => <ExpenseRow key={e.id} e={e} onClick={() => onOpen(e.id)} />)}
          </div>
        </div>
      )}
    </div>
  );
}

function ExpenseAdd({ onBack, onSubmit }) {
  const [hasPhoto, setHasPhoto] = useStateI(false);
  const [cat, setCat] = useStateI('petrol');
  const [amount, setAmount] = useStateI('');
  const [where, setWhere] = useStateI('');
  const [note, setNote] = useStateI('');
  const ready = hasPhoto && amount && Number(amount) > 0;

  return (
    <div className="ks-screen" style={{ padding: '6px 18px 24px' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '4px 0 14px' }}>
        <button onClick={onBack} style={iIconBtn}><Icon name="left" size={18} /></button>
        <div style={{ fontWeight: 800, fontSize: 22, letterSpacing: '-0.03em' }}>Add expense</div>
      </div>

      {/* Receipt capture — striped placeholder until "captured". Click to toggle. */}
      <button onClick={() => setHasPhoto(p => !p)} style={{ width: '100%', height: 220, borderRadius: 'var(--r)', border: hasPhoto ? '1px solid var(--border)' : '1.5px dashed var(--border-2)', background: hasPhoto
          ? `repeating-linear-gradient(135deg, var(--surface-3) 0 8px, var(--surface-2) 8px 16px)`
          : 'var(--surface-2)', position: 'relative', cursor: 'pointer', padding: 0, overflow: 'hidden' }}>
        {hasPhoto ? (
          <div>
            <div style={{ position: 'absolute', inset: 0, display: 'grid', placeItems: 'center', color: 'var(--ink-4)' }}>
              <Icon name="ticket" size={48} sw={1.4} />
            </div>
            <div style={{ position: 'absolute', top: 10, right: 10, padding: '4px 9px', borderRadius: 99, background: 'var(--surface)', color: 'var(--ink-2)', fontSize: 11.5, fontWeight: 800, boxShadow: 'var(--sh-1)' }}>Receipt.jpg</div>
            <div style={{ position: 'absolute', bottom: 10, right: 10, display: 'flex', gap: 8 }}>
              <span style={{ padding: '6px 10px', borderRadius: 99, background: 'var(--surface)', color: 'var(--ink-2)', fontSize: 11.5, fontWeight: 700, display: 'inline-flex', alignItems: 'center', gap: 5 }}><Icon name="repeat" size={13} sw={2.2} /> Retake</span>
            </div>
          </div>
        ) : (
          <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', height: '100%', gap: 8, color: 'var(--ink-3)' }}>
            <div style={{ width: 56, height: 56, borderRadius: '50%', background: 'var(--primary-tint)', color: 'var(--primary-deep)', display: 'grid', placeItems: 'center' }}><Icon name="plus" size={26} sw={2.4} /></div>
            <div style={{ fontWeight: 800, fontSize: 15, color: 'var(--ink)' }}>Snap receipt</div>
            <div style={{ fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 600 }}>Photo or upload — required for submission</div>
          </div>
        )}
      </button>

      <div style={{ height: 18 }} />

      {/* Category chips */}
      <div style={{ fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 700, marginBottom: 8, letterSpacing: 0.3, textTransform: 'uppercase' }}>Category</div>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        {EXPENSE_CATEGORIES.map(c => {
          const on = c.id === cat;
          const colour = `oklch(0.55 0.14 ${c.tone})`;
          return (
            <button key={c.id} onClick={() => setCat(c.id)} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '8px 12px', borderRadius: 99, border: on ? `1.5px solid ${colour}` : '1px solid var(--border)', background: on ? `color-mix(in oklch, ${colour} 14%, transparent)` : 'var(--surface)', color: on ? colour : 'var(--ink-2)', fontWeight: 800, fontSize: 13, cursor: 'pointer', fontFamily: 'var(--font)' }}>
              <Icon name={c.icon} size={14} sw={2.2} />{c.label}
            </button>
          );
        })}
      </div>

      <div style={{ height: 18 }} />

      {/* Amount + where + notes */}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
        <KField label="Amount paid"><KInput prefix="£" value={amount} onChange={v => setAmount(v.replace(/[^0-9.]/g, ''))} placeholder="0.00" /></KField>
        <KField label="Where" hint="Forecourt, café, car park…"><KInput value={where} onChange={setWhere} placeholder="Esso Sydenham" /></KField>
        <KField label="Notes" hint="Optional — context for the owner"><KInput value={note} onChange={setNote} placeholder="Top-up for the week" /></KField>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12.5, color: 'var(--ink-4)', fontWeight: 600 }}>
          <Icon name="info" size={14} sw={2.1} /> Submitted expenses are reviewed by the owner before reimbursement.
        </div>
        <div style={{ display: 'flex', gap: 10, marginTop: 2 }}>
          <Btn full variant="secondary" onClick={onBack}>Cancel</Btn>
          <Btn full variant="primary" icon="check" disabled={!ready} onClick={onSubmit}>Submit for review</Btn>
        </div>
      </div>
    </div>
  );
}

function ExpenseDetail({ expense, onBack, onWithdraw, fire }) {
  if (!expense) return null;
  const cat = expenseCat(expense.cat);
  const catColour = `oklch(0.55 0.14 ${cat.tone})`;

  return (
    <div className="ks-screen" style={{ padding: '6px 18px 24px' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '4px 0 14px' }}>
        <button onClick={onBack} style={iIconBtn}><Icon name="left" size={18} /></button>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 700, letterSpacing: 0.3, textTransform: 'uppercase' }}>Expense</div>
          <div style={{ fontWeight: 800, fontSize: 22, letterSpacing: '-0.03em' }}>£{expense.amount.toFixed(2)}</div>
        </div>
        {statusPill(expense.status)}
      </div>

      {/* Receipt photo */}
      <div style={{ width: '100%', height: 280, borderRadius: 'var(--r)', background: `repeating-linear-gradient(135deg, var(--surface-3) 0 8px, var(--surface-2) 8px 16px)`, position: 'relative', overflow: 'hidden', marginBottom: 14 }}>
        <div style={{ position: 'absolute', inset: 0, display: 'grid', placeItems: 'center', color: 'var(--ink-4)' }}>
          <Icon name="ticket" size={56} sw={1.4} />
        </div>
        <div style={{ position: 'absolute', top: 10, left: 10, padding: '4px 9px', borderRadius: 99, background: 'var(--surface)', color: 'var(--ink-2)', fontSize: 11.5, fontWeight: 800, boxShadow: 'var(--sh-1)' }}>Receipt.jpg</div>
      </div>

      {/* Meta */}
      <Card pad={14}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ width: 36, height: 36, borderRadius: 10, background: `color-mix(in oklch, ${catColour} 14%, transparent)`, color: catColour, display: 'grid', placeItems: 'center' }}><Icon name={cat.icon} size={18} sw={2.1} /></div>
          <div style={{ flex: 1 }}>
            <div style={{ fontWeight: 800, fontSize: 14.5 }}>{cat.label}</div>
            <div style={{ fontSize: 12.5, color: 'var(--ink-3)' }}>{expense.where || '—'}</div>
          </div>
          <div style={{ fontSize: 12.5, color: 'var(--ink-3)', fontWeight: 700 }}>{expense.when}</div>
        </div>
        {expense.note && (
          <div style={{ marginTop: 12, paddingTop: 12, borderTop: '1px solid var(--border)', fontSize: 13.5, color: 'var(--ink-2)' }}>{expense.note}</div>
        )}
      </Card>

      {/* Status footnote */}
      {expense.status === 'approved' && expense.reviewerNote && (
        <div style={{ marginTop: 12, padding: '11px 14px', borderRadius: 'var(--r)', background: 'var(--primary-tint)', color: 'var(--ink-2)', fontSize: 13 }}>
          <div style={{ fontWeight: 800, color: 'var(--primary-deep)', display: 'flex', alignItems: 'center', gap: 8 }}><Icon name="check-circle" size={16} sw={2.2} /> Approved · {expense.reviewedBy}</div>
          <div style={{ marginTop: 4, fontWeight: 600 }}>{expense.reviewerNote}</div>
        </div>
      )}
      {expense.status === 'reimbursed' && (
        <div style={{ marginTop: 12, padding: '11px 14px', borderRadius: 'var(--r)', background: 'color-mix(in oklch, var(--success) 10%, transparent)', color: 'var(--success)', fontSize: 13, fontWeight: 700, display: 'flex', alignItems: 'center', gap: 8 }}>
          <Icon name="check-circle" size={16} sw={2.2} /> Reimbursed {expense.paidOn} · {expense.paidVia}
        </div>
      )}
      {expense.status === 'rejected' && (
        <div style={{ marginTop: 12, padding: '11px 14px', borderRadius: 'var(--r)', background: 'color-mix(in oklch, var(--danger) 10%, transparent)', color: 'var(--danger)', fontSize: 13 }}>
          <div style={{ fontWeight: 800, display: 'flex', alignItems: 'center', gap: 8 }}><Icon name="x-circle" size={16} sw={2.2} /> Rejected by {expense.reviewedBy || 'Owner'}</div>
          {expense.reviewerNote && <div style={{ marginTop: 4, color: 'var(--ink-2)', fontWeight: 600 }}>{expense.reviewerNote}</div>}
        </div>
      )}

      {/* Actions */}
      {expense.status === 'pending' && (
        <div style={{ display: 'flex', gap: 10, marginTop: 16 }}>
          <Btn full variant="secondary" icon="edit" onClick={() => fire('Edit coming next', 'info')}>Edit</Btn>
          <Btn full variant="danger" icon="trash" onClick={onWithdraw}>Withdraw</Btn>
        </div>
      )}
    </div>
  );
}

Object.assign(window, { InstructorApp });