// Kickstand — Manager: Students list + Student detail (progress, tests, ledger,
// incidents, staff-only notes & flags). Web-first, manager-only.
const { useState: useStateST } = React;

function StudentsScreen({ fire }) {
  const [recs, setRecs] = useStateST(SREC);
  const [sel, setSel] = useStateST(null);
  const update = (id, fn) => setRecs(r => ({ ...r, [id]: fn(r[id]) }));
  if (sel) return <StudentDetail id={sel} rec={recs[sel]} onBack={() => setSel(null)} update={(fn) => update(sel, fn)} fire={fire} />;
  return <StudentsList recs={recs} onOpen={setSel} />;
}

/* ---------------- List ---------------- */
function StudentsList({ recs, onOpen }) {
  const [q, setQ] = useStateST('');
  const [filter, setFilter] = useStateST('all');
  const rows = STUDENT_LIST.map(id => ({ id, stu: STU[id], rec: recs[id], bal: (recs[id].charges.reduce((a, c) => a + c.amount, 0) - recs[id].payments.reduce((a, p) => a + p.amount, 0)) }))
    .filter(r => r.stu.name.toLowerCase().includes(q.toLowerCase()))
    .filter(r => filter === 'all' || (filter === 'owes' ? r.bal > 0 : filter === 'flags' ? r.rec.flags.length : true));
  const owingTotal = STUDENT_LIST.reduce((a, id) => a + Math.max(0, balanceOf(id)), 0);
  return (
    <div className="ks-screen">
      <PageHead title="Students" sub={`${STUDENT_LIST.length} riders · £${owingTotal} outstanding across the school`} />
      <div style={{ display: 'flex', gap: 10, marginBottom: 16, alignItems: 'center', flexWrap: 'wrap' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '0 13px', height: 40, borderRadius: 'var(--r-sm)', border: '1px solid var(--border-2)', background: 'var(--surface)', minWidth: 240 }}>
          <Icon name="search" size={17} style={{ color: 'var(--ink-4)' }} />
          <input value={q} onChange={e => setQ(e.target.value)} placeholder="Search students" style={{ border: 'none', outline: 'none', background: 'transparent', fontFamily: 'var(--font)', fontSize: 14, color: 'var(--ink)', width: 180 }} />
        </div>
        <Seg value={filter} onChange={setFilter} items={[{ value: 'all', label: 'All' }, { value: 'owes', label: 'Owes money' }, { value: 'flags', label: 'Has flags' }]} />
      </div>
      <Card pad={0} style={{ overflow: 'hidden' }}>
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13.5 }}>
          <thead><tr style={{ background: 'var(--surface-2)', textAlign: 'left' }}>
            {['Student', 'Stage', 'Lessons', 'Balance', 'Flags', ''].map((h, i) => <th key={i} style={adminTh}>{h}</th>)}
          </tr></thead>
          <tbody>
            {rows.map(({ id, stu, rec, bal }, i) => (
              <tr key={id} onClick={() => onOpen(id)} style={{ borderTop: '1px solid var(--border)', cursor: 'pointer' }}
                onMouseEnter={e => e.currentTarget.style.background = 'var(--surface-2)'} onMouseLeave={e => e.currentTarget.style.background = 'transparent'}>
                <td style={adminTd}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 11 }}>
                    <Avatar initials={stu.initials} tone={(i * 55 + 277) % 360} size={36} />
                    <div><div style={{ fontWeight: 700 }}>{stu.name}</div><div style={{ fontSize: 12, color: 'var(--ink-4)' }}>Cat {stu.cat} · {stu.trans}</div></div>
                  </div>
                </td>
                <td style={adminTd}><Badge tone="neutral" size="sm">{rec.stage}</Badge></td>
                <td style={{ ...adminTd, color: 'var(--ink-2)', fontWeight: 600 }}>{rec.lessons}</td>
                <td style={adminTd}>
                  {bal > 0 ? <span style={{ fontWeight: 800, color: 'var(--danger)' }}>£{bal} owed</span> : <span style={{ fontWeight: 700, color: 'var(--success)' }}>Settled</span>}
                </td>
                <td style={adminTd}>{rec.flags.length ? <Badge tone="warning" size="sm" icon="shield">{rec.flags.length}</Badge> : <span style={{ color: 'var(--ink-4)' }}>—</span>}</td>
                <td style={{ ...adminTd, textAlign: 'right' }}><Icon name="right" size={18} style={{ color: 'var(--ink-4)' }} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      </Card>
    </div>
  );
}

