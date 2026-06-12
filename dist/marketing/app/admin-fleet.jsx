// Kickstand — Admin: Fleet management + Disruption resolution (the interactive cores).
const { useState: useStateAF } = React;

/* ============ FLEET ============ */
function FleetScreen({ fire }) {
  const [bikes, setBikes] = useStateAF(BIKES);
  const [filter, setFilter] = useStateAF('all');
  const [unavail, setUnavail] = useStateAF(null); // bike to mark unavailable
  const [add, setAdd] = useStateAF(false);
  const counts = {
    all: bikes.length,
    ready: bikes.filter(b => b.status === 'ready').length,
    down: bikes.filter(b => b.status !== 'ready').length,
  };
  const shown = bikes.filter(b => filter === 'all' || (filter === 'ready' ? b.status === 'ready' : b.status !== 'ready'));

  const markUnavail = (id, reason) => {
    setBikes(bs => bs.map(b => b.id === id ? { ...b, status: reason, note: REASON_NOTE[reason] } : b));
    setUnavail(null);
    fire('Bike taken offline — future slots updated', 'wrench');
  };
  const restore = (id) => { setBikes(bs => bs.map(b => b.id === id ? { ...b, status: 'ready', note: undefined } : b)); fire('Bike back in service', 'check-circle'); };
  const addBike = (data) => { setBikes(bs => [...bs, { ...data, id: 'b' + Date.now(), status: 'ready', loc: data.home }]); setAdd(false); fire('Bike added to fleet', 'check-circle'); };

  return (
    <div className="ks-screen">
      <PageHead title="Bike fleet" sub={`${counts.ready} ready · ${counts.down} unavailable across 3 sites`}
        actions={<Btn icon="plus" onClick={() => setAdd(true)}>Add bike</Btn>} />
      <div style={{ display: 'flex', gap: 8, marginBottom: 16 }}>
        <Seg value={filter} onChange={setFilter} items={[
          { value: 'all', label: `All ${counts.all}` },
          { value: 'ready', label: `Ready ${counts.ready}` },
          { value: 'down', label: `Unavailable ${counts.down}` },
        ]} />
      </div>
      <Card pad={0} style={{ overflow: 'hidden' }}>
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13.5 }}>
          <thead>
            <tr style={{ background: 'var(--surface-2)', textAlign: 'left' }}>
              {['Bike', 'Reg', 'Category', 'Transmission', 'Home', 'Current', 'Status', ''].map((h, i) => (
                <th key={i} style={thStyle}>{h}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {shown.map(b => (
              <tr key={b.id} style={{ borderTop: '1px solid var(--border)' }}>
                <td style={tdStyle}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                    <BikeGlyph cat={b.cat} size={34} />
                    <span style={{ fontWeight: 700 }}>{b.name}</span>
                  </div>
                </td>
                <td style={tdStyle}><span className="mono" style={{ fontSize: 12.5, fontWeight: 700 }}>{b.reg}</span></td>
                <td style={tdStyle}><Badge tone={b.cat === 'A1' ? 'primary' : 'warning'} size="sm">{b.cat}</Badge></td>
                <td style={{ ...tdStyle, color: 'var(--ink-2)', textTransform: 'capitalize' }}>{b.cc}cc · {b.trans}</td>
                <td style={{ ...tdStyle, color: 'var(--ink-2)' }}>{LOC[b.home].short}</td>
                <td style={tdStyle}>
                  <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, color: b.loc !== b.home ? 'oklch(0.55 0.13 70)' : 'var(--ink-2)', fontWeight: b.loc !== b.home ? 700 : 400 }}>
                    {b.loc !== b.home && <Icon name="route" size={14} sw={2.2} />}{LOC[b.loc].short}
                  </span>
                </td>
                <td style={tdStyle}><BikeStatus status={b.status} size="sm" /></td>
                <td style={{ ...tdStyle, textAlign: 'right' }}>
                  {b.status === 'ready'
                    ? <Btn size="sm" variant="secondary" onClick={() => setUnavail(b)}>Take offline</Btn>
                    : <Btn size="sm" variant="soft" onClick={() => restore(b.id)}>Restore</Btn>}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </Card>

      <Modal open={!!unavail} onClose={() => setUnavail(null)} title="Take bike offline" icon="wrench" tone="warning" width={440}>
        {unavail && <UnavailBody bike={unavail} onConfirm={markUnavail} onClose={() => setUnavail(null)} />}
      </Modal>
      <Modal open={add} onClose={() => setAdd(false)} title="Add bike to fleet" icon="moto" width={500}>
        {add && <BikeEditor onSave={addBike} onCancel={() => setAdd(false)} />}
      </Modal>
    </div>
  );
}

function BikeEditor({ onSave, onCancel }) {
  const [name, setName] = useStateAF('');
  const [reg, setReg] = useStateAF('');
  const [cat, setCat] = useStateAF('A1');
  const [trans, setTrans] = useStateAF('manual');
  const [cc, setCc] = useStateAF('125');
  const [home, setHome] = useStateAF('belfast');
  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, padding: 12, borderRadius: 'var(--r)', background: 'var(--surface-2)', marginBottom: 18 }}>
        <BikeGlyph cat={cat} size={42} />
        <div style={{ minWidth: 0 }}>
          <div style={{ fontWeight: 800, fontSize: 15 }}>{name.trim() || 'New bike'}</div>
          <div className="mono" style={{ fontSize: 12, color: 'var(--ink-4)' }}>{reg.trim() || 'REG —'}</div>
        </div>
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 16 }}>
        <BFLabel label="Model"><BFInput value={name} onChange={setName} placeholder="Honda CB125F" /></BFLabel>
        <BFLabel label="Registration"><BFInput value={reg} onChange={v => setReg(v.toUpperCase())} placeholder="GKZ 4473" /></BFLabel>
      </div>
      <div style={{ display: 'flex', gap: 24, marginBottom: 16, flexWrap: 'wrap' }}>
        <BFLabel label="Category"><Seg value={cat} onChange={setCat} items={['A1', 'A2', 'A']} /></BFLabel>
        <BFLabel label="Transmission"><Seg value={trans} onChange={setTrans} items={[{ value: 'manual', label: 'Manual' }, { value: 'auto', label: 'Auto' }]} /></BFLabel>
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: '120px 1fr', gap: 12, marginBottom: 16, alignItems: 'end' }}>
        <BFLabel label="Engine (cc)"><BFInput value={cc} onChange={v => setCc(v.replace(/[^0-9]/g, ''))} placeholder="125" /></BFLabel>
        <BFLabel label="Home location"><Seg value={home} onChange={setHome} items={LOCATIONS.map(l => ({ value: l.id, label: l.short }))} /></BFLabel>
      </div>
      <div style={{ display: 'flex', gap: 10, marginTop: 22 }}>
        <Btn full variant="secondary" onClick={onCancel}>Cancel</Btn>
        <Btn full variant="primary" icon="check" disabled={!name.trim() || !reg.trim()} onClick={() => onSave({ name: name.trim(), reg: reg.trim(), cat, trans, cc: Number(cc) || 0, home })}>Add bike</Btn>
      </div>
    </div>
  );
}
function BFLabel({ label, children }) {
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
      <span style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--ink-2)' }}>{label}</span>
      {children}
    </div>
  );
}
function BFInput({ value, onChange, placeholder }) {
  return (
    <input value={value} onChange={e => onChange(e.target.value)} placeholder={placeholder}
      style={{ width: '100%', height: 42, padding: '0 13px', borderRadius: 'var(--r-sm)', border: '1px solid var(--border-2)', background: 'var(--surface)', fontFamily: 'var(--font)', fontSize: 14.5, fontWeight: 500, color: 'var(--ink)', outline: 'none', boxSizing: 'border-box' }} />
  );
}
const REASON_NOTE = { mechanic: 'At mechanic', damaged: 'Damaged', offroad: 'Off-road' };
function UnavailBody({ bike, onConfirm, onClose }) {
  const [reason, setReason] = useStateAF('mechanic');
  const reasons = [
    { id: 'mechanic', label: 'At mechanic', icon: 'wrench' },
    { id: 'damaged', label: 'Damaged / broken', icon: 'alert' },
    { id: 'offroad', label: 'Off-road', icon: 'ban' },
  ];
  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 11, padding: 12, background: 'var(--surface-2)', borderRadius: 'var(--r)', marginBottom: 16 }}>
        <BikeGlyph cat={bike.cat} size={38} />
        <div><div style={{ fontWeight: 800 }}>{bike.name}</div><div className="mono" style={{ fontSize: 12, color: 'var(--ink-4)' }}>{bike.reg}</div></div>
      </div>
      <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--ink-2)', marginBottom: 9 }}>Reason</div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 8 }}>
        {reasons.map(r => (
          <button key={r.id} onClick={() => setReason(r.id)} style={{
            display: 'flex', alignItems: 'center', gap: 10, padding: '11px 13px', borderRadius: 'var(--r-sm)', cursor: 'pointer',
            border: reason === r.id ? '2px solid var(--primary)' : '1px solid var(--border-2)', background: 'var(--surface)',
            fontFamily: 'var(--font)', fontWeight: 700, fontSize: 14, color: 'var(--ink)', textAlign: 'left',
          }}>
            <Icon name={r.icon} size={18} sw={2.1} style={{ color: 'var(--ink-3)' }} />{r.label}
          </button>
        ))}
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 14, fontSize: 12.5, color: 'var(--ink-3)' }}>
        <Icon name="info" size={15} sw={2.1} /> Starts now. Affected future bookings move to <b style={{ color: 'var(--ink-2)' }}>&nbsp;needs reassignment</b>.
      </div>
      <div style={{ display: 'flex', gap: 10, marginTop: 18 }}>
        <Btn full variant="secondary" onClick={onClose}>Cancel</Btn>
        <Btn full variant="primary" onClick={() => onConfirm(bike.id, reason)}>Take offline</Btn>
      </div>
    </div>
  );
}

