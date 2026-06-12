// Kickstand — extended domain data for the manager surface (10b), NI pathway (10c):
// student records, payment ledger, instructor pay, notifications, travel matrix.

// ---- Student records (manager-only data) ----
// balance = sum(charges) − sum(payments). Course ids match COURSE_TYPES (NI).
const SREC = {
  s1: {
    phone: '07700 900 112', stage: 'Practical training', course: 'practical', lessons: 3,
    cbtStatus: 'completed',
    progress: { cbt650: { done: 5, total: 5, complete: true }, practical: { done: 4, total: 7 } },
    tests: [{ type: 'practical', attempt: 1, outcome: 'booked', date: '24 Jun 2026', ref: 'DVA-77 410 226' }],
    charges: [
      { id: 'ch1', label: 'CBT (650)', amount: 159, date: '14 Mar 2025', booking: 'CBT · 14 Mar' },
      { id: 'ch2', label: 'Practical training', amount: 95, date: '02 Jun 2026', booking: 'Practical · 12 Jun' },
    ],
    payments: [{ id: 'pm1', amount: 159, method: 'card-in-person', date: '14 Mar 2025', by: 'Rachel Burns' }],
    incidents: [],
    flags: [],
    notes: [{ id: 'n1', by: 'Aoife McGrath', date: '05 Jun', text: 'Slow ride solid. U-turn needs work before the 24th — strong rider otherwise.' }],
  },
  s2: {
    phone: '07700 900 134', stage: 'CBT booked', course: 'cbt125', lessons: 0, cbtStatus: 'booked',
    progress: { cbt125: { done: 0, total: 5 } },
    tests: [],
    charges: [{ id: 'ch3', label: 'CBT (125)', amount: 139, date: '03 Jun 2026', booking: 'CBT · 9 Jun' }],
    payments: [],
    incidents: [],
    flags: [{ id: 'f1', kind: 'access', text: 'Requires low-seat bike (rider is 5\u20192\u201d).' }],
    notes: [],
  },
  s3: {
    phone: '07700 900 156', stage: 'CBT completed', course: 'cbt125', lessons: 1, cbtStatus: 'completed',
    progress: { cbt125: { done: 5, total: 5, complete: true } },
    tests: [],
    charges: [{ id: 'ch4', label: 'CBT (125)', amount: 139, date: '28 May 2026', booking: 'CBT · 28 May' }],
    payments: [{ id: 'pm2', amount: 139, method: 'bank-transfer', date: '27 May 2026', by: 'Rachel Burns' }],
    incidents: [],
    flags: [{ id: 'f2', kind: 'safety', text: 'Build up roundabout confidence slowly — anxious in traffic.' }],
    notes: [{ id: 'n2', by: 'Mark Doherty', date: '28 May', text: 'Completed all 5 elements. Comfortable on the 125 by end of day.' }],
  },
  s4: {
    phone: '07700 900 178', stage: 'CBT — return day', course: 'cbt125', lessons: 1, cbtStatus: 'return-day',
    progress: { cbt125: { done: 3, total: 5 } },
    tests: [],
    charges: [
      { id: 'ch5', label: 'CBT (125)', amount: 139, date: '20 May 2026', booking: 'CBT · 20 May' },
      { id: 'ch6', label: 'CBT return day', amount: 75, date: '20 May 2026', booking: 'CBT · 16 Jun' },
    ],
    payments: [{ id: 'pm3', amount: 139, method: 'cash', date: '20 May 2026', by: 'Gary Thompson' }],
    incidents: [],
    flags: [],
    notes: [{ id: 'n3', by: 'Gary Thompson', date: '20 May', text: 'Needs a return day — ran out of time on Element E (on-road). Booked back in 16 Jun.' }],
  },
  s5: {
    phone: '07700 900 190', stage: 'Practical training', course: 'practical', lessons: 6, cbtStatus: 'completed',
    progress: { cbt650: { done: 5, total: 5, complete: true }, practical: { done: 5, total: 7 } },
    tests: [
      { type: 'practical', attempt: 1, outcome: 'fail', date: '28 May 2026', ref: 'DVA-77 330 781' },
      { type: 'practical', attempt: 2, outcome: 'booked', date: '19 Jun 2026', ref: 'DVA-77 440 902' },
    ],
    charges: [
      { id: 'ch7', label: 'CBT (650)', amount: 159, date: '02 Apr 2026' },
      { id: 'ch9', label: 'Practical training \u00d73', amount: 285, date: '15 May 2026' },
    ],
    payments: [{ id: 'pm4', amount: 234, method: 'card-in-person', date: '02 Apr 2026', by: 'Rachel Burns' }],
    incidents: [{ id: 'in1', date: '28 May 2026', bike: 'b5', desc: 'Low-speed drop during U-turn practice. Cosmetic scuff to fairing, bike still serviceable.' }],
    flags: [],
    notes: [{ id: 'n4', by: 'Mark Doherty', date: '29 May', text: 'Failed practical on observation at junctions. Lots of potential — nerves on the day. Confidence work for the resit.' }],
  },
  s6: {
    phone: '07700 900 201', stage: 'CBT booked', course: 'cbt125', lessons: 0, cbtStatus: 'booked',
    progress: { cbt125: { done: 0, total: 5 } },
    tests: [],
    charges: [{ id: 'ch10', label: 'CBT (125)', amount: 139, date: '04 Jun 2026', booking: 'CBT · 13 Jun' }],
    payments: [],
    incidents: [],
    flags: [],
    notes: [],
  },
  s7: {
    phone: '07700 900 223', stage: 'Practical training', course: 'practical', lessons: 4, cbtStatus: 'completed',
    progress: { cbt650: { done: 5, total: 5, complete: true }, practical: { done: 5, total: 7 } },
    tests: [
      { type: 'practical', attempt: 1, outcome: 'fail', date: '03 Jun 2026', ref: 'DVA-77 410 119' },
      { type: 'practical', attempt: 2, outcome: 'booked', date: '10 Jun 2026', ref: 'DVA-77 410 350' },
    ],
    charges: [
      { id: 'ch11', label: 'CBT (650)', amount: 159, date: '10 Apr 2026' },
      { id: 'ch12', label: 'Practical training \u00d72', amount: 190, date: '20 May 2026' },
    ],
    payments: [{ id: 'pm5', amount: 159, method: 'cash', date: '10 Apr 2026', by: 'Gary Thompson' }],
    incidents: [],
    flags: [{ id: 'f3', kind: 'safety', text: 'Tends to rush the emergency stop — reinforce observation first.' }],
    notes: [{ id: 'n5', by: 'Aoife McGrath', date: '03 Jun', text: 'Failed practical on the speed for emergency stop. Otherwise manoeuvres are clean. Resit 10 Jun.' }],
  },
};
const balanceOf = (id) => {
  const r = SREC[id]; if (!r) return 0;
  return r.charges.reduce((a, c) => a + c.amount, 0) - r.payments.reduce((a, p) => a + p.amount, 0);
};
const STUDENT_LIST = ['s1', 's2', 's3', 's4', 's5', 's6', 's7'];

