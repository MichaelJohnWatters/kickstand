// Kickstand — Admin: student onboarding mode + pending sign-ups queue.
const { useState: useStateSU } = React;

function SignupsScreen({ fire }) {
  const [mode, setMode] = useStateSU(SCHOOL.onboardingMode);
  const [queue, setQueue] = useStateSU(PENDING);

  const decide = (id, ok) => {
    setQueue(q => q.filter(p => p.id !== id));
    fire(ok ? 'Approved — student can now book' : 'Sign-up rejected', ok ? 'check-circle' : 'x-circle');
  };

  return (
    <div className="ks-screen">
      <PageHead title="Sign-ups" sub="How new students join, and who's waiting to be approved." />

      {/* onboarding mode setting */}
      <Card pad={16} style={{ marginBottom: 18 }}>
        <div style={{ display: 'flex', alignItems: 'flex-start', gap: 14, flexWrap: 'wrap' }}>
          <div style={{ flex: 1, minWidth: 240 }}>
            <div style={{ fontWeight: 800, fontSize: 15.5 }}>New student onboarding</div>
            <div style={{ fontSize: 13, color: 'var(--ink-3)', marginTop: 3, lineHeight: 1.45 }}>
              {mode === 'open'
                ? 'Open booking — students sign up and can book straight away. Best for high volume.'
                : 'Approval required — sign-ups land here for you to review (and phone) before they can book. Pending students can browse but not book.'}
            </div>
          </div>
          <Seg value={mode} onChange={setMode} items={[{ value: 'open', label: 'Open booking' }, { value: 'approval', label: 'Approval required' }]} />
        </div>
      </Card>

      <SectionLabel>{mode === 'approval' ? `Awaiting approval · ${queue.length}` : 'Awaiting approval'}</SectionLabel>

      {mode === 'open' ? (
        <Card pad={0}><EmptyState icon="zap" title="Open booking is on" msg="New students book immediately — nothing to approve. Switch to ‘Approval required’ to vet sign-ups first." /></Card>
      ) : queue.length === 0 ? (
        <Card pad={0}><EmptyState icon="check-circle" title="All caught up" msg="No sign-ups waiting for review." /></Card>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
          {queue.map(p => (
            <Card key={p.id} pad={16}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 13 }}>
                <Avatar initials={p.initials} tone={(p.id.charCodeAt(2) * 40) % 360} size={46} />
                <div style={{ flex: 1, minWidth: 0 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <span style={{ fontWeight: 800, fontSize: 16 }}>{p.name}</span>
                    <Badge tone="warning" size="sm">Pending</Badge>
                  </div>
                  <div style={{ fontSize: 12.5, color: 'var(--ink-3)', marginTop: 1 }}>Pursuing cat {p.cat} · applied {p.applied}</div>
                </div>
                <a href={`tel:${p.phone.replace(/\s/g, '')}`} style={{ textDecoration: 'none' }}><Btn size="sm" variant="secondary" icon="phone">{p.phone}</Btn></a>
              </div>
              {p.note && (
                <div style={{ marginTop: 12, padding: '10px 12px', borderRadius: 10, background: 'var(--surface-2)', fontSize: 13, color: 'var(--ink-2)', display: 'flex', gap: 8, alignItems: 'flex-start' }}>
                  <Icon name="info" size={15} sw={2.1} style={{ color: 'var(--ink-4)', flexShrink: 0, marginTop: 1 }} />{p.note}
                </div>
              )}
              <div style={{ display: 'flex', gap: 8, marginTop: 13 }}>
                <Btn full size="sm" variant="success" icon="check" onClick={() => decide(p.id, true)}>Approve</Btn>
                <Btn full size="sm" variant="secondary" icon="x" onClick={() => decide(p.id, false)}>Reject</Btn>
              </div>
            </Card>
          ))}
        </div>
      )}
    </div>
  );
}

function EmptyState({ icon, title, msg }) {
  return (
    <div style={{ padding: '40px 24px', textAlign: 'center' }}>
      <div style={{ width: 52, height: 52, borderRadius: 15, margin: '0 auto 14px', display: 'grid', placeItems: 'center', background: 'var(--surface-3)', color: 'var(--ink-4)' }}><Icon name={icon} size={26} /></div>
      <div style={{ fontWeight: 800, fontSize: 16 }}>{title}</div>
      <div style={{ fontSize: 13.5, color: 'var(--ink-3)', marginTop: 4, maxWidth: 320, marginInline: 'auto', lineHeight: 1.45 }}>{msg}</div>
    </div>
  );
}

Object.assign(window, { SignupsScreen, EmptyState });
