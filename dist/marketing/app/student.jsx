// Kickstand — Student app shell: home, my bookings, progress, licence.
const { useState: useStateS } = React;

function StudentApp({ theme, status = 'active' }) {
  const pending = status === 'pending';
  const [tab, setTab] = useStateS('home');
  const [toast, setToast] = useStateS(null);
  const [confirmed, setConfirmed] = useStateS(null);   // success screen
  const [bookings, setBookings] = useStateS(MY_BOOKINGS);
  const [cancelBk, setCancelBk] = useStateS(null);
  const [reschedBk, setReschedBk] = useStateS(null);
  const [share, setShare] = useStateS(false);
  const [notif, setNotif] = useStateS(false);
  const [prefs, setPrefs] = useStateS(false);

  const fireToast = (msg, icon, tone) => { setToast({ msg, icon, tone }); setTimeout(() => setToast(null), 2200); };

  const onConfirmed = (b) => {
    const nb = { id: 'bk' + Date.now(), se: b.se.id, ct: b.ct, status: 'booked', date: b.se.date, start: b.se.start, end: b.se.end, loc: b.se.loc, inst: b.se.inst, bike: b.bike ? b.bike.id : null };
    setBookings(x => [nb, ...x]);
    setConfirmed({ ...b });
  };

  const doCancel = () => {
    setBookings(x => x.map(bk => bk.id === cancelBk.id ? { ...bk, status: 'cancelled' } : bk));
    setCancelBk(null);
    fireToast('Booking cancelled', 'check-circle');
  };

  const doReschedule = (newSe) => {
    setBookings(x => x.map(bk => bk.id === reschedBk.id
      ? { ...bk, se: newSe.id, date: newSe.date, start: newSe.start, end: newSe.end, loc: newSe.loc, inst: newSe.inst }
      : bk));
    setReschedBk(null);
    fireToast('Booking rescheduled', 'repeat');
  };

  const tabs = [
    { id: 'home', label: 'Home', icon: 'home' },
    { id: 'book', label: 'Book', icon: 'plus' },
    { id: 'bookings', label: 'Bookings', icon: 'ticket' },
    { id: 'progress', label: 'Progress', icon: 'award' },
  ];

  let body;
  if (confirmed) body = <Confirmed data={confirmed} onDone={() => { setConfirmed(null); setTab('bookings'); }} />;
  else if (tab === 'home') body = <StudentHome go={setTab} bookings={bookings} openLicence={() => setTab('licence')} onShare={() => setShare(true)} onBell={() => setNotif(true)} pending={pending} />;
  else if (tab === 'book') body = <StudentBook onConfirmed={onConfirmed} pending={pending} onBell={() => setNotif(true)} />;
  else if (tab === 'bookings') body = <MyBookings bookings={bookings} onCancel={setCancelBk} onReschedule={setReschedBk} go={setTab} onBell={() => setNotif(true)} />;
  else if (tab === 'progress') body = <Progress onBell={() => setNotif(true)} />;
  else if (tab === 'licence') body = <Licence onBack={() => setTab('home')} onBell={() => setNotif(true)} />;

  return (
    <IOSDevice dark={theme === 'dark'}>
      <div style={{ height: '100%', display: 'flex', flexDirection: 'column', background: 'var(--bg)' }}>
        <div style={{ flex: 1, overflowY: 'auto', paddingTop: 54 }}>{body}</div>
        {!confirmed && tab !== 'licence' && <TabBar tabs={tabs} active={tab} onChange={setTab} />}
      </div>
      {toast && <Toast {...toast} />}
      <Sheet open={!!cancelBk} onClose={() => setCancelBk(null)} title="Cancel this booking?">
        {cancelBk && <CancelBody bk={cancelBk} onConfirm={doCancel} onClose={() => setCancelBk(null)} />}
      </Sheet>
      <Sheet open={!!reschedBk} onClose={() => setReschedBk(null)} title="Reschedule booking">
        {reschedBk && <RescheduleBody bk={reschedBk} onConfirm={doReschedule} onClose={() => setReschedBk(null)} />}
      </Sheet>
      <ShareSheet open={share} onClose={() => setShare(false)} title="Invite a friend"
        subtitle={`Share ${SCHOOL.short}'s booking link — they scan, pick a course, and they're in.`}
        url={typeof window !== 'undefined' ? window.location.href : ''} caption="lagan-valley.kickstand.app/book" />
      <NotifCenter open={notif} onClose={() => setNotif(false)} role="student" mobile onOpenPrefs={() => { setNotif(false); setPrefs(true); }} />
      <NotifPrefs open={prefs} onClose={() => setPrefs(false)} mobile />
    </IOSDevice>
  );
}