/* ---------------- Detail ---------------- */
function StudentDetail({ id, rec, onBack, update, fire }) {
  const stu = STU[id];
  const [modal, setModal] = useStateST(null); // 'pay'|'charge'|'flag'|'note'|'incident'
  const charged = rec.charges.reduce((a, c) => a + c.amount, 0);
  const paid = rec.payments.reduce((a, p) => a + p.amount, 0);
  const bal = charged - paid;

  const addPayment = (d) => { update(r => ({ ...r, payments: [{ id: 'pm' + Date.now(), by: 'Rachel Burns', ...d }, ...r.payments] })); fire('Payment recorded', 'check-circle'); };
  const addCharge = (d) => { update(r => ({ ...r, charges: [{ id: 'ch' + Date.now(), ...d }, ...r.charges] })); fire('Charge added', 'check-circle'); };
  const addFlag = (d) => { update(r => ({ ...r, flags: [{ id: 'f' + Date.now(), ...d }, ...r.flags] })); fire('Flag added — visible to instructors', 'shield'); };
  const addNote = (d) => { update(r => ({ ...r, notes: [{ id: 'n' + Date.now(), by: 'Rachel Burns', date: 'Today', ...d }, ...r.notes] })); fire('Note saved', 'check-circle'); };
  const addIncident = (d) => { update(r => ({ ...r, incidents: [{ id: 'in' + Date.now(), date: 'Today', ...d }, ...r.incidents] })); fire('Incident logged', 'alert'); };

  return (
    <div className="ks-screen">
      {/* header */}
      <button onClick={onBack} style={{ display: 'inline-flex', alignItems: 'center', gap: 6, border: 'none', background: 'transparent', color: 'var(--ink-3)', fontWeight: 700, fontSize: 13.5, cursor: 'pointer', marginBottom: 14, padding: 0 }}><Icon name="left" size={16} sw={2.4} />All students</button>
      <div style={{ display: 'flex', alignItems: 'center', gap: 16, marginBottom: 18 }}>
        <Avatar initials={stu.initials} tone={277} size={56} />
        <div style={{ flex: 1 }}>
          <div style={{ fontWeight: 800, fontSize: 24, letterSpacing: '-0.03em' }}>{stu.name}</div>
          <div style={{ fontSize: 13.5, color: 'var(--ink-3)' }}>Cat {stu.cat} · {stu.trans} · {rec.stage}</div>
        </div>
        <a href={`tel:${rec.phone.replace(/\s/g, '')}`} style={{ textDecoration: 'none' }}><Btn variant="secondary" icon="phone">{rec.phone}</Btn></a>
        <a href={`sms:${rec.phone.replace(/\s/g, '')}`} style={{ textDecoration: 'none' }}><Btn variant="secondary" icon="mail">Text</Btn></a>
      </div>

      {/* flags banner */}
      {rec.flags.length > 0 && (
        <Card pad={0} style={{ overflow: 'hidden', marginBottom: 16, borderColor: 'oklch(0.7 0.135 70)' }}>
          <div style={{ padding: '12px 16px', background: 'var(--warning-tint)' }}>
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontWeight: 800, fontSize: 13, color: 'oklch(0.5 0.13 70)', marginBottom: 8 }}><Icon name="shield" size={16} sw={2.2} />SAFETY & ACCOMMODATION FLAGS</div>
            <div style={{ display: 'flex', flexDirection: 'column', gap: 7 }}>
              {rec.flags.map(f => (
                <div key={f.id} style={{ display: 'flex', alignItems: 'center', gap: 9, fontSize: 14, fontWeight: 600, color: 'var(--ink)' }}>
                  <Icon name={f.kind === 'safety' ? 'alert' : 'info'} size={16} sw={2.1} style={{ color: 'oklch(0.55 0.13 70)', flexShrink: 0 }} />{f.text}
                </div>
              ))}
            </div>
          </div>
        </Card>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1.5fr 1fr', gap: 16, alignItems: 'start' }}>
        {/* LEFT column */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <ProgressPanel rec={rec} />
          <TestsPanel rec={rec} />
          <IncidentsPanel rec={rec} onAdd={() => setModal('incident')} />
        </div>
        {/* RIGHT column */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 16 }}>
          <FinancialPanel charged={charged} paid={paid} bal={bal} rec={rec} onPay={() => setModal('pay')} onCharge={() => setModal('charge')} />
          <NotesPanel rec={rec} onAddNote={() => setModal('note')} onAddFlag={() => setModal('flag')} />
        </div>
      </div>

      <Modal open={modal === 'pay'} onClose={() => setModal(null)} title="Record a payment" icon="card" tone="success" width={440}>
        {modal === 'pay' && <PaymentForm bal={bal} onSave={d => { addPayment(d); setModal(null); }} onCancel={() => setModal(null)} />}
      </Modal>
      <Modal open={modal === 'charge'} onClose={() => setModal(null)} title="Add a charge" icon="plus" width={440}>
        {modal === 'charge' && <ChargeForm onSave={d => { addCharge(d); setModal(null); }} onCancel={() => setModal(null)} />}
      </Modal>
      <Modal open={modal === 'flag'} onClose={() => setModal(null)} title="Add safety / accommodation flag" icon="shield" tone="warning" width={460}>
        {modal === 'flag' && <FlagForm onSave={d => { addFlag(d); setModal(null); }} onCancel={() => setModal(null)} />}
      </Modal>
      <Modal open={modal === 'note'} onClose={() => setModal(null)} title="Add progress note" icon="edit" width={460}>
        {modal === 'note' && <NoteForm onSave={d => { addNote(d); setModal(null); }} onCancel={() => setModal(null)} />}
      </Modal>
      <Modal open={modal === 'incident'} onClose={() => setModal(null)} title="Log an incident" icon="alert" tone="danger" width={480}>
        {modal === 'incident' && <IncidentForm onSave={d => { addIncident(d); setModal(null); }} onCancel={() => setModal(null)} />}
      </Modal>
    </div>
  );
}

