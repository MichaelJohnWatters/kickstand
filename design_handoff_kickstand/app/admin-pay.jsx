// Kickstand — Manager: instructor pay (owed-tracking, NOT payroll).
// Per-instructor earned / paid / outstanding, record earning + payment, pay-model config.
const { useState: useStatePay } = React;

const payUnit = (basis) => basis === 'percentage' ? '%' : '£';
function payModelSummary(p) {
  const m = {
    percentage: `${p.rate}% of session revenue`,
    'per-day': `£${p.rate} per day`,
    'per-session': `£${p.rate} per session`,
    'per-hour': `£${p.rate} per hour`,
    'per-student': `£${p.rate} per student`,
    salary: 'Salaried · not tracked here',
  }[p.basis] || '—';
  return p.perCourse && p.perCourse.mod2 ? `${m} · Mod 2 ${payUnit(p.basis)}${p.perCourse.mod2}` : m;
}

function InstructorPayScreen({ fire }) {
  const [pay, setPay] = useStatePay(INSTRUCTOR_PAY);
  const [modal, setModal] = useStatePay(null); // {type, id}
  const tracked = INSTRUCTORS.filter(i => pay[i.id].basis !== 'salary');
  const totalOwed = tracked.reduce((a, i) => {
    const p = pay[i.id];
    return a + (p.earnings.reduce((s, e) => s + e.amount, 0) - p.payments.reduce((s, x) => s + x.amount, 0));
  }, 0);
  const owedFor = (id) => { const p = pay[id]; return p.earnings.reduce((s, e) => s + e.amount, 0) - p.payments.reduce((s, x) => s + x.amount, 0); };

  const addEarning = (id, d) => { setPay(p => ({ ...p, [id]: { ...p[id], earnings: [{ id: 'ie' + Date.now(), ...d }, ...p[id].earnings] } })); fire('Earning recorded', 'check-circle'); };
  const addPayment = (id, d) => { setPay(p => ({ ...p, [id]: { ...p[id], payments: [{ id: 'ip' + Date.now(), ...d }, ...p[id].payments] } })); fire('Instructor payment recorded', 'check-circle'); };
  const setModel = (id, d) => { setPay(p => ({ ...p, [id]: { ...p[id], ...d } })); fire('Pay model updated', 'check-circle'); };

  return (
    <div className="ks-screen">
      <PageHead title="Instructor pay" sub="What the school owes its instructors. Owed-tracking — feeds your payroll, doesn't replace it." />
      <Card pad={16} style={{ marginBottom: 18, display: 'flex', alignItems: 'center', gap: 18, background: 'linear-gradient(120deg, var(--primary-deep), var(--primary))', color: '#fff', border: 'none' }}>
        <div style={{ width: 50, height: 50, borderRadius: 14, display: 'grid', placeItems: 'center', background: 'rgba(255,255,255,.18)' }}><Icon name="card" size={26} /></div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 13, opacity: .85, fontWeight: 600 }}>Total outstanding to instructors</div>
          <div style={{ fontWeight: 800, fontSize: 32, letterSpacing: '-0.03em', lineHeight: 1.1 }}>£{totalOwed.toFixed(2).replace(/\.00$/, '')}</div>
        </div>
        <div style={{ fontSize: 12.5, opacity: .9, textAlign: 'right', maxWidth: 180, lineHeight: 1.4 }}>Across {tracked.length} tracked instructors · end-of-week payout view</div>
      </Card>

      <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
        {INSTRUCTORS.map(i => {
          const p = pay[i.id], salary = p.basis === 'salary';
          const earned = p.earnings.reduce((s, e) => s + e.amount, 0);
          const paid = p.payments.reduce((s, x) => s + x.amount, 0);
          const owed = earned - paid;
          return (
            <Card key={i.id} pad={0} style={{ overflow: 'hidden' }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 13, padding: 16, borderBottom: salary ? 'none' : '1px solid var(--border)' }}>
                <Avatar initials={i.initials} tone={i.tone} size={44} />
                <div style={{ flex: 1 }}>
                  <div style={{ fontWeight: 800, fontSize: 16 }}>{i.name}</div>
                  <div style={{ fontSize: 12.5, color: 'var(--ink-3)', display: 'flex', alignItems: 'center', gap: 5 }}><Icon name="gauge" size={13} sw={2.1} />{payModelSummary(p)}</div>
                </div>
                {!salary && (
                  <div style={{ display: 'flex', gap: 24, alignItems: 'center', marginRight: 8 }}>
                    <Stat label="Earned" value={`£${earned.toFixed(2).replace(/\.00$/, '')}`} />
                    <Stat label="Paid" value={`£${paid.toFixed(2).replace(/\.00$/, '')}`} />
                    <Stat label="Outstanding" value={`£${owed.toFixed(2).replace(/\.00$/, '')}`} tone={owed > 0 ? 'var(--danger)' : 'var(--success)'} />
                  </div>
                )}
                <button onClick={() => setModal({ type: 'model', id: i.id })} style={{ ...payIconBtn }} title="Edit pay model"><Icon name="sliders" size={18} /></button>
              </div>
              {salary ? (
                <div style={{ padding: '12px 16px', fontSize: 13, color: 'var(--ink-4)', fontWeight: 600, display: 'flex', alignItems: 'center', gap: 7 }}><Icon name="info" size={15} sw={2.1} />Employed / salaried — not tracked in this ledger.</div>
              ) : (
                <div style={{ display: 'flex', gap: 8, padding: 12 }}>
                  <Btn size="sm" variant="soft" icon="plus" onClick={() => setModal({ type: 'earning', id: i.id })}>Record earning</Btn>
                  <Btn size="sm" variant="success" icon="arrow-right" onClick={() => setModal({ type: 'payment', id: i.id })}>Record payment</Btn>
                  <div style={{ flex: 1 }} />
                  <span style={{ alignSelf: 'center', fontSize: 12, color: 'var(--ink-4)' }}>{p.earnings.length} earnings · {p.payments.length} payments</span>
                </div>
              )}
            </Card>
          );
        })}
      </div>

      <Modal open={modal?.type === 'earning'} onClose={() => setModal(null)} title="Record an earning" icon="plus" width={460}>
        {modal?.type === 'earning' && <EarningForm pay={pay[modal.id]} onSave={d => { addEarning(modal.id, d); setModal(null); }} onCancel={() => setModal(null)} />}
      </Modal>
      <Modal open={modal?.type === 'payment'} onClose={() => setModal(null)} title="Record instructor payment" icon="card" tone="success" width={440}>
        {modal?.type === 'payment' && <InstrPayForm onSave={d => { addPayment(modal.id, d); setModal(null); }} onCancel={() => setModal(null)} />}
      </Modal>
      <Modal open={modal?.type === 'model'} onClose={() => setModal(null)} title="Pay model" icon="sliders" width={460}>
        {modal?.type === 'model' && <PayModelForm pay={pay[modal.id]} name={INST[modal.id].name} onSave={d => { setModel(modal.id, d); setModal(null); }} onCancel={() => setModal(null)} />}
      </Modal>
    </div>
  );
}
function Stat({ label, value, tone }) {
  return (
    <div style={{ textAlign: 'right' }}>
      <div style={{ fontSize: 10.5, fontWeight: 700, color: 'var(--ink-4)', textTransform: 'uppercase', letterSpacing: '0.03em' }}>{label}</div>
      <div style={{ fontWeight: 800, fontSize: 16, color: tone || 'var(--ink)' }}>{value}</div>
    </div>
  );
}
const payIconBtn = { width: 36, height: 36, borderRadius: 10, border: '1px solid var(--border-2)', background: 'var(--surface)', display: 'grid', placeItems: 'center', color: 'var(--ink-2)', cursor: 'pointer', flexShrink: 0 };