/* ---------------- Home ---------------- */
function StudentHome({ go, bookings, openLicence, onShare, onBell, pending }) {
  const next = bookings.find(b => b.status === 'booked');
  const prac = MY_PROGRESS.practical;
  return (
    <div className="ks-screen" style={{ padding: '0 18px 20px' }}>
      {pending && (
        <Card pad={13} style={{ marginTop: 6, marginBottom: 4, background: 'var(--warning-tint)', border: 'none', display: 'flex', gap: 11, alignItems: 'center' }}>
          <div style={{ width: 38, height: 38, borderRadius: 11, flexShrink: 0, display: 'grid', placeItems: 'center', background: 'oklch(0.55 0.13 70)', color: '#fff' }}><Icon name="clock" size={20} /></div>
          <div>
            <div style={{ fontWeight: 800, fontSize: 14.5 }}>Awaiting approval</div>
            <div style={{ fontSize: 12.5, color: 'var(--ink-2)', lineHeight: 1.4 }}>{SCHOOL.short} is reviewing your sign-up. You can browse, and we'll text you once you're cleared to book.</div>
          </div>
        </Card>
      )}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '4px 0 18px' }}>
        <div>
          <div style={{ fontSize: 13.5, color: 'var(--ink-3)', fontWeight: 600 }}>Good morning,</div>
          <div style={{ fontWeight: 800, fontSize: 25, letterSpacing: '-0.03em' }}>{ME.name.split(' ')[0]} 👋</div>
        </div>
        <div style={{ display: 'flex', gap: 9, alignItems: 'center' }}>
          <NotifBell role="student" onClick={onBell} style={iconBtn} />
          <Avatar initials={ME.initials} size={40} />
        </div>
      </div>

      {/* Next up hero */}
      {next ? <NextUpCard bk={next} go={go} /> : (
        <Card pad={20} style={{ textAlign: 'center' }}>
          <div style={{ fontWeight: 700, color: 'var(--ink-2)', marginBottom: 12 }}>No upcoming sessions</div>
          <Btn icon="plus" onClick={() => go('book')}>Book training</Btn>
        </Card>
      )}

      {/* Status strip */}
      <div style={{ marginTop: 22 }}><SectionLabel>Your licence journey</SectionLabel></div>
      <div style={{ display: 'flex', gap: 10 }}>
        <StatTile tone={160} icon="shield" label="CBT valid" value={`to ${ME.cbtExpiry}`} />
        <StatTile tone={277} icon="check-circle" label="Theory" value="Passed" />
      </div>
      <Card pad={15} style={{ marginTop: 10, display: 'flex', alignItems: 'center', gap: 13 }} accent="var(--warning)">
        <div style={{ width: 44, height: 44, borderRadius: 12, display: 'grid', placeItems: 'center', background: 'var(--warning-tint)', color: 'oklch(0.55 0.13 70)' }}><Icon name="target" size={23} /></div>
        <div style={{ flex: 1 }}>
          <div style={{ fontWeight: 800, fontSize: 15 }}>Practical test booked</div>
          <div style={{ fontSize: 12.5, color: 'var(--ink-3)' }}>{ME.practicalTest.date} · {ME.practicalTest.time} · {ME.practicalTest.centre}</div>
        </div>
        <div style={{ textAlign: 'center' }}>
          <div style={{ fontWeight: 800, fontSize: 22, color: 'oklch(0.55 0.13 70)', lineHeight: 1 }}>18</div>
          <div style={{ fontSize: 10.5, color: 'var(--ink-4)', fontWeight: 700 }}>DAYS</div>
        </div>
      </Card>

      {/* Progress snapshot */}
      <div style={{ marginTop: 22 }}><SectionLabel action={<button onClick={() => go('progress')} style={linkBtn}>View all</button>}>Practical training progress</SectionLabel></div>
      <Card pad={16} onClick={() => go('progress')} hover style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
        <ProgressRing value={prac.done} total={prac.total} size={64} sw={7} color="var(--success)">
          <span style={{ fontSize: 15 }}>{prac.done}<span style={{ fontSize: 11, color: 'var(--ink-4)' }}>/{prac.total}</span></span>
        </ProgressRing>
        <div style={{ flex: 1 }}>
          <div style={{ fontWeight: 800, fontSize: 15.5 }}>4 of 7 manoeuvres signed off</div>
          <div style={{ fontSize: 13, color: 'var(--ink-3)', marginTop: 2 }}>U-turn next — keep it up!</div>
        </div>
        <Icon name="right" size={20} style={{ color: 'var(--ink-4)' }} />
      </Card>

      <button onClick={openLicence} style={{ ...linkRow, marginTop: 14 }}>
        <span style={{ color: 'var(--primary)', display: 'flex' }}><Icon name="card" size={19} /></span>
        Licence & documents
        <Icon name="right" size={18} style={{ marginLeft: 'auto', color: 'var(--ink-4)' }} />
      </button>
      <button onClick={onShare} style={{ ...linkRow, marginTop: 10 }}>
        <span style={{ color: 'var(--primary)', display: 'flex' }}><Icon name="qr" size={19} /></span>
        Invite a friend
        <Icon name="right" size={18} style={{ marginLeft: 'auto', color: 'var(--ink-4)' }} />
      </button>
    </div>
  );
}