/* panels */
function Panel({ title, icon, action, children, pad = 16 }) {
  return (
    <Card pad={0} style={{ overflow: 'hidden' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '13px 16px', borderBottom: '1px solid var(--border)' }}>
        <Icon name={icon} size={18} sw={2.1} style={{ color: 'var(--ink-3)' }} />
        <span style={{ fontWeight: 800, fontSize: 14.5, flex: 1 }}>{title}</span>
        {action}
      </div>
      <div style={{ padding: pad }}>{children}</div>
    </Card>
  );
}
const miniBtn = (label, icon, onClick) => <Btn size="sm" variant="soft" icon={icon} onClick={onClick}>{label}</Btn>;

function ProgressPanel({ rec }) {
  const courses = Object.keys(rec.progress);
  return (
    <Panel title="Training progress" icon="award">
      <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
        {courses.map(ct => {
          const p = rec.progress[ct], c = CT[ct];
          return (
            <div key={ct} style={{ display: 'flex', alignItems: 'center', gap: 13 }}>
              <ProgressRing value={p.done} total={p.total} size={48} sw={5} color={c.color}><span style={{ fontSize: 11 }}>{p.done}/{p.total}</span></ProgressRing>
              <div style={{ flex: 1 }}>
                <div style={{ fontWeight: 700, fontSize: 14 }}>{c.name}</div>
                <div style={{ fontSize: 12.5, color: 'var(--ink-3)' }}>{p.complete ? 'All competencies signed off' : `${p.done} of ${p.total} signed off`}</div>
              </div>
              {p.complete && <Badge tone="success" icon="check">Complete</Badge>}
            </div>
          );
        })}
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, paddingTop: 12, borderTop: '1px solid var(--border)', fontSize: 13, color: 'var(--ink-2)', fontWeight: 600 }}>
          <Icon name="clipboard-check" size={15} sw={2.1} style={{ color: 'var(--ink-4)' }} />{rec.lessons} lessons completed · CBT {rec.cbtStatus.replace('-', ' ')}
        </div>
      </div>
    </Panel>
  );
}

