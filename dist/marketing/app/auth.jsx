// Kickstand — Auth & onboarding flow (role-aware login, signup, school select,
// student profile setup). Mobile-first, shown in the iOS frame.
const { useState: useStateAuth } = React;

const SCHOOLS = [
  { id: 'lagan', name: 'Lagan Valley Rider Training', loc: 'Belfast · Lisburn · Newry', init: 'LV', tone: 277 },
  { id: 'coast', name: 'North Coast Motorcycle School', loc: 'Coleraine · Ballymena', init: 'NC', tone: 195 },
  { id: 'capital', name: 'Capital Rider Academy', loc: 'Belfast', init: 'CR', tone: 70 },
];

function AuthApp({ theme, onFinish }) {
  const [step, setStep] = useStateAuth('welcome');
  const [school, setSchool] = useStateAuth('lagan');
  const [profile, setProfile] = useStateAuth({ cat: 'A2', trans: 'manual', cbt: 'yes', theory: 'yes' });

  let body, white = false;
  if (step === 'welcome') { body = <Welcome go={setStep} />; white = true; }
  else if (step === 'login') body = <Login onBack={() => setStep('welcome')} onIn={onFinish} onSignup={() => setStep('signup')} />;
  else if (step === 'signup') body = <Signup onBack={() => setStep('welcome')} onNext={() => setStep('school')} />;
  else if (step === 'school') body = <SchoolSelect value={school} onChange={setSchool} onBack={() => setStep('signup')} onNext={() => setStep('profile')} />;
  else if (step === 'profile') body = <ProfileSetup value={profile} onChange={setProfile} onBack={() => setStep('school')} onNext={() => setStep('done')} />;
  else if (step === 'done') body = <AuthDone school={school} onFinish={onFinish} />;
  return (
    <IOSDevice dark={theme === 'dark'}>
      <div style={{ height: '100%', display: 'flex', flexDirection: 'column', background: white ? 'var(--primary-deep)' : 'var(--bg)' }}>
        <div style={{ flex: 1, overflowY: 'auto', paddingTop: white ? 0 : 54 }}>{body}</div>
      </div>
    </IOSDevice>
  );
}

/* progress dots */
function Steps({ n, of }) {
  return (
    <div style={{ display: 'flex', gap: 6, marginBottom: 18 }}>
      {Array.from({ length: of }, (_, i) => (
        <div key={i} style={{ height: 5, flex: 1, borderRadius: 99, background: i < n ? 'var(--primary)' : 'var(--surface-3)', transition: 'background .3s' }} />
      ))}
    </div>
  );
}

/* shared inputs */
function TextField({ label, value, onChange, placeholder, type = 'text', icon, trailing, optional, hint }) {
  return (
    <label style={{ display: 'block', marginBottom: 14 }}>
      <span style={{ display: 'flex', alignItems: 'baseline', justifyContent: 'space-between', gap: 8, marginBottom: 7 }}>
        <span style={{ fontSize: 13, fontWeight: 700, color: 'var(--ink-2)' }}>{label}</span>
        {optional && <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--ink-4)' }}>Optional</span>}
      </span>
      <div style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '0 14px', height: 50, borderRadius: 'var(--r)', border: '1px solid var(--border-2)', background: 'var(--surface)' }}>
        {icon && <Icon name={icon} size={18} sw={2} style={{ color: 'var(--ink-4)' }} />}
        <input type={type} value={value} onChange={e => onChange(e.target.value)} placeholder={placeholder}
          style={{ flex: 1, border: 'none', outline: 'none', background: 'transparent', fontFamily: 'var(--font)', fontSize: 15.5, color: 'var(--ink)', fontWeight: 500, minWidth: 0 }} />
        {trailing}
      </div>
      {hint && <span style={{ display: 'block', fontSize: 12, color: 'var(--ink-4)', marginTop: 6, lineHeight: 1.4 }}>{hint}</span>}
    </label>
  );
}
function FieldLabel({ children }) { return <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--ink-2)', marginBottom: 8 }}>{children}</div>; }