function NextUpCard({ bk, go }) {
  const c = CT[bk.ct], inst = INST[bk.inst], b = bk.bike ? BIKE[bk.bike] : null;
  return (
    <div onClick={() => go('bookings')} style={{
      borderRadius: 'var(--r-xl)', padding: 18, cursor: 'pointer', position: 'relative', overflow: 'hidden',
      background: 'linear-gradient(135deg, var(--primary-deep), var(--primary))', color: '#fff', boxShadow: 'var(--sh-primary)',
    }}>
      <div style={{ position: 'absolute', right: -28, top: -28, width: 130, height: 130, borderRadius: '50%', background: 'rgba(255,255,255,.10)' }} />
      <div style={{ position: 'absolute', right: 18, bottom: 12, opacity: .22 }}><Icon name="moto" size={64} sw={1.6} /></div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, opacity: .9, fontSize: 12, fontWeight: 700, letterSpacing: '0.04em' }}>
        <Icon name="zap" size={14} sw={2.4} fill="#fff" /> NEXT UP · {bk.date.toUpperCase()}
      </div>
      <div style={{ fontWeight: 800, fontSize: 23, letterSpacing: '-0.03em', margin: '8px 0 2px' }}>{c.name}</div>
      <div style={{ display: 'flex', gap: 16, fontSize: 13.5, fontWeight: 600, opacity: .95, marginBottom: 16 }}>
        <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}><Icon name="clock" size={15} sw={2.2} />{bk.start}</span>
        <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}><Icon name="pin" size={15} sw={2.2} />{LOC[bk.loc].short}</span>
        <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}><Icon name="user" size={15} sw={2.2} />{inst.name.split(' ')[0]}</span>
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 9, background: 'rgba(255,255,255,.16)', borderRadius: 'var(--r)', padding: '10px 13px', backdropFilter: 'blur(4px)' }}>
        <Icon name="moto" size={20} sw={1.8} />
        <span style={{ fontWeight: 700, fontSize: 13.5 }}>{b ? b.name : 'Bike auto-assigned'}</span>
        {b && <span className="mono" style={{ fontSize: 11.5, opacity: .85, marginLeft: 'auto' }}>{b.reg}</span>}
      </div>
    </div>
  );
}