function TestsPanel({ rec }) {
  const oTone = { pass: 'success', fail: 'danger', booked: 'primary', notyet: 'neutral' };
  return (
    <Panel title={`${SCHOOL.body} test history`} icon="target">
      {rec.tests.length === 0 ? <div style={{ fontSize: 13.5, color: 'var(--ink-4)', fontWeight: 600 }}>No {SCHOOL.body} tests yet — CBT is {rec.cbtStatus.replace('-', ' ')}.</div> : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
          {rec.tests.map((t, i) => (
            <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 11 }}>
              <div style={{ fontWeight: 800, fontSize: 13, width: 70, color: 'var(--ink-2)' }}>{TEST_LABEL[t.type] || t.type}</div>
              <div style={{ fontSize: 12.5, color: 'var(--ink-4)', fontWeight: 600, width: 70 }}>Attempt {t.attempt}</div>
              <div style={{ flex: 1, fontSize: 12.5, color: 'var(--ink-3)' }}>{t.date} · <span className="mono" style={{ fontSize: 11 }}>{t.ref}</span></div>
              <Badge tone={oTone[t.outcome]} size="sm" icon={t.outcome === 'pass' ? 'check' : t.outcome === 'fail' ? 'x' : t.outcome === 'booked' ? 'calendar' : undefined}>{t.outcome === 'notyet' ? 'Not yet' : t.outcome[0].toUpperCase() + t.outcome.slice(1)}</Badge>
            </div>
          ))}
        </div>
      )}
    </Panel>
  );
}

function IncidentsPanel({ rec, onAdd }) {
  return (
    <Panel title="Incidents" icon="alert" action={miniBtn('Log incident', 'plus', onAdd)}>
      {rec.incidents.length === 0 ? <div style={{ fontSize: 13.5, color: 'var(--ink-4)', fontWeight: 600 }}>No incidents on record.</div> : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          {rec.incidents.map(inc => (
            <div key={inc.id} style={{ display: 'flex', gap: 11 }}>
              <div style={{ width: 34, height: 34, borderRadius: 9, flexShrink: 0, display: 'grid', placeItems: 'center', background: 'var(--danger-tint)', color: 'var(--danger)' }}><Icon name="alert" size={17} /></div>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 12.5, color: 'var(--ink-4)', fontWeight: 600 }}>{inc.date} · {BIKE[inc.bike] ? `${BIKE[inc.bike].name} (${BIKE[inc.bike].reg})` : 'Bike'}</div>
                <div style={{ fontSize: 13.5, color: 'var(--ink-2)', lineHeight: 1.45, marginTop: 2 }}>{inc.desc}</div>
              </div>
            </div>
          ))}
        </div>
      )}
    </Panel>
  );
}