/* ---------- Welcome ---------- */
function Welcome({ go }) {
  return (
    <div className="ks-screen" style={{ minHeight: '100%', display: 'flex', flexDirection: 'column', padding: '0 26px 30px', color: '#fff', position: 'relative', overflow: 'hidden' }}>
      <div style={{ position: 'absolute', top: -60, right: -50, width: 220, height: 220, borderRadius: '50%', background: 'rgba(255,255,255,.08)' }} />
      <div style={{ position: 'absolute', bottom: 120, left: -70, width: 180, height: 180, borderRadius: '50%', background: 'rgba(255,255,255,.06)' }} />
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', justifyContent: 'center', position: 'relative' }}>
        <div style={{ width: 64, height: 64, borderRadius: 18, background: 'rgba(255,255,255,.16)', display: 'grid', placeItems: 'center', backdropFilter: 'blur(6px)', marginBottom: 26 }}>
          <Icon name="moto" size={38} sw={1.8} />
        </div>
        <div style={{ fontWeight: 800, fontSize: 36, letterSpacing: '-0.04em', lineHeight: 1.05 }}>Learn to ride,<br />the right way.</div>
        <div style={{ fontSize: 16, opacity: .85, marginTop: 14, lineHeight: 1.5, maxWidth: 300 }}>
          Book your CBT & practical training, track your progress, and get licence-ready with your local school.
        </div>
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 11, position: 'relative' }}>
        <Btn full size="lg" variant="secondary" iconRight="arrow-right" onClick={() => go('signup')}>Create account</Btn>
        <button onClick={() => go('login')} style={{ border: 'none', background: 'transparent', color: '#fff', fontWeight: 700, fontSize: 15, cursor: 'pointer', padding: 12, fontFamily: 'var(--font)' }}>I already have an account</button>
      </div>
    </div>
  );
}

/* ---------- Login (role-aware) ---------- */
function Login({ onBack, onIn, onSignup }) {
  const [email, setEmail] = useStateAuth('jordan.reid@gmail.com');
  const [pw, setPw] = useStateAuth('••••••••');
  const [show, setShow] = useStateAuth(false);
  return (
    <div className="ks-screen" style={{ padding: '6px 22px 24px' }}>
      <button onClick={onBack} style={authBack}><Icon name="left" size={19} /></button>
      <div style={{ fontWeight: 800, fontSize: 28, letterSpacing: '-0.03em', marginTop: 18 }}>Welcome back</div>
      <div style={{ fontSize: 14.5, color: 'var(--ink-3)', marginBottom: 26, marginTop: 4 }}>Log in — we'll take you to the right place for your role.</div>
      <TextField label="Email" value={email} onChange={setEmail} icon="mail" type="email" />
      <TextField label="Password" value={pw} onChange={setPw} icon="key" type={show ? 'text' : 'password'}
        trailing={<button onClick={() => setShow(s => !s)} style={{ border: 'none', background: 'transparent', color: 'var(--ink-4)', cursor: 'pointer', padding: 0, display: 'flex' }}><Icon name={show ? 'x-circle' : 'search'} size={17} /></button>} />
      <button style={{ border: 'none', background: 'transparent', color: 'var(--primary)', fontWeight: 700, fontSize: 13.5, cursor: 'pointer', padding: 0, marginBottom: 22, fontFamily: 'var(--font)' }}>Forgot password?</button>
      <Btn full size="lg" onClick={onIn}>Log in</Btn>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, margin: '20px 0', color: 'var(--ink-4)', fontSize: 12.5 }}>
        <div style={{ flex: 1, height: 1, background: 'var(--border)' }} /> or <div style={{ flex: 1, height: 1, background: 'var(--border)' }} />
      </div>
      <div style={{ textAlign: 'center', fontSize: 14, color: 'var(--ink-3)' }}>
        New here? <button onClick={onSignup} style={{ border: 'none', background: 'transparent', color: 'var(--primary)', fontWeight: 800, cursor: 'pointer', fontSize: 14, fontFamily: 'var(--font)' }}>Create account</button>
      </div>
    </div>
  );
}