function StatTile({ tone, icon, label, value }) {
  return (
    <Card pad={14} style={{ flex: 1 }}>
      <div style={{ width: 34, height: 34, borderRadius: 10, display: 'grid', placeItems: 'center', background: `oklch(0.93 0.05 ${tone})`, color: `oklch(0.46 0.12 ${tone})`, marginBottom: 9 }}><Icon name={icon} size={18} sw={2.2} /></div>
      <div style={{ fontWeight: 800, fontSize: 15 }}>{label}</div>
      <div style={{ fontSize: 12, color: 'var(--ink-3)', marginTop: 1 }}>{value}</div>
    </Card>
  );
}

/* ---------------- My bookings ---------------- */
function MyBookings({ bookings, onCancel, onReschedule, go, onBell }) {
  const [seg, setSeg] = useStateS('upcoming');
  const up = bookings.filter(b => b.status === 'booked');
  const past = bookings.filter(b => b.status !== 'booked');
  const list = seg === 'upcoming' ? up : past;
  return (
    <div className="ks-screen" style={{ padding: '6px 18px 20px' }}>
      <BookH title="My bookings" onBell={onBell} />
      <div style={{ margin: '16px 0 14px' }}>
        <Seg full value={seg} onChange={setSeg} items={[{ value: 'upcoming', label: `Upcoming (${up.length})` }, { value: 'past', label: 'Past' }]} />
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        {list.map(bk => <BookingCard key={bk.id} bk={bk} onCancel={onCancel} onReschedule={onReschedule} />)}
        {list.length === 0 && (
          <Empty msg={seg === 'upcoming' ? 'Nothing booked yet.' : 'No past sessions.'} />
        )}
        {seg === 'upcoming' && <Btn full variant="soft" icon="plus" onClick={() => go('book')} style={{ marginTop: 2 }}>Book another session</Btn>}
      </div>
    </div>
  );
}

function BookingCard({ bk, onCancel, onReschedule }) {
  const c = CT[bk.ct], inst = INST[bk.inst], b = bk.bike ? BIKE[bk.bike] : null;
  const cancelled = bk.status === 'cancelled', done = bk.status === 'completed';
  return (
    <Card pad={0} style={{ overflow: 'hidden', opacity: cancelled ? 0.6 : 1 }}>
      <div style={{ display: 'flex', borderBottom: '1px solid var(--border)' }}>
        <div style={{ width: 5, background: c.color }} />
        <div style={{ flex: 1, padding: 15 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
            <div>
              <span className="mono" style={{ fontSize: 10.5, fontWeight: 700, color: c.color }}>{c.code}</span>
              <div style={{ fontWeight: 800, fontSize: 16.5, letterSpacing: '-0.02em' }}>{c.name}</div>
            </div>
            {done ? <Badge tone="success" icon="check">{bk.result}</Badge> : cancelled ? <Badge tone="neutral">Cancelled</Badge> : <Badge tone="primary">Confirmed</Badge>}
          </div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: '7px 16px', marginTop: 11, fontSize: 13, color: 'var(--ink-2)', fontWeight: 600 }}>
            <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}><Icon name="calendar" size={15} sw={2} />{bk.date}</span>
            <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}><Icon name="clock" size={15} sw={2} />{bk.start}–{bk.end}</span>
            <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}><Icon name="pin" size={15} sw={2} />{LOC[bk.loc].short}</span>
            <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}><Icon name="moto" size={16} sw={1.8} />{b ? b.name : 'Auto bike'}</span>
          </div>
        </div>
      </div>
      {bk.status === 'booked' && (
        <div style={{ display: 'flex', gap: 8, padding: 12 }}>
          <Btn size="sm" variant="secondary" full icon="repeat" onClick={() => onReschedule(bk)}>Reschedule</Btn>
          <Btn size="sm" variant="danger-soft" full icon="x" onClick={() => onCancel(bk)}>Cancel</Btn>
        </div>
      )}
    </Card>
  );
}

