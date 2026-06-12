// Kickstand — Student booking flow (the marquee flow). Honest, bike-aware capacity.
const { useState: useStateB } = React;

// suitable, ready bikes for a course + student (cat/trans match)
function suitableBikes(ct, loc) {
  const reqCat = CT[ct] ? CT[ct].cat : 'A1';
  const isCbt = ct && ct.startsWith('cbt');
  return BIKES.filter(b =>
    b.cat === reqCat &&
    (isCbt ? true : b.trans === ME.trans) &&
    b.status === 'ready'
  ).map(b => ({ ...b, here: b.loc === loc }));
}
// real bookable = min(capacity left, free suitable bikes)
function honestCapacity(se) {
  const ct = se.ct;
  const free = suitableBikes(ct, se.loc);
  const freeHere = free.length; // simplification: cross-site moves allowed w/ notice
  const left = se.cap - se.booked;
  return { left, bikes: freeHere, bookable: Math.min(left, freeHere), free };
}

function Eligibility({ ct }) {
  const c = CT[ct];
  const passed = {
    'Provisional licence': true,
    'Valid CBT': true,
    'Theory test passed': !!ME.theoryPassed,
    'Aged 24+': false,
  };
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 7 }}>
      {c.prereqs.map(p => {
        const ok = passed[p];
        return (
          <div key={p} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13.5, fontWeight: 600, color: ok ? 'var(--ink-2)' : 'var(--danger)' }}>
            <span style={{ color: ok ? 'var(--success)' : 'var(--danger)', display: 'flex' }}>
              <Icon name={ok ? 'check-circle' : 'x-circle'} size={17} sw={2.2} />
            </span>
            {p}{!ok && <span style={{ color: 'var(--ink-4)', fontWeight: 600 }}> — required</span>}
          </div>
        );
      })}
    </div>
  );
}