/* ---------- Signup ---------- */
function Signup({ onBack, onNext }) {
  const [name, setName] = useStateAuth('');
  const [email, setEmail] = useStateAuth('');
  const [phone, setPhone] = useStateAuth('');
  const [pw, setPw] = useStateAuth('');
  return (
    <div className="ks-screen" style={{ padding: '6px 22px 24px' }}>
      <button onClick={onBack} style={authBack}><Icon name="left" size={19} /></button>
      <div style={{ marginTop: 18 }}><Steps n={1} of={3} /></div>
      <div style={{ fontWeight: 800, fontSize: 27, letterSpacing: '-0.03em' }}>Create your account</div>
      <div style={{ fontSize: 14.5, color: 'var(--ink-3)', marginBottom: 24, marginTop: 4 }}>Takes about a minute.</div>
      <TextField label="Full name" value={name} onChange={setName} placeholder="Jordan Reid" icon="user" />
      <TextField label="Email" value={email} onChange={setEmail} placeholder="you@email.com" icon="mail" type="email" />
      <TextField label="Mobile number" value={phone} onChange={setPhone} placeholder="07700 900 000" icon="phone" type="tel" hint="So the school can reach you about sessions. Staff-only — never shown to other students." />
      <TextField label="Create password" value={pw} onChange={setPw} placeholder="At least 8 characters" icon="key" type="password" />
      <Card pad={12} style={{ background: 'var(--surface-2)', border: 'none', display: 'flex', gap: 9, alignItems: 'flex-start', marginBottom: 22 }}>
        <span style={{ color: 'var(--ink-3)', display: 'flex', marginTop: 1 }}><Icon name="info" size={16} sw={2.1} /></span>
        <div style={{ fontSize: 12.5, color: 'var(--ink-3)', lineHeight: 1.45 }}>Instructors join via an invite from their school — ask your admin for a link.</div>
      </Card>
      <Btn full size="lg" iconRight="arrow-right" onClick={onNext}>Continue</Btn>
    </div>
  );
}

/* ---------- School select (tenant context) ---------- */
function SchoolSelect({ value, onChange, onBack, onNext }) {
  const [q, setQ] = useStateAuth('');
  const list = SCHOOLS.filter(s => s.name.toLowerCase().includes(q.toLowerCase()));
  return (
    <div className="ks-screen" style={{ padding: '6px 22px 24px' }}>
      <button onClick={onBack} style={authBack}><Icon name="left" size={19} /></button>
      <div style={{ marginTop: 18 }}><Steps n={2} of={3} /></div>
      <div style={{ fontWeight: 800, fontSize: 27, letterSpacing: '-0.03em' }}>Find your school</div>
      <div style={{ fontSize: 14.5, color: 'var(--ink-3)', marginBottom: 20, marginTop: 4 }}>Choose the training school you're booking with.</div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '0 14px', height: 48, borderRadius: 'var(--r)', border: '1px solid var(--border-2)', background: 'var(--surface)', marginBottom: 16 }}>
        <Icon name="search" size={18} style={{ color: 'var(--ink-4)' }} />
        <input value={q} onChange={e => setQ(e.target.value)} placeholder="Search by name or town" style={{ flex: 1, border: 'none', outline: 'none', background: 'transparent', fontFamily: 'var(--font)', fontSize: 15, color: 'var(--ink)', minWidth: 0 }} />
      </div>
      <div style={{ display: 'flex', flexDirection: 'column', gap: 10 }}>
        {list.map(s => {
          const on = value === s.id;
          return (
            <button key={s.id} onClick={() => onChange(s.id)} style={{
              display: 'flex', alignItems: 'center', gap: 12, padding: 13, borderRadius: 'var(--r)', cursor: 'pointer', textAlign: 'left',
              border: on ? '2px solid var(--primary)' : '1px solid var(--border)', background: 'var(--surface)', boxShadow: on ? 'var(--sh-2)' : 'var(--sh-1)',
            }}>
              <div style={{ width: 44, height: 44, borderRadius: 12, display: 'grid', placeItems: 'center', background: `oklch(0.92 0.05 ${s.tone})`, color: `oklch(0.42 0.13 ${s.tone})`, fontWeight: 800, fontSize: 15, flexShrink: 0 }}>{s.init}</div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div style={{ fontWeight: 800, fontSize: 15, lineHeight: 1.2 }}>{s.name}</div>
                <div style={{ fontSize: 12.5, color: 'var(--ink-3)', marginTop: 2 }}>{s.loc}</div>
              </div>
              <div style={{ width: 22, height: 22, borderRadius: 99, flexShrink: 0, display: 'grid', placeItems: 'center', border: on ? 'none' : '2px solid var(--border-2)', background: on ? 'var(--primary)' : 'transparent', color: '#fff' }}>{on && <Icon name="check" size={14} sw={3} />}</div>
            </button>
          );
        })}
      </div>
      <div style={{ position: 'sticky', bottom: 0, paddingTop: 18 }}>
        <Btn full size="lg" iconRight="arrow-right" onClick={onNext}>Continue</Btn>
      </div>
    </div>
  );
}