function RescheduleBody({ bk, onConfirm, onClose }) {
  const c = CT[bk.ct];
  const [pick, setPick] = useStateS(null);
  // alternative sessions: same course, not the current one, with availability
  const alts = SESSIONS.filter(s => s.ct === bk.ct && s.id !== bk.se).map(s => ({ s, cap: honestCapacity(s) })).filter(o => o.cap.bookable > 0);
  return (
    <div>
      <Card pad={12} style={{ background: 'var(--surface-2)', border: 'none', marginBottom: 14, display: 'flex', gap: 10, alignItems: 'center' }}>
        <div style={{ width: 38, height: 38, borderRadius: 10, display: 'grid', placeItems: 'center', background: `color-mix(in oklch, ${c.color} 14%, transparent)`, color: c.color, flexShrink: 0 }}><Icon name={c.icon} size={20} /></div>
        <div style={{ fontSize: 13, color: 'var(--ink-2)', lineHeight: 1.4 }}>
          Moving your <b>{c.name}</b> from <b>{bk.date} · {bk.start}</b>. Pick a new slot — your bike re-assigns automatically.
        </div>
      </Card>
      <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--ink-3)', marginBottom: 10 }}>Available alternatives</div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 9, marginBottom: 16 }}>
        {alts.map(({ s, cap }) => {
          const on = pick === s.id;
          return (
            <button key={s.id} onClick={() => setPick(s.id)} style={{
              display: 'flex', alignItems: 'center', gap: 12, width: '100%', textAlign: 'left', padding: 13, cursor: 'pointer',
              borderRadius: 'var(--r)', background: 'var(--surface)', boxShadow: on ? 'var(--sh-2)' : 'var(--sh-1)',
              border: on ? '2px solid var(--primary)' : '1px solid var(--border)',
            }}>
              <div style={{ flex: 1 }}>
                <div style={{ fontWeight: 800, fontSize: 15 }}>{s.date} · {s.start}</div>
                <div style={{ fontSize: 12.5, color: 'var(--ink-3)', display: 'flex', gap: 12, marginTop: 3 }}>
                  <span style={{ display: 'flex', alignItems: 'center', gap: 4 }}><Icon name="pin" size={13} sw={2.1} />{LOC[s.loc].short}</span>
                  <span style={{ display: 'flex', alignItems: 'center', gap: 4 }}><Icon name="user" size={13} sw={2.1} />{INST[s.inst].name.split(' ')[0]}</span>
                </div>
              </div>
              <Badge tone={cap.bookable <= 1 ? 'warning' : 'success'} size="sm">{cap.bookable} left</Badge>
              <div style={{ width: 22, height: 22, borderRadius: 99, flexShrink: 0, display: 'grid', placeItems: 'center', border: on ? 'none' : '2px solid var(--border-2)', background: on ? 'var(--primary)' : 'transparent', color: '#fff' }}>{on && <Icon name="check" size={13} sw={3} />}</div>
            </button>
          );
        })}
        {alts.length === 0 && <Empty msg="No other slots available this week." />}
      </div>
      <div style={{ display: 'flex', gap: 10 }}>
        <Btn full variant="secondary" onClick={onClose}>Keep current</Btn>
        <Btn full variant="primary" disabled={!pick} onClick={() => onConfirm(SESSIONS.find(s => s.id === pick))}>Confirm new time</Btn>
      </div>
    </div>
  );
}