const PAY_METHODS = [
  { id: 'cash', label: 'Cash' },
  { id: 'bank-transfer', label: 'Bank transfer' },
  { id: 'card-in-person', label: 'Card in person' },
  { id: 'other', label: 'Other' },
];
const methodLabel = (m) => (PAY_METHODS.find(x => x.id === m) || {}).label || m;
// region-aware test label (NI: practical; GB: Mod 1/Mod 2)
const TEST_LABEL = { practical: 'Practical', mod1: 'Mod 1', mod2: 'Mod 2' };

// ---- Instructor pay (owed-tracking, not payroll) ----
const PAY_BASES = [
  { id: 'percentage', label: 'Percentage of revenue' },
  { id: 'per-day', label: 'Per day' },
  { id: 'per-session', label: 'Per session' },
  { id: 'per-hour', label: 'Per hour' },
  { id: 'per-student', label: 'Per student' },
  { id: 'salary', label: 'Salary / N/A' },
];
const INSTRUCTOR_PAY = {
  i1: { basis: 'percentage', rate: 40, perCourse: { practical: 45 },
    earnings: [
      { id: 'ie1', session: 'CBT day · 2 Jun', date: '2 Jun', amount: 222.40, from: '40% of 4 × CBT £139 = £556' },
      { id: 'ie2', session: 'Practical · 5 Jun', date: '5 Jun', amount: 42.75, from: '45% of Practical £95' },
    ],
    payments: [{ id: 'ip1', amount: 200, method: 'bank-transfer', date: '31 May' }] },
  i2: { basis: 'per-day', rate: 120,
    earnings: [{ id: 'ie3', session: 'CBT day · 4 Jun', date: '4 Jun', amount: 120, from: 'Flat day rate' }],
    payments: [] },
  i3: { basis: 'per-session', rate: 85,
    earnings: [
      { id: 'ie4', session: 'CBT · 28 May', date: '28 May', amount: 85, from: 'Flat session rate' },
      { id: 'ie5', session: 'Practical · 2 Jun', date: '2 Jun', amount: 85, from: 'Flat session rate' },
    ],
    payments: [{ id: 'ip2', amount: 85, method: 'cash', date: '30 May' }] },
  i4: { basis: 'salary', rate: 0, earnings: [], payments: [] },
};
const owedToInstructor = (id) => {
  const p = INSTRUCTOR_PAY[id]; if (!p) return 0;
  return p.earnings.reduce((a, e) => a + e.amount, 0) - p.payments.reduce((a, x) => a + x.amount, 0);
};