function EarningForm({ pay, onSave, onCancel }) {
  const [session, setSession] = useStatePay('');
  const [amount, setAmount] = useStatePay('');
  const [from, setFrom] = useStatePay('');
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      {pay.basis === 'percentage' && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '9px 12px', borderRadius: 8, background: 'var(--primary-tint)', fontSize: 12.5, color: 'var(--primary-deep)', fontWeight: 600 }}>
          <Icon name="info" size={15} sw={2.1} />{pay.rate}% basis — link to the session's charges so "how was this calculated?" is answerable.
        </div>
      )}
      <KField label="Session"><KInput value={session} onChange={setSession} placeholder="e.g. CBT day · 9 Jun" /></KField>
      <KField label="Amount earned"><KInput prefix="£" value={amount} onChange={v => setAmount(v.replace(/[^0-9.]/g, ''))} placeholder="0" /></KField>
      <KField label="Derived from" hint="What this is based on — e.g. '40% of 4 × CBT £139'."><KInput value={from} onChange={setFrom} placeholder="Calculation basis" /></KField>
      <div style={{ display: 'flex', gap: 10, marginTop: 4 }}>
        <Btn full variant="secondary" onClick={onCancel}>Cancel</Btn>
        <Btn full variant="primary" icon="check" disabled={!session.trim() || !amount} onClick={() => onSave({ session: session.trim(), amount: Number(amount) || 0, from: from.trim() || 'Manual entry', date: 'Today' })}>Record earning</Btn>
      </div>
    </div>
  );
}
function InstrPayForm({ onSave, onCancel }) {
  const [amount, setAmount] = useStatePay('');
  const [method, setMethod] = useStatePay('bank-transfer');
  const [date, setDate] = useStatePay('Today');
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      <KField label="Amount paid out"><KInput prefix="£" value={amount} onChange={v => setAmount(v.replace(/[^0-9.]/g, ''))} placeholder="0" /></KField>
      <KField label="Method"><KSelect value={method} onChange={setMethod} options={PAY_METHODS} /></KField>
      <KField label="Date"><KInput value={date} onChange={setDate} placeholder="Today" /></KField>
      <div style={{ display: 'flex', gap: 10, marginTop: 4 }}>
        <Btn full variant="secondary" onClick={onCancel}>Cancel</Btn>
        <Btn full variant="success" icon="check" disabled={!amount} onClick={() => onSave({ amount: Number(amount) || 0, method, date })}>Record payment</Btn>
      </div>
    </div>
  );
}
function PayModelForm({ pay, name, onSave, onCancel }) {
  const [basis, setBasis] = useStatePay(pay.basis);
  const [rate, setRate] = useStatePay(String(pay.rate || ''));
  const [override, setOverride] = useStatePay(!!(pay.perCourse && pay.perCourse.mod2));
  const [mod2, setMod2] = useStatePay(String(pay.perCourse?.mod2 || ''));
  const salary = basis === 'salary';
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      <div style={{ fontSize: 13, color: 'var(--ink-3)', marginTop: -4 }}>How <b style={{ color: 'var(--ink)' }}>{name}</b> is paid for sessions.</div>
      <KField label="Pay basis"><KSelect value={basis} onChange={setBasis} options={PAY_BASES} /></KField>
      {!salary && (
        <KField label={basis === 'percentage' ? 'Percentage of session revenue' : 'Rate'}>
          <KInput prefix={payUnit(basis)} value={rate} onChange={v => setRate(v.replace(/[^0-9.]/g, ''))} placeholder="0" />
        </KField>
      )}
      {!salary && (
        <label style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '11px 13px', borderRadius: 'var(--r-sm)', border: '1px solid var(--border-2)', cursor: 'pointer' }}>
          <input type="checkbox" checked={override} onChange={e => setOverride(e.target.checked)} style={{ width: 17, height: 17, accentColor: 'var(--primary)' }} />
          <span style={{ fontSize: 13.5, fontWeight: 600, color: 'var(--ink-2)' }}>Different rate for Mod 2 escort days</span>
        </label>
      )}
      {!salary && override && (
        <KField label="Mod 2 rate"><KInput prefix={payUnit(basis)} value={mod2} onChange={v => setMod2(v.replace(/[^0-9.]/g, ''))} placeholder="0" /></KField>
      )}
      <div style={{ display: 'flex', gap: 10, marginTop: 4 }}>
        <Btn full variant="secondary" onClick={onCancel}>Cancel</Btn>
        <Btn full variant="primary" icon="check" onClick={() => onSave({ basis, rate: Number(rate) || 0, perCourse: (!salary && override && mod2) ? { mod2: Number(mod2) } : undefined })}>Save pay model</Btn>
      </div>
    </div>
  );
}

Object.assign(window, { InstructorPayScreen });