function CancelBody({ bk, onConfirm, onClose }) {
  const c = CT[bk.ct];
  return (
    <div>
      <Card pad={13} style={{ background: 'var(--surface-2)', border: 'none', marginBottom: 14, display: 'flex', gap: 9, alignItems: 'center' }}>
        <span style={{ color: 'var(--success)', display: 'flex' }}><Icon name="check-circle" size={20} /></span>
        <div style={{ fontSize: 13, color: 'var(--ink-2)', fontWeight: 600, lineHeight: 1.4 }}>
          You're <b>{SCHOOL.cancelCutoffHrs}h+</b> before this session — no cancellation fee.
        </div>
      </Card>
      <div style={{ fontSize: 14, color: 'var(--ink-2)', marginBottom: 16, lineHeight: 1.5 }}>
        Cancel your <b>{c.name}</b> on {bk.date} at {bk.start}? Your bike and place will be released.
      </div>
      <div style={{ display: 'flex', gap: 10 }}>
        <Btn full variant="secondary" onClick={onClose}>Keep it</Btn>
        <Btn full variant="danger" onClick={onConfirm}>Cancel booking</Btn>
      </div>
    </div>
  );
}

/* ---------------- Progress ---------------- */
function Progress({ onBell }) {
  return (
    <div className="ks-screen" style={{ padding: '6px 18px 20px' }}>
      <BookH title="My progress" onBell={onBell} />
      <div style={{ marginTop: 18 }}>
        <CourseProgress ct="cbt650" complete />
        <div style={{ height: 14 }} />
        <CourseProgress ct="practical" />
      </div>
    </div>
  );
}
function CourseProgress({ ct, complete }) {
  const c = CT[ct], comps = compsFor(ct);
  const prog = MY_PROGRESS[ct];
  const items = prog.items || {};
  return (
    <Card pad={0} style={{ overflow: 'hidden' }}>
      <div style={{ padding: 16, display: 'flex', alignItems: 'center', gap: 13, borderBottom: '1px solid var(--border)' }}>
        <div style={{ width: 42, height: 42, borderRadius: 12, display: 'grid', placeItems: 'center', background: `color-mix(in oklch, ${c.color} 14%, transparent)`, color: c.color }}><Icon name={c.icon} size={22} /></div>
        <div style={{ flex: 1 }}>
          <span className="mono" style={{ fontSize: 10.5, fontWeight: 700, color: c.color }}>{c.code}</span>
          <div style={{ fontWeight: 800, fontSize: 16 }}>{c.name}</div>
        </div>
        {complete ? <Badge tone="success" icon="check">Complete</Badge> : <Badge tone="primary">{prog.done}/{prog.total}</Badge>}
      </div>
      <div style={{ padding: '6px 16px' }}>
        {comps.map((it, i) => {
          const ok = complete || items[it.id];
          return (
            <div key={it.id} style={{ display: 'flex', alignItems: 'center', gap: 11, padding: '11px 0', borderBottom: i < comps.length - 1 ? '1px solid var(--border)' : 'none' }}>
              <div style={{ width: 24, height: 24, borderRadius: 99, flexShrink: 0, display: 'grid', placeItems: 'center', background: ok ? 'var(--success)' : 'var(--surface-3)', color: '#fff', border: ok ? 'none' : '1.5px solid var(--border-2)' }}>
                {ok ? <Icon name="check" size={14} sw={3} /> : <span style={{ fontSize: 11, fontWeight: 700, color: 'var(--ink-4)' }}>{i + 1}</span>}
              </div>
              <span style={{ fontSize: 14, fontWeight: 600, color: ok ? 'var(--ink)' : 'var(--ink-3)' }}>{it.label}</span>
            </div>
          );
        })}
      </div>
      {!complete && (
        <div style={{ padding: '0 16px 16px' }}>
          <Card pad={12} style={{ background: 'var(--surface-2)', border: 'none', display: 'flex', gap: 9, alignItems: 'flex-start' }}>
            <Avatar initials="AM" tone={25} size={26} />
            <div>
              <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--ink-2)' }}>Aoife · last session</div>
              <div style={{ fontSize: 13, color: 'var(--ink-2)', lineHeight: 1.4, marginTop: 2 }}>“Slow ride is really solid now. Let's nail the U-turn next time — looking strong for the 24th.”</div>
            </div>
          </Card>
        </div>
      )}
    </Card>
  );
}