// ---- Notifications (per role) ----
const NOTIFS = {
  student: [
    { id: 'sn1', icon: 'clock', tone: 'primary', title: 'Session tomorrow', body: 'Practical training · Fri 12 Jun, 09:00 at Belfast with Aoife.', time: '2h ago', unread: true },
    { id: 'sn2', icon: 'card', tone: 'warning', title: 'Payment outstanding', body: 'You have £95 left to pay for your practical training. Pay in person on the day.', time: 'Yesterday', unread: true },
    { id: 'sn3', icon: 'check-circle', tone: 'success', title: 'Booking confirmed', body: 'Practical training on Fri 12 Jun is confirmed. Bike: Honda CB500F.', time: '2 days ago', unread: false },
    { id: 'sn4', icon: 'target', tone: 'primary', title: 'You can book practical training', body: 'Theory passed — you\u2019re eligible to book your practical training.', time: '21 May', unread: false },
  ],
  instructor: [
    { id: 'in1', icon: 'alert', tone: 'danger', title: 'Bike down on your session', body: 'Yamaha YBR125 flagged damaged — Niamh Quinn (Sat CBT) needs reassignment.', time: '18m ago', unread: true },
    { id: 'in2', icon: 'calendar', tone: 'primary', title: 'New booking added', body: 'Ryan Carson booked practical training on Wed 10 Jun, 09:00 Belfast.', time: '1h ago', unread: true },
    { id: 'in3', icon: 'route', tone: 'warning', title: 'Tight travel gap', body: 'Belfast 12:30 → Lisburn 13:00 is tight (usually ~25 min drive).', time: '3h ago', unread: false },
    { id: 'in4', icon: 'list', tone: 'neutral', title: 'Today\u2019s schedule', body: '1 session today: CBT group at Belfast, 08:30. 3 students.', time: 'Today 07:00', unread: false },
  ],
  admin: [
    { id: 'an1', icon: 'shield', tone: 'danger', title: 'Approval needed', body: 'Niamh Quinn\u2019s CBT can\u2019t be re-biked — cancel needs your approval. Slot held.', time: '15m ago', unread: true },
    { id: 'an2', icon: 'card', tone: 'warning', title: 'Overdue payments', body: '3 students owe a combined £424. Emma Wilson (£139) is oldest.', time: '1h ago', unread: true },
    { id: 'an3', icon: 'target', tone: 'warning', title: 'Repeated test failure', body: 'Ryan Carson failed the practical test (attempt 1). Resit booked 10 Jun.', time: '3 days ago', unread: false },
    { id: 'an4', icon: 'route', tone: 'primary', title: 'End-of-day logistics', body: '3 bikes need moving for tomorrow\u2019s sessions.', time: 'Today 17:30', unread: false },
  ],
};
const NOTIF_CATEGORIES = [
  { id: 'reminders', label: 'Session reminders', desc: '24h & 2h before a session', urgent: false },
  { id: 'bookings', label: 'Bookings', desc: 'Confirmations, cancels, reschedules', urgent: false },
  { id: 'disruptions', label: 'Disruptions & issues', desc: 'Bike swaps, approvals needed', urgent: true },
  { id: 'payments', label: 'Payments', desc: 'Outstanding balance reminders', urgent: false },
  { id: 'news', label: 'Retention & news', desc: 'CBT expiry, eligibility nudges', urgent: false },
];
const NOTIF_PREFS_DEFAULT = {
  reminders: { email: true, push: true, sms: false },
  bookings: { email: true, push: true, sms: false },
  disruptions: { email: true, push: true, sms: true },
  payments: { email: true, push: false, sms: false },
  news: { email: false, push: false, sms: false },
};

// ---- Travel-time matrix (approx minutes) + buffer ----
const TRAVEL = {
  belfast: { belfast: 0, lisburn: 25, newry: 45 },
  lisburn: { belfast: 25, lisburn: 0, newry: 35 },
  newry: { belfast: 45, lisburn: 35, newry: 0 },
};
const TRAVEL_BUFFER = 15;

Object.assign(window, {
  SREC, balanceOf, STUDENT_LIST, PAY_METHODS, methodLabel, TEST_LABEL,
  PAY_BASES, INSTRUCTOR_PAY, owedToInstructor,
  NOTIFS, NOTIF_CATEGORIES, NOTIF_PREFS_DEFAULT, TRAVEL, TRAVEL_BUFFER,
});