function FinancialPanel({ charged, paid, bal, rec, onPay, onCharge }) {
  return (
    <Panel title="Financial summary" icon="card" pad={0}>
      <div style={{ padding: 16, textAlign: 'center', borderBottom: '1px solid var(--border)' }}>
        <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--ink-4)', textTransform: 'uppercase', letterSpacing: '0.04em' }}>Balance</div>
        <div style={{ fontWeight: 800, fontSize: 34, letterSpacing: '-0.03em', color: bal > 0 ? 'var(--danger)' : 'var(--success)', margin: '2px 0' }}>{bal > 0 ? `£${bal}` : '£0'}</div>
        <div style={{ fontSize: 13, color: 'var(--ink-3)', fontWeight: 600 }}>{bal > 0 ? 'outstanding' : 'fully settled'}</div>
        <div style={{ display: 'flex', justifyContent: 'center', gap: 18, marginTop: 12, fontSize: 12.5, color: 'var(--ink-3)' }}>
          <span>Charged <b style={{ color: 'var(--ink)' }}>£{charged}</b></span>
          <span>Paid <b style={{ color: 'var(--ink)' }}>£{paid}</b></span>
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 14 }}>
          <Btn full size="sm" variant="success" icon="plus" onClick={onPay}>Record payment</Btn>
          <Btn full size="sm" variant="secondary" icon="card" onClick={onCharge}>Add charge</Btn>
        </div>
      </div>
      <div style={{ padding: '8px 16px 14px' }}>
        <div style={{ fontSize: 11.5, fontWeight: 700, color: 'var(--ink-4)', textTransform: 'uppercase', letterSpacing: '0.04em', margin: '6px 0 4px' }}>History</div>
        {[...rec.charges.map(c => ({ ...c, kind: 'charge' })), ...rec.payments.map(p => ({ ...p, kind: 'payment' }))].slice(0, 8).map((row, i) => (
          <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 0', borderBottom: '1px solid var(--border)' }}>
            <div style={{ width: 26, height: 26, borderRadius: 8, flexShrink: 0, display: 'grid', placeItems: 'center', background: row.kind === 'payment' ? 'var(--success-tint)' : 'var(--surface-3)', color: row.kind === 'payment' ? 'var(--success)' : 'var(--ink-3)' }}>
              <Icon name={row.kind === 'payment' ? 'arrow-right' : 'card'} size={14} sw={2.2} />
            </div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <div style={{ fontSize: 13, fontWeight: 700 }}>{row.kind === 'payment' ? methodLabel(row.method) : row.label}</div>
              <div style={{ fontSize: 11.5, color: 'var(--ink-4)' }}>{row.date}{row.by ? ` · ${row.by}` : ''}</div>
            </div>
            <div style={{ fontWeight: 800, fontSize: 13.5, color: row.kind === 'payment' ? 'var(--success)' : 'var(--ink)' }}>{row.kind === 'payment' ? '+' : ''}£{row.amount}</div>
          </div>
        ))}
      </div>
    </Panel>
  );
}

function NotesPanel({ rec, onAddNote, onAddFlag }) {
  return (
    <Panel title="Staff notes" icon="clipboard"
      action={<div style={{ display: 'flex', gap: 6 }}>{miniBtn('Flag', 'shield', onAddFlag)}{miniBtn('Note', 'plus', onAddNote)}</div>}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '7px 10px', borderRadius: 8, background: 'var(--surface-2)', marginBottom: 12, fontSize: 11.5, color: 'var(--ink-3)', fontWeight: 600 }}>
        <Icon name="shield" size={13} sw={2.2} /> Staff-only — never shown to the student.
      </div>
      {rec.notes.length === 0 ? <div style={{ fontSize: 13.5, color: 'var(--ink-4)', fontWeight: 600 }}>No notes yet.</div> : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          {rec.notes.map(n => (
            <div key={n.id} style={{ display: 'flex', gap: 10 }}>
              <Avatar initials={n.by.split(' ').map(w => w[0]).join('')} tone={200} size={28} />
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 12, color: 'var(--ink-4)', fontWeight: 700 }}>{n.by} · {n.date}</div>
                <div style={{ fontSize: 13.5, color: 'var(--ink-2)', lineHeight: 1.45, marginTop: 2 }}>{n.text}</div>
              </div>
            </div>
          ))}
        </div>
      )}
    </Panel>
  );
}