/* ---------------- Licence & docs ---------------- */
function Licence({ onBack, onBell }) {
  return (
    <div className="ks-screen" style={{ padding: '6px 18px 30px', minHeight: '100%', background: 'var(--bg)' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 11, marginBottom: 18 }}>
        <button onClick={onBack} style={iconBtn}><Icon name="left" size={19} /></button>
        <div style={{ flex: 1, fontWeight: 800, fontSize: 22, letterSpacing: '-0.03em' }}>Licence & documents</div>
        <NotifBell role="student" onClick={onBell} style={iconBtn} />
        <Avatar initials={ME.initials} size={40} />
      </div>

      {/* provisional licence "card" */}
      <div style={{ borderRadius: 'var(--r-lg)', padding: 18, background: 'linear-gradient(135deg, oklch(0.42 0.13 277), oklch(0.55 0.18 277))', color: '#fff', boxShadow: 'var(--sh-2)', position: 'relative', overflow: 'hidden' }}>
        <div style={{ position: 'absolute', right: -20, top: -20, width: 100, height: 100, borderRadius: '50%', background: 'rgba(255,255,255,.10)' }} />
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <span style={{ fontSize: 11.5, fontWeight: 700, letterSpacing: '0.08em', opacity: .85 }}>PROVISIONAL · CAT {ME.cat}</span>
          <Icon name="card" size={20} />
        </div>
        <div className="mono" style={{ fontSize: 16, letterSpacing: '0.06em', margin: '20px 0 4px' }}>{ME.provisional}</div>
        <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, opacity: .85 }}>
          <span>{ME.name.toUpperCase()}</span><span>{ME.trans.toUpperCase()}</span>
        </div>
      </div>

      <div style={{ marginTop: 20 }}><SectionLabel>Certificates & tests</SectionLabel></div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 11 }}>
        <DocRow icon="shield" tone={160} title={`CBT certificate (DL196) · ${CT[ME.cbtVariant] ? CT[ME.cbtVariant].name : ''}`} meta={`Issued ${ME.cbtIssued}`} badge={<Badge tone="success">Valid to {ME.cbtExpiry}</Badge>} />
        <DocRow icon="check-circle" tone={277} title="Motorcycle theory test" meta={ME.theoryRef} badge={<Badge tone="success" icon="check">Passed {ME.theoryPassed}</Badge>} />
        <DocRow icon="target" tone={70} title="DVA practical test" meta={`${ME.practicalTest.centre} · ${ME.practicalTest.ref}`} badge={<Badge tone="warning">{ME.practicalTest.date} · {ME.practicalTest.time}</Badge>} />
      </div>
      <Card pad={13} style={{ marginTop: 14, background: 'var(--surface-2)', border: 'none', display: 'flex', gap: 9, alignItems: 'flex-start' }}>
        <span style={{ color: 'var(--ink-3)', display: 'flex' }}><Icon name="info" size={17} sw={2.1} /></span>
        <div style={{ fontSize: 12.5, color: 'var(--ink-3)', lineHeight: 1.45 }}>{SCHOOL.body} test dates are booked directly with {SCHOOL.body} — we store them here for prep scheduling and reminders.</div>
      </Card>
    </div>
  );
}
function DocRow({ icon, tone, title, meta, badge, muted }) {
  return (
    <Card pad={14} style={{ display: 'flex', alignItems: 'center', gap: 12, opacity: muted ? 0.7 : 1 }}>
      <div style={{ width: 40, height: 40, borderRadius: 11, flexShrink: 0, display: 'grid', placeItems: 'center', background: `oklch(0.93 0.05 ${tone})`, color: `oklch(0.46 0.12 ${tone})` }}><Icon name={icon} size={20} sw={2.1} /></div>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontWeight: 700, fontSize: 14.5 }}>{title}</div>
        <div className="mono" style={{ fontSize: 11, color: 'var(--ink-4)', marginTop: 2, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{meta}</div>
        <div style={{ marginTop: 7 }}>{badge}</div>
      </div>
    </Card>
  );
}