/* ============ DISRUPTION RESOLUTION ============ */
function DisruptionScreen({ fire }) {
  const bike = BIKE[DISRUPTION.bike];
  const [rows, setRows] = useStateAF(DISRUPTION.affected);
  const resolved = rows.filter(r => r.status === 'swapped' || r.status === 'cancelled').length;

  const doSwap = (i, bikeId) => { setRows(rs => rs.map((r, j) => j === i ? { ...r, status: 'swapped', swapTo: bikeId } : r)); fire('Reassigned — student notified', 'check-circle'); };
  const doCancel = (i) => { setRows(rs => rs.map((r, j) => j === i ? { ...r, status: 'cancelled' } : r)); fire('Cancelled with approval — slot held', 'check-circle'); };

  return (
    <div className="ks-screen">
      <PageHead title="Resolve disruption" sub="Reassign affected bookings or cancel with manager approval." />
      {/* event banner */}
      <Card pad={0} style={{ overflow: 'hidden', marginBottom: 18, borderColor: 'var(--danger)' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 14, padding: 18, background: 'var(--danger-tint)' }}>
          <div style={{ width: 52, height: 52, borderRadius: 14, display: 'grid', placeItems: 'center', background: 'var(--danger)', color: '#fff', flexShrink: 0 }}><Icon name="alert" size={28} /></div>
          <div style={{ flex: 1 }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 9 }}>
              <span style={{ fontWeight: 800, fontSize: 17 }}>{bike.name} is down</span>
              <span className="mono" style={{ fontSize: 12, fontWeight: 700, color: 'var(--danger)' }}>{bike.reg}</span>
              <BikeStatus status="damaged" size="sm" />
            </div>
            <div style={{ fontSize: 13, color: 'var(--ink-2)', marginTop: 3 }}>{bike.note} · reported by {DISRUPTION.reportedBy} · {DISRUPTION.at} · {LOC[DISRUPTION.loc].name}</div>
          </div>
          <div style={{ textAlign: 'center', flexShrink: 0 }}>
            <div style={{ fontWeight: 800, fontSize: 24, color: 'var(--danger)', lineHeight: 1 }}>{resolved}/{rows.length}</div>
            <div style={{ fontSize: 11, color: 'var(--ink-3)', fontWeight: 700 }}>RESOLVED</div>
          </div>
        </div>
      </Card>

      <SectionLabel>Affected bookings</SectionLabel>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
        {rows.map((r, i) => <AffectedRow key={i} r={r} onSwap={(bid) => doSwap(i, bid)} onCancel={() => doCancel(i)} />)}
      </div>
    </div>
  );
}