function StudentBook({ onConfirmed, pending, onBell }) {
  const [step, setStep] = useStateB(1);
  const [ct, setCt] = useStateB(null);
  const [loc, setLoc] = useStateB('all');
  const [se, setSe] = useStateB(null);
  const [bike, setBike] = useStateB('any');

  const eligibleOf = (id) => id !== 'cbt600'; // Jordan (A2): CBT 650 + practical ok; direct-access CBT 600 needs 24+

  const goCourse = (id) => { if (!eligibleOf(id)) return; setCt(id); setStep(2); };
  const sessions = SESSIONS.filter(s => s.ct === ct && (loc === 'all' || s.loc === loc));

  /* ---- Step 1: course type ---- */
  if (step === 1) return (
    <div className="ks-screen" style={{ padding: '6px 18px 20px' }}>
      <H title="Book training" sub="Pick a course to see honest, bike-aware availability." onBell={onBell} />
      {pending && (
        <Card pad={12} style={{ marginTop: 14, background: 'var(--warning-tint)', border: 'none', display: 'flex', gap: 9, alignItems: 'flex-start' }}>
          <span style={{ color: 'oklch(0.55 0.13 70)', display: 'flex', marginTop: 1 }}><Icon name="clock" size={17} sw={2.1} /></span>
          <div style={{ fontSize: 12.5, color: 'var(--ink-2)', fontWeight: 600, lineHeight: 1.45 }}>Your account is awaiting approval — browse freely, but you can’t confirm a booking just yet.</div>
        </Card>
      )}
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12, marginTop: 16 }}>
        {COURSE_TYPES.map(c => {
          const elig = eligibleOf(c.id);
          return (
            <Card key={c.id} pad={0} hover={elig} onClick={elig ? () => goCourse(c.id) : undefined}
              style={{ opacity: elig ? 1 : 0.72, overflow: 'hidden' }}>
              <div style={{ display: 'flex', gap: 13, padding: 15, alignItems: 'flex-start' }}>
                <div style={{ width: 46, height: 46, borderRadius: 13, flexShrink: 0, display: 'grid', placeItems: 'center', background: `color-mix(in oklch, ${c.color} 16%, transparent)`, color: c.color }}>
                  <Icon name={c.icon} size={24} sw={2} />
                </div>
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <span className="mono" style={{ fontSize: 11, fontWeight: 700, color: c.color, letterSpacing: '0.04em' }}>{c.code}</span>
                    <span style={{ fontSize: 12, color: 'var(--ink-4)' }}>· {c.durationShort} · {c.ratio}</span>
                  </div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap' }}>
                    <div style={{ fontWeight: 800, fontSize: 16.5, letterSpacing: '-0.02em', margin: '2px 0 3px' }}>{c.name}</div>
                    {c.non_teaching && <Badge tone="warning" size="sm" icon="flag">Test day</Badge>}
                  </div>
                  <div style={{ fontSize: 13, color: 'var(--ink-3)', lineHeight: 1.4 }}>{c.blurb}</div>
                </div>
                {elig
                  ? <span style={{ color: 'var(--ink-4)', alignSelf: 'center' }}><Icon name="right" size={20} /></span>
                  : <Icon name="x" size={0} />}
              </div>
              {!elig && (
                <div style={{ background: 'var(--danger-tint)', padding: '10px 15px', display: 'flex', alignItems: 'center', gap: 8, fontSize: 12.5, fontWeight: 700, color: 'var(--danger)' }}>
                  <Icon name="alert-circle" size={15} sw={2.2} /> {c.lockMsg || 'Not available on your licence yet'}
                </div>
              )}
            </Card>
          );
        })}
      </div>
    </div>
  );

  const c = CT[ct];

  /* ---- Step 2: slot list ---- */
  if (step === 2) return (
    <div className="ks-screen" style={{ padding: '6px 18px 20px' }}>
      <BackRow onBack={() => setStep(1)} code={c.code} color={c.color} name={c.name} />
      <div style={{ margin: '14px 0' }}>
        <Seg full value={loc} onChange={setLoc} items={[{ value: 'all', label: 'All sites' }, ...LOCATIONS.map(l => ({ value: l.id, label: l.short }))]} />
      </div>
      <Card pad={12} style={{ background: 'var(--primary-tint)', border: 'none', display: 'flex', gap: 9, alignItems: 'center', marginBottom: 14 }}>
        <span style={{ color: 'var(--primary)', display: 'flex' }}><Icon name="info" size={18} sw={2.1} /></span>
        <div style={{ fontSize: 12.5, color: 'var(--primary-deep)', fontWeight: 600, lineHeight: 1.4 }}>
          Places shown are <b>bike-aware</b> — we only offer slots where a suitable bike is actually free.
        </div>
      </Card>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 11 }}>
        {sessions.map(s => {
          const cap = honestCapacity(s);
          const full = cap.bookable <= 0;
          return (
            <Card key={s.id} pad={14} hover={!full} onClick={full ? undefined : () => { setSe(s); setBike('any'); setStep(3); }}
              style={{ opacity: full ? 0.6 : 1 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', gap: 10 }}>
                <div>
                  <div style={{ fontWeight: 800, fontSize: 15.5 }}>{s.date}</div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6, color: 'var(--ink-3)', fontSize: 13, marginTop: 3 }}>
                    <Icon name="clock" size={14} sw={2.1} /> {s.start}–{s.end}
                  </div>
                </div>
                {full
                  ? <Badge tone="neutral">Full</Badge>
                  : <Badge tone={cap.bookable <= 1 ? 'warning' : 'success'}>{cap.bookable} {cap.bookable === 1 ? 'place' : 'places'} left</Badge>}
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 14, marginTop: 11, paddingTop: 11, borderTop: '1px solid var(--border)', fontSize: 12.5, color: 'var(--ink-2)', fontWeight: 600 }}>
                <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}><Icon name="pin" size={14} sw={2.1} />{LOC[s.loc].short}</span>
                <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}><Avatar initials={INST[s.inst].initials} tone={INST[s.inst].tone} size={20} />{INST[s.inst].name.split(' ')[0]}</span>
                <span style={{ display: 'flex', alignItems: 'center', gap: 5, marginLeft: 'auto', color: 'var(--ink-4)' }}><Icon name="moto" size={15} sw={1.8} />{cap.bikes} free</span>
              </div>
            </Card>
          );
        })}
        {sessions.length === 0 && <Empty msg="No slots match" hint="Try another site or a different week." />}
      </div>
    </div>
  );

  /* ---- Step 3: bike choice ---- */
  if (step === 3) {
    const cap = honestCapacity(se);
    return (
      <div className="ks-screen" style={{ padding: '6px 18px 20px' }}>
        <BackRow onBack={() => setStep(2)} code={c.code} color={c.color} name={`${se.date} · ${se.start}`} />
        <div style={{ marginTop: 16 }}>
          <SectionLabel>Choose your bike</SectionLabel>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          <BikeOption selected={bike === 'any'} onClick={() => setBike('any')}
            glyph={<div style={{ width: 40, height: 40, borderRadius: 12, display: 'grid', placeItems: 'center', background: 'var(--primary-tint)', color: 'var(--primary)' }}><Icon name="sparkle" size={22} /></div>}
            title="Any suitable bike" sub={`We'll auto-assign a free ${c.cat} ${ME.trans} bike`} recommend />
          {cap.free.map(b => (
            <BikeOption key={b.id} selected={bike === b.id} onClick={() => setBike(b.id)}
              glyph={<BikeGlyph cat={b.cat} />}
              title={b.name} reg={b.reg}
              sub={`${b.cat} · ${b.cc}cc · ${b.trans}`}
              tag={b.here ? null : { label: `at ${LOC[b.loc].short}`, tone: 'warning' }} />
          ))}
        </div>
        <div style={{ position: 'sticky', bottom: 0, paddingTop: 16, marginTop: 4 }}>
          <Btn full size="lg" iconRight="arrow-right" onClick={() => setStep(4)}>Review booking</Btn>
        </div>
      </div>
    );
  }

  /* ---- Step 4: confirm ---- */
  if (step === 4) {
    const b = bike === 'any' ? null : BIKE[bike];
    return (
      <div className="ks-screen" style={{ padding: '6px 18px 20px' }}>
        <BackRow onBack={() => setStep(3)} code={c.code} color={c.color} name="Review" />
        <Card pad={0} style={{ marginTop: 16, overflow: 'hidden' }}>
          <div style={{ padding: '16px 18px', background: `color-mix(in oklch, ${c.color} 10%, transparent)`, borderBottom: '1px solid var(--border)' }}>
            <span className="mono" style={{ fontSize: 11, fontWeight: 700, color: c.color }}>{c.code}</span>
            <div style={{ fontWeight: 800, fontSize: 18, letterSpacing: '-0.02em' }}>{c.name}</div>
          </div>
          <div style={{ padding: '6px 18px' }}>
            <Row icon="calendar" label="Date" value={se.date} />
            <Row icon="clock" label="Time" value={`${se.start} – ${se.end}`} />
            <Row icon="pin" label="Location" value={LOC[se.loc].name} />
            <Row icon="user" label="Instructor" value={INST[se.inst].name} />
            <Row icon="moto" label="Bike" value={b ? `${b.name} · ${b.reg}` : 'Any suitable (auto-assigned)'} last />
          </div>
        </Card>
        <Card pad={13} style={{ marginTop: 12, background: 'var(--surface-2)', display: 'flex', gap: 9, alignItems: 'flex-start' }}>
          <span style={{ color: 'var(--ink-3)', display: 'flex', marginTop: 1 }}><Icon name="info" size={17} sw={2.1} /></span>
          <div style={{ fontSize: 12.5, color: 'var(--ink-3)', lineHeight: 1.45 }}>
            Free cancellation up to <b style={{ color: 'var(--ink-2)' }}>{SCHOOL.cancelCutoffHrs}h</b> before. Pay in person on the day — <b style={{ color: 'var(--ink-2)' }}>{c.price}</b>.
          </div>
        </Card>
        {c.non_teaching && (
          <Card pad={12} style={{ marginTop: 12, background: 'var(--surface-2)', border: 'none', display: 'flex', gap: 9, alignItems: 'flex-start' }}>
            <span style={{ color: 'oklch(0.55 0.13 70)', display: 'flex', marginTop: 1 }}><Icon name="alert-circle" size={16} sw={2.1} /></span>
            <div style={{ fontSize: 12.5, color: 'var(--ink-3)', lineHeight: 1.45 }}>Heads-up: bring your CBT certificate and theory pass on the day — the examiner will check them. This reserves a bike + escort, not the test itself.</div>
          </Card>
        )}
        <div style={{ position: 'sticky', bottom: 0, paddingTop: 16 }}>
          {pending
            ? <Btn full size="lg" icon="clock" variant="secondary" disabled>Awaiting approval to book</Btn>
            : <Btn full size="lg" icon="check" onClick={() => onConfirmed({ ct, se, bike: b })}>Confirm booking</Btn>}
        </div>
      </div>
    );
  }
}