/* ---------------- Confirmation ---------------- */
function Confirmed({ data, onDone }) {
  const c = CT[data.ct], se = data.se, b = data.bike;
  return (
    <div className="ks-screen" style={{ padding: '20px 22px', minHeight: '100%', display: 'flex', flexDirection: 'column', background: 'var(--bg)' }}>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', textAlign: 'center' }}>
        <div style={{ width: 88, height: 88, borderRadius: '50%', background: 'var(--success)', display: 'grid', placeItems: 'center', color: '#fff', animation: 'ks-pop .5s cubic-bezier(.22,1.4,.4,1)', boxShadow: '0 12px 30px oklch(0.58 0.13 160 / .4)' }}>
          <Icon name="check" size={48} sw={3} />
        </div>
        <div style={{ fontWeight: 800, fontSize: 25, letterSpacing: '-0.03em', marginTop: 22 }}>You're booked in!</div>
        <div style={{ fontSize: 14.5, color: 'var(--ink-3)', marginTop: 6, lineHeight: 1.4, maxWidth: 280 }}>
          Confirmation sent. We'll remind you 48h before — see you at {LOC[se.loc].short}.
        </div>
        <Card pad={0} style={{ width: '100%', marginTop: 26, overflow: 'hidden', textAlign: 'left' }}>
          <div style={{ padding: '14px 16px', background: `color-mix(in oklch, ${c.color} 10%, transparent)`, borderBottom: '1px solid var(--border)', display: 'flex', alignItems: 'center', gap: 10 }}>
            <div style={{ width: 36, height: 36, borderRadius: 10, display: 'grid', placeItems: 'center', background: c.color, color: '#fff' }}><Icon name={c.icon} size={19} /></div>
            <div><div style={{ fontWeight: 800, fontSize: 15.5 }}>{c.name}</div><div style={{ fontSize: 12.5, color: 'var(--ink-3)' }}>{se.date} · {se.start}–{se.end}</div></div>
          </div>
          <div style={{ padding: '6px 16px' }}>
            <Row icon="pin" label="Location" value={LOC[se.loc].name} />
            <Row icon="moto" label="Bike" value={b ? `${b.name} · ${b.reg}` : 'Auto-assigned'} last />
          </div>
        </Card>
      </div>
      <Btn full size="lg" onClick={onDone}>View my bookings</Btn>
    </div>
  );
}

const iconBtn = { width: 40, height: 40, borderRadius: 11, border: '1px solid var(--border)', background: 'var(--surface)', display: 'grid', placeItems: 'center', color: 'var(--ink-2)', cursor: 'pointer', position: 'relative' };
const linkBtn = { border: 'none', background: 'transparent', color: 'var(--primary)', fontWeight: 700, fontSize: 13, cursor: 'pointer', fontFamily: 'var(--font)' };
const linkRow = { display: 'flex', alignItems: 'center', gap: 11, width: '100%', padding: 15, borderRadius: 'var(--r)', border: '1px solid var(--border)', background: 'var(--surface)', fontWeight: 700, fontSize: 14.5, color: 'var(--ink)', cursor: 'pointer', boxShadow: 'var(--sh-1)' };

Object.assign(window, { StudentApp });