/* forms */
function PaymentForm({ bal, onSave, onCancel }) {
  const [amount, setAmount] = useStateST(bal > 0 ? String(bal) : '');
  const [method, setMethod] = useStateST('cash');
  const [date, setDate] = useStateST('Today');
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      <KField label="Amount received"><KInput prefix="£" type="text" value={amount} onChange={v => setAmount(v.replace(/[^0-9.]/g, ''))} placeholder="0" /></KField>
      <KField label="Method"><KSelect value={method} onChange={setMethod} options={PAY_METHODS} /></KField>
      <KField label="Date"><KInput value={date} onChange={setDate} placeholder="Today" /></KField>
      <div style={{ display: 'flex', gap: 10, marginTop: 4 }}>
        <Btn full variant="secondary" onClick={onCancel}>Cancel</Btn>
        <Btn full variant="success" icon="check" disabled={!amount} onClick={() => onSave({ amount: Number(amount) || 0, method, date })}>Record payment</Btn>
      </div>
    </div>
  );
}
function ChargeForm({ onSave, onCancel }) {
  const [label, setLabel] = useStateST('');
  const [amount, setAmount] = useStateST('');
  const [date, setDate] = useStateST('Today');
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      <KField label="What's the charge for?"><KInput value={label} onChange={setLabel} placeholder="e.g. Practical training" /></KField>
      <KField label="Amount"><KInput prefix="£" value={amount} onChange={v => setAmount(v.replace(/[^0-9.]/g, ''))} placeholder="0" /></KField>
      <KField label="Date"><KInput value={date} onChange={setDate} placeholder="Today" /></KField>
      <div style={{ display: 'flex', gap: 10, marginTop: 4 }}>
        <Btn full variant="secondary" onClick={onCancel}>Cancel</Btn>
        <Btn full variant="primary" icon="check" disabled={!label.trim() || !amount} onClick={() => onSave({ label: label.trim(), amount: Number(amount) || 0, date })}>Add charge</Btn>
      </div>
    </div>
  );
}
function FlagForm({ onSave, onCancel }) {
  const [kind, setKind] = useStateST('safety');
  const [text, setText] = useStateST('');
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      <KField label="Type"><Seg full value={kind} onChange={setKind} items={[{ value: 'safety', label: 'Safety' }, { value: 'access', label: 'Accommodation' }]} /></KField>
      <KField label="Flag" hint="Factual & professional — flags are staff-visible and could appear in a Subject Access Request.">
        <KArea value={text} onChange={setText} placeholder="e.g. Requires low-seat bike; build up roundabouts slowly." rows={3} />
      </KField>
      <div style={{ display: 'flex', gap: 10, marginTop: 4 }}>
        <Btn full variant="secondary" onClick={onCancel}>Cancel</Btn>
        <Btn full variant="primary" icon="check" disabled={!text.trim()} onClick={() => onSave({ kind, text: text.trim() })}>Add flag</Btn>
      </div>
    </div>
  );
}
function NoteForm({ onSave, onCancel }) {
  const [text, setText] = useStateST('');
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      <KField label="Progress note" hint="Factual & professional — staff-only, but disclosable on request.">
        <KArea value={text} onChange={setText} placeholder="How are they getting on? What to work on next…" rows={4} />
      </KField>
      <div style={{ display: 'flex', gap: 10, marginTop: 4 }}>
        <Btn full variant="secondary" onClick={onCancel}>Cancel</Btn>
        <Btn full variant="primary" icon="check" disabled={!text.trim()} onClick={() => onSave({ text: text.trim() })}>Save note</Btn>
      </div>
    </div>
  );
}
function IncidentForm({ onSave, onCancel }) {
  const [bike, setBike] = useStateST('b1');
  const [desc, setDesc] = useStateST('');
  const [offline, setOffline] = useStateST(false);
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      <KField label="Bike involved"><KSelect value={bike} onChange={setBike} options={BIKES.map(b => ({ value: b.id, label: `${b.name} · ${b.reg}` }))} /></KField>
      <KField label="What happened?" hint="Factual account — incidents are part of the student record.">
        <KArea value={desc} onChange={setDesc} placeholder="e.g. Low-speed drop during U-turn. Cosmetic scuff, bike serviceable." rows={3} />
      </KField>
      <label style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '11px 13px', borderRadius: 'var(--r-sm)', border: '1px solid var(--border-2)', cursor: 'pointer' }}>
        <input type="checkbox" checked={offline} onChange={e => setOffline(e.target.checked)} style={{ width: 17, height: 17, accentColor: 'var(--primary)' }} />
        <span style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--ink-2)' }}>Also take this bike offline (damaged)</span>
      </label>
      <div style={{ display: 'flex', gap: 10, marginTop: 4 }}>
        <Btn full variant="secondary" onClick={onCancel}>Cancel</Btn>
        <Btn full variant="danger" icon="check" disabled={!desc.trim()} onClick={() => onSave({ bike, desc: desc.trim() + (offline ? ' (bike taken offline)' : '') })}>Log incident</Btn>
      </div>
    </div>
  );
}

Object.assign(window, { StudentsScreen });