/* sub-pieces */
// H (exported as BookH) is the standard page header for tab-level student
// screens: title on the left, optional subtitle below it, notifications
// bell + avatar on the right. Keeping these on every tab matches the
// Flutter app's StudentTopActions cluster — students should always know
// where notifications and "sign out" live.
function H({ title, sub, onBell }) {
  return (
    <div style={{ display: 'flex', alignItems: 'flex-start', gap: 10 }}>
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ fontWeight: 800, fontSize: 26, letterSpacing: '-0.03em' }}>{title}</div>
        {sub && <div style={{ fontSize: 14, color: 'var(--ink-3)', marginTop: 4, lineHeight: 1.4 }}>{sub}</div>}
      </div>
      <div style={{ display: 'flex', gap: 9, alignItems: 'center', flexShrink: 0 }}>
        <NotifBell role="student" onClick={onBell} style={iconBtn} />
        <Avatar initials={ME.initials} size={40} />
      </div>
    </div>
  );
}
function BackRow({ onBack, code, color, name }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 11 }}>
      <button onClick={onBack} style={{ width: 38, height: 38, borderRadius: 11, border: '1px solid var(--border)', background: 'var(--surface)', display: 'grid', placeItems: 'center', color: 'var(--ink-2)', cursor: 'pointer' }}><Icon name="left" size={19} /></button>
      <div>
        <span className="mono" style={{ fontSize: 10.5, fontWeight: 700, color }}>{code}</span>
        <div style={{ fontWeight: 800, fontSize: 17, letterSpacing: '-0.02em', lineHeight: 1.1 }}>{name}</div>
      </div>
    </div>
  );
}
function BikeOption({ selected, onClick, glyph, title, sub, reg, tag, recommend }) {
  return (
    <button onClick={onClick} style={{
      display: 'flex', alignItems: 'center', gap: 12, width: '100%', textAlign: 'left',
      padding: 12, borderRadius: 'var(--r)', background: 'var(--surface)', cursor: 'pointer',
      border: selected ? '2px solid var(--primary)' : '1px solid var(--border)',
      boxShadow: selected ? 'var(--sh-2)' : 'var(--sh-1)', transition: 'all .16s',
    }}>
      {glyph}
      <div style={{ flex: 1, minWidth: 0 }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 7, flexWrap: 'wrap' }}>
          <span style={{ fontWeight: 800, fontSize: 15 }}>{title}</span>
          {recommend && <Badge tone="primary" size="sm">Recommended</Badge>}
          {tag && <Badge tone={tag.tone} size="sm">{tag.label}</Badge>}
        </div>
        <div style={{ fontSize: 12.5, color: 'var(--ink-3)', marginTop: 2, display: 'flex', gap: 7, alignItems: 'center' }}>
          {sub}{reg && <span className="mono" style={{ fontSize: 11, color: 'var(--ink-4)' }}>{reg}</span>}
        </div>
      </div>
      <div style={{ width: 22, height: 22, borderRadius: 99, flexShrink: 0, display: 'grid', placeItems: 'center', border: selected ? 'none' : '2px solid var(--border-2)', background: selected ? 'var(--primary)' : 'transparent', color: '#fff' }}>
        {selected && <Icon name="check" size={14} sw={3} />}
      </div>
    </button>
  );
}
function Row({ icon, label, value, last }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '12px 0', borderBottom: last ? 'none' : '1px solid var(--border)' }}>
      <span style={{ color: 'var(--ink-4)', display: 'flex' }}><Icon name={icon} size={18} sw={2} /></span>
      <span style={{ fontSize: 13, color: 'var(--ink-3)', width: 78 }}>{label}</span>
      <span style={{ fontWeight: 700, fontSize: 14, color: 'var(--ink)', flex: 1, textAlign: 'right' }}>{value}</span>
    </div>
  );
}
function Empty({ msg, icon = 'search', hint }) {
  return (
    <div style={{ textAlign: 'center', padding: '38px 24px' }}>
      <div style={{ width: 48, height: 48, borderRadius: 14, margin: '0 auto 12px', display: 'grid', placeItems: 'center', background: 'var(--surface-3)', color: 'var(--ink-4)' }}><Icon name={icon} size={24} /></div>
      <div style={{ color: 'var(--ink-2)', fontSize: 14.5, fontWeight: 700 }}>{msg}</div>
      {hint && <div style={{ color: 'var(--ink-4)', fontSize: 13, marginTop: 4 }}>{hint}</div>}
    </div>
  );
}

Object.assign(window, { StudentBook, suitableBikes, honestCapacity, BookH: H, BackRow, Row, Empty });