/* ---------- Profile setup ---------- */
function ProfileSetup({ value, onChange, onBack, onNext }) {
  const set = (k, v) => onChange({ ...value, [k]: v });
  return (
    <div className="ks-screen" style={{ padding: '6px 22px 24px' }}>
      <button onClick={onBack} style={authBack}><Icon name="left" size={19} /></button>
      <div style={{ marginTop: 18 }}><Steps n={3} of={3} /></div>
      <div style={{ fontWeight: 800, fontSize: 27, letterSpacing: '-0.03em' }}>Your licence details</div>
      <div style={{ fontSize: 14.5, color: 'var(--ink-3)', marginBottom: 22, marginTop: 4 }}>So we only show training you're eligible to book.</div>

      <TextField label="Provisional licence number" value={value.licence || ''} onChange={v => set('licence', v)} placeholder="REID9 012 24 J 99" icon="card" optional hint="No rush — you can add this later from your profile." />

      <div style={{ marginBottom: 18 }}>
        <FieldLabel>Licence category you're pursuing</FieldLabel>
        <Seg full value={value.cat} onChange={v => set('cat', v)} items={[{ value: 'A1', label: 'A1' }, { value: 'A2', label: 'A2' }, { value: 'A', label: 'A' }]} />
      </div>
      <div style={{ marginBottom: 18 }}>
        <FieldLabel>Transmission preference</FieldLabel>
        <Seg full value={value.trans} onChange={v => set('trans', v)} items={[{ value: 'manual', label: 'Manual' }, { value: 'auto', label: 'Automatic' }]} />
      </div>
      <div style={{ marginBottom: 18 }}>
        <FieldLabel>Do you have a valid CBT (DL196)?</FieldLabel>
        <Seg full value={value.cbt} onChange={v => set('cbt', v)} items={[{ value: 'yes', label: 'Yes' }, { value: 'no', label: 'Not yet' }]} />
      </div>
      <div style={{ marginBottom: 22 }}>
        <FieldLabel>Theory test passed?</FieldLabel>
        <Seg full value={value.theory} onChange={v => set('theory', v)} items={[{ value: 'yes', label: 'Yes' }, { value: 'no', label: 'Not yet' }]} />
      </div>

      <Btn full size="lg" icon="check" onClick={onNext}>Finish setup</Btn>
    </div>
  );
}

/* ---------- Done ---------- */
function AuthDone({ school, onFinish }) {
  const s = SCHOOLS.find(x => x.id === school);
  const approval = SCHOOL.onboardingMode === 'approval';
  return (
    <div className="ks-screen" style={{ minHeight: '100%', display: 'flex', flexDirection: 'column', padding: '24px 24px', background: 'var(--bg)' }}>
      <div style={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', textAlign: 'center' }}>
        <div style={{ width: 88, height: 88, borderRadius: '50%', background: approval ? 'oklch(0.55 0.13 70)' : 'var(--success)', display: 'grid', placeItems: 'center', color: '#fff', animation: 'ks-pop .5s cubic-bezier(.22,1.4,.4,1)', boxShadow: approval ? '0 12px 30px oklch(0.55 0.13 70 / .4)' : '0 12px 30px oklch(0.58 0.13 160 / .4)' }}>
          <Icon name={approval ? 'clock' : 'check'} size={46} sw={3} />
        </div>
        <div style={{ fontWeight: 800, fontSize: 26, letterSpacing: '-0.03em', marginTop: 22 }}>{approval ? 'Almost there!' : "You're all set!"}</div>
        <div style={{ fontSize: 15, color: 'var(--ink-3)', marginTop: 8, lineHeight: 1.5, maxWidth: 290 }}>
          {approval
            ? <>Your account with <b style={{ color: 'var(--ink)' }}>{s.name}</b> is awaiting approval. They'll review it shortly — you can browse in the meantime, and we'll text you once you're cleared to book.</>
            : <>Your account is linked to <b style={{ color: 'var(--ink)' }}>{s.name}</b>. Let's get you booked in for your first session.</>}
        </div>
      </div>
      <Btn full size="lg" iconRight="arrow-right" onClick={() => onFinish(approval ? 'pending' : 'active')}>{approval ? 'Browse while I wait' : 'Go to my dashboard'}</Btn>
    </div>
  );
}

const authBack = { width: 40, height: 40, borderRadius: 11, border: '1px solid var(--border)', background: 'var(--surface)', display: 'grid', placeItems: 'center', color: 'var(--ink-2)', cursor: 'pointer' };

Object.assign(window, { AuthApp });