function AffectedRow({ r, onSwap, onCancel }) {
  // suggest a free A1 bike at Belfast that isn't the broken one
  const suggestion = BIKES.find(b => b.status === 'ready' && b.cat === 'A1' && b.id !== 'b8' && b.loc === 'belfast') || BIKES.find(b => b.status === 'ready' && b.cat === 'A1');
  const [course, who] = r.booking.split(' · ');
  return (
    <Card pad={16}>
      <div style={{ display: 'flex', alignItems: 'flex-start', gap: 14 }}>
        <div style={{ flex: 1 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 9, marginBottom: 4 }}>
            <Badge tone="neutral" size="sm">{course}</Badge>
            <span style={{ fontWeight: 800, fontSize: 15.5 }}>{who}</span>
          </div>
          <div style={{ fontSize: 13, color: 'var(--ink-3)', display: 'flex', alignItems: 'center', gap: 5 }}><Icon name="calendar" size={14} sw={2} />{r.session}</div>
        </div>
        {/* state */}
        {r.status === 'swapped' && (
          <Badge tone="success" icon="check">Swapped → {BIKE[r.swapTo]?.name} {BIKE[r.swapTo]?.reg}</Badge>
        )}
        {r.status === 'cancelled' && <Badge tone="warning" icon="shield">Cancelled · slot held</Badge>}
      </div>

      {(r.status === 'pending' || r.status === 'approval') && (
        <div style={{ marginTop: 14, paddingTop: 14, borderTop: '1px solid var(--border)' }}>
          {suggestion && r.status === 'pending' ? (
            <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10, flex: 1, minWidth: 220 }}>
                <div style={{ width: 36, height: 36, borderRadius: 99, display: 'grid', placeItems: 'center', background: 'var(--success-tint)', color: 'var(--success)' }}><Icon name="sparkle" size={18} /></div>
                <div>
                  <div style={{ fontSize: 12, color: 'var(--ink-3)', fontWeight: 600 }}>Suggested swap — suitable & free here</div>
                  <div style={{ fontWeight: 700, fontSize: 14 }}>{suggestion.name} <span className="mono" style={{ fontSize: 12, color: 'var(--ink-4)' }}>{suggestion.reg}</span></div>
                </div>
              </div>
              <div style={{ display: 'flex', gap: 8 }}>
                <Btn size="sm" variant="secondary" icon="x" onClick={onCancel}>No bike — cancel</Btn>
                <Btn size="sm" variant="success" icon="swap" onClick={() => onSwap(suggestion.id)}>Swap bike</Btn>
              </div>
            </div>
          ) : (
            <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 9, flex: 1, minWidth: 220, color: 'var(--ink-2)', fontSize: 13, fontWeight: 600 }}>
                <Icon name="alert-circle" size={17} sw={2.1} style={{ color: 'oklch(0.55 0.13 70)' }} />
                No suitable bike free — needs manager approval. Slot stays held for the student.
              </div>
              <Btn size="sm" variant="primary" icon="shield" onClick={onCancel}>Approve cancellation</Btn>
            </div>
          )}
        </div>
      )}
    </Card>
  );
}

const thStyle = { padding: '11px 16px', fontSize: 11.5, fontWeight: 700, letterSpacing: '0.04em', textTransform: 'uppercase', color: 'var(--ink-3)', whiteSpace: 'nowrap' };
const tdStyle = { padding: '12px 16px', verticalAlign: 'middle' };

function PageHead({ title, sub, actions }) {
  return (
    <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between', gap: 16, marginBottom: 18 }}>
      <div>
        <div style={{ fontWeight: 800, fontSize: 24, letterSpacing: '-0.03em' }}>{title}</div>
        {sub && <div style={{ fontSize: 14, color: 'var(--ink-3)', marginTop: 3 }}>{sub}</div>}
      </div>
      {actions}
    </div>
  );
}

Object.assign(window, { FleetScreen, DisruptionScreen, PageHead, adminTh: thStyle, adminTd: tdStyle });
