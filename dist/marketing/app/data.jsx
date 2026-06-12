// Kickstand — mock data for a demo tenant. Realistic NI / UK rider-training domain.

const SCHOOL = {
  name: 'Lagan Valley Rider Training',
  short: 'Lagan Valley',
  tagline: 'CBT · theory · practical — Belfast, Lisburn & Newry',
  region: 'NI',            // NI pathway: provisional → CBT → theory → practical test
  body: 'DVA',             // test authority (GB would be DVSA: Mod 1 / Mod 2)
  practicalName: 'Practical test',
  theoryName: 'Theory test',
  onboardingMode: 'approval', // 'open' = book immediately · 'approval' = manager reviews sign-ups first
  instructorsCanRecordPayments: true, // per-school: instructors can take payments in the field (record-only)
  cancelCutoffHrs: 48,
  crossSiteNoticeHrs: 24,
};

// region pathway (drives docs / progress display). NI shown; a GB tenant would
// configure CBT → Mod 1 → Mod 2 instead.
const PATHWAY = [
  { key: 'provisional', label: 'Provisional licence', icon: 'card' },
  { key: 'cbt', label: 'CBT (DL196)', icon: 'shield' },
  { key: 'theory', label: 'Theory test', icon: 'check-circle' },
  { key: 'practical', label: 'Practical test', icon: 'target' },
];

const LOCATIONS = [
  { id: 'belfast', name: 'Belfast (Boucher Rd)', short: 'Belfast', pad: 'Boucher Road Playing Fields' },
  { id: 'lisburn', name: 'Lisburn (Knockmore)', short: 'Lisburn', pad: 'Knockmore Industrial Estate' },
  { id: 'newry',   name: 'Newry (Greenbank)',   short: 'Newry',   pad: 'Greenbank Industrial Estate' },
];

// NI course types — CBT runs as bike-category variants, plus practical training.
// (A GB tenant would configure CBT / Mod 1 / Mod 2 here instead.)
const COURSE_TYPES = [
  {
    id: 'cbt125', code: 'CBT · 125', name: 'CBT (125cc)',
    blurb: 'Full-day CBT on a 125 — cat A1 (typically 17–19). Earns your DL196.',
    duration: '1 day · 8hrs', durationShort: '8h', ratio: '2:1', cat: 'A1',
    prereqs: ['Provisional licence'], color: 'var(--primary)', price: '£139',
    icon: 'cap',
  },
  {
    id: 'cbt650', code: 'CBT · 650', name: 'CBT (500/650cc)',
    blurb: 'CBT on a larger A2 machine (≈500–650cc) — for cat A2 (19+).',
    duration: '1 day · 8hrs', durationShort: '8h', ratio: '2:1', cat: 'A2',
    prereqs: ['Provisional licence'], color: 'oklch(0.56 0.15 300)', price: '£159',
    icon: 'cap',
  },
  {
    id: 'cbt600', code: 'CBT · 600', name: 'CBT (600cc)',
    blurb: 'Direct-access CBT on a 600 — cat A, riders aged 24+.',
    duration: '1 day · 8hrs', durationShort: '8h', ratio: '2:1', cat: 'A',
    prereqs: ['Provisional licence', 'Aged 24+'], color: 'oklch(0.6 0.17 25)', price: '£169',
    icon: 'cap', lockMsg: 'Direct access (category A) — requires you to be 24 or over.',
  },
  {
    id: 'practical', code: 'PRACTICAL', name: 'Practical training',
    blurb: 'On- & off-road tuition to prep for your DVA practical test.',
    duration: 'Half day · 4hrs', durationShort: '4h', ratio: '1:1', cat: 'A2',
    prereqs: ['Valid CBT', 'Theory test passed'], color: 'var(--success)', price: '£95',
    icon: 'target',
  },
  {
    id: 'practicaltest', code: 'TEST', name: 'Practical test day',
    blurb: 'Reserve a bike + instructor escort for your DVA practical test.',
    duration: '1hr slot', durationShort: '1h', ratio: '1:1', cat: 'A2',
    prereqs: ['Valid CBT', 'Theory test passed'], color: 'oklch(0.6 0.17 25)', price: '£55',
    icon: 'flag', non_teaching: true,
  },
];

// status: ready | mechanic | damaged | offroad
const BIKES = [
  { id: 'b1', name: 'Honda CB125F',   reg: 'GKZ 4471', cat: 'A1', cc: 125, trans: 'manual', status: 'ready',    home: 'belfast', loc: 'belfast' },
  { id: 'b2', name: 'Honda CB125F',   reg: 'GKZ 4472', cat: 'A1', cc: 125, trans: 'manual', status: 'ready',    home: 'belfast', loc: 'lisburn' },
  { id: 'b3', name: 'Yamaha YBR125',  reg: 'RKZ 8810', cat: 'A1', cc: 125, trans: 'manual', status: 'ready',    home: 'belfast', loc: 'belfast' },
  { id: 'b4', name: 'Lexmoto Echo',   reg: 'LXZ 2204', cat: 'A1', cc: 125, trans: 'auto',   status: 'ready',    home: 'lisburn', loc: 'lisburn' },
  { id: 'b5', name: 'Honda CB500F',   reg: 'OEZ 6633', cat: 'A2', cc: 500, trans: 'manual', status: 'ready',    home: 'belfast', loc: 'newry'   },
  { id: 'b6', name: 'Kawasaki Z400',  reg: 'WGZ 1197', cat: 'A2', cc: 400, trans: 'manual', status: 'mechanic', home: 'lisburn', loc: 'lisburn', note: 'Annual service — back Mon' },
  { id: 'b7', name: 'Honda CB500F',   reg: 'OEZ 6634', cat: 'A2', cc: 500, trans: 'manual', status: 'ready',    home: 'newry',   loc: 'newry'   },
  { id: 'b8', name: 'Yamaha YBR125',  reg: 'RKZ 8811', cat: 'A1', cc: 125, trans: 'manual', status: 'damaged',  home: 'belfast', loc: 'belfast', note: 'Clutch cable snapped mid-session' },
  { id: 'b9', name: 'Honda CB650R',   reg: 'TRZ 5540', cat: 'A',  cc: 649, trans: 'manual', status: 'ready',    home: 'belfast', loc: 'belfast' },
];

const INSTRUCTORS = [
  { id: 'i1', name: 'Mark Doherty',   initials: 'MD', qualified: ['cbt125','cbt650','cbt600','practical','practicaltest'], home: 'belfast', tone: 277 },
  { id: 'i2', name: 'Siobhán Kelly',  initials: 'SK', qualified: ['cbt125','cbt650','practical'],          home: 'lisburn', tone: 160 },
  { id: 'i3', name: 'Gary Thompson',  initials: 'GT', qualified: ['cbt125','cbt600','practical','practicaltest'],          home: 'newry',   tone: 70  },
  { id: 'i4', name: 'Aoife McGrath',  initials: 'AM', qualified: ['cbt125','cbt650','practical','practicaltest'],          home: 'belfast', tone: 25  },
];

// the signed-in student
const ME = {
  id: 's1', name: 'Jordan Reid', initials: 'JR',
  provisional: 'REID9 012 24 J 99', cat: 'A2', trans: 'manual',
  cbtVariant: 'cbt650', cbtExpiry: '14 Mar 2027', cbtIssued: '14 Mar 2025',
  theoryPassed: '21 May 2026', theoryRef: 'DVA-44 902 118',
  practicalTest: { date: '24 Jun 2026', time: '10:15', centre: 'Belfast (Balmoral) MTC', ref: 'DVA-77 410 226' },
};

const OTHER_STUDENTS = [
  { id: 's2', name: 'Emma Wilson',    initials: 'EW', cat: 'A1', trans: 'manual' },
  { id: 's3', name: 'Liam O\u2019Neill', initials: 'LO', cat: 'A1', trans: 'auto' },
  { id: 's4', name: 'Chloe Adams',    initials: 'CA', cat: 'A1', trans: 'manual' },
  { id: 's5', name: 'Daniel Burns',   initials: 'DB', cat: 'A2', trans: 'manual' },
  { id: 's6', name: 'Niamh Quinn',    initials: 'NQ', cat: 'A1', trans: 'manual' },
  { id: 's7', name: 'Ryan Carson',    initials: 'RC', cat: 'A2', trans: 'manual' },
];

// Sessions — keyed for the booking screen + calendar. day is index Mon=0..Sun=6 of the demo week.
// "this week" = w/c Mon 8 Jun 2026.
const WEEK_DATES = ['Mon 8','Tue 9','Wed 10','Thu 11','Fri 12','Sat 13','Sun 14'];

const SESSIONS = [
  // CBT group days (capacity model) — by bike-category variant
  { id: 'se1', ct: 'cbt125', day: 1, date: 'Tue 9 Jun',  start: '08:30', end: '16:30', loc: 'belfast', inst: 'i1', cap: 4, booked: 3 },
  { id: 'se2', ct: 'cbt650', day: 3, date: 'Thu 11 Jun', start: '08:30', end: '16:30', loc: 'lisburn', inst: 'i2', cap: 4, booked: 2 },
  { id: 'se3', ct: 'cbt125', day: 5, date: 'Sat 13 Jun', start: '08:30', end: '16:30', loc: 'belfast', inst: 'i4', cap: 4, booked: 4 },
  { id: 'se4', ct: 'cbt125', day: 5, date: 'Sat 13 Jun', start: '08:30', end: '16:30', loc: 'newry',   inst: 'i3', cap: 4, booked: 1 },
  // Practical training (1:1)
  { id: 'se5', ct: 'practical', day: 1, date: 'Tue 9 Jun',  start: '13:00', end: '17:00', loc: 'lisburn', inst: 'i2', cap: 1, booked: 0 },
  { id: 'se6', ct: 'practical', day: 2, date: 'Wed 10 Jun', start: '09:00', end: '13:00', loc: 'belfast', inst: 'i1', cap: 1, booked: 0 },
  { id: 'se7', ct: 'practical', day: 4, date: 'Fri 12 Jun', start: '09:00', end: '13:00', loc: 'belfast', inst: 'i4', cap: 1, booked: 1 },
  { id: 'se8', ct: 'practical', day: 2, date: 'Wed 10 Jun', start: '14:00', end: '18:00', loc: 'newry',   inst: 'i3', cap: 1, booked: 0 },
  { id: 'se9', ct: 'practical', day: 4, date: 'Fri 12 Jun', start: '13:30', end: '17:30', loc: 'belfast', inst: 'i1', cap: 1, booked: 1 },
  // Test day (non-teaching course type — reserves bike + escort, no assessment)
  { id: 'se10', ct: 'practicaltest', day: 2, date: 'Wed 10 Jun', start: '10:15', end: '11:15', loc: 'belfast', inst: 'i1', cap: 1, booked: 0 },
];

// the student's own bookings
const MY_BOOKINGS = [
  { id: 'bk1', se: 'se7', ct: 'practical', status: 'booked', date: 'Fri 12 Jun', start: '09:00', end: '13:00', loc: 'belfast', inst: 'i4', bike: 'b5' },
  { id: 'bk2', se: null, ct: 'cbt650', status: 'completed', date: '14 Mar 2025', start: '08:30', end: '16:30', loc: 'belfast', inst: 'i1', bike: 'b5', result: 'DL196 issued' },
];

// CBT day roster (instructor view) — for se1
const ROSTER = [
  { student: 's2', bike: 'b1', attend: 'present' },
  { student: 's3', bike: 'b4', attend: 'present' },
  { student: 's6', bike: 'b3', attend: null },
];

// competency checklists. CBT variants share the 5 elements; practical = NI test skills.
const COMPETENCIES = {
  cbt: [
    { id: 'A', label: 'Element A — Introduction & eyesight' },
    { id: 'B', label: 'Element B — On-site controls & handling' },
    { id: 'C', label: 'Element C — On-site riding & manoeuvres' },
    { id: 'D', label: 'Element D — On-road theory & safety' },
    { id: 'E', label: 'Element E — On-road riding (2hrs)' },
  ],
  practical: [
    { id: 'p1', label: 'Slow-speed control & U-turn' },
    { id: 'p2', label: 'Slalom & figure-of-8' },
    { id: 'p3', label: 'Controlled & emergency stop' },
    { id: 'p4', label: 'Hill start & moving off on a gradient' },
    { id: 'p5', label: 'Junctions & roundabouts' },
    { id: 'p6', label: 'Dual carriageway / faster roads' },
    { id: 'p7', label: 'Independent on-road riding' },
  ],
};
// CBT variants (cbt125/cbt650/cbt600) all use the CBT element list.
const compsFor = (ct) => (ct && ct.startsWith('cbt')) ? COMPETENCIES.cbt : COMPETENCIES.practical;

// student's progress (Jordan, cat A2 — CBT done, prepping for the practical test)
const MY_PROGRESS = {
  cbt650: { done: 5, total: 5, complete: true },
  practical: { done: 4, total: 7, items: { p1: 1, p2: 1, p3: 1, p4: 1, p5: 0, p6: 0, p7: 0 } },
};

// a live disruption — bike b8 went down at Belfast
const DISRUPTION = {
  id: 'd1', bike: 'b8', loc: 'belfast', reason: 'damaged',
  at: 'Today 11:42', reportedBy: 'Aoife McGrath',
  affected: [
    { booking: 'CBT · Emma Wilson',    session: 'Tue 9 Jun · 08:30 Belfast', status: 'swapped',  swapTo: 'b3' },
    { booking: 'CBT · Niamh Quinn',    session: 'Sat 13 Jun · 08:30 Belfast', status: 'pending' },
    { booking: 'Practical · Ryan Carson',  session: 'Wed 10 Jun · 09:00 Belfast', status: 'approval' },
  ],
};

// end-of-day logistics — bikes whose loc != tomorrow's session loc
const LOGISTICS = [
  { dest: 'lisburn', need: [
    { bike: 'b1', from: 'belfast', forSession: 'CBT 08:30' },
  ]},
  { dest: 'belfast', need: [
    { bike: 'b5', from: 'newry', forSession: 'Practical 13:30' },
    { bike: 'b7', from: 'newry', forSession: 'Practical 09:00' },
  ]},
];

// students who self-signed-up and are awaiting manager approval (onboardingMode: 'approval')
const PENDING = [
  { id: 'pe1', name: 'Sophie Hart',  initials: 'SH', phone: '07700 900 245', cat: 'A1', applied: 'Today 09:14',  note: 'Wants CBT asap — turns 17 next week.' },
  { id: 'pe2', name: 'Conor Magee',  initials: 'CM', phone: '07700 900 267', cat: 'A2', applied: 'Yesterday',    note: '' },
  { id: 'pe3', name: 'Beth Larkin',  initials: 'BL', phone: '07700 900 289', cat: 'A',  applied: '2 days ago',   note: 'Returning rider, full car licence.' },
];

// Instructor expense categories — drives the chip selector in the
// "Add expense" flow and the pill on each expense row. Tones picked to
// echo the existing course-type palette so the mock feels consistent.
const EXPENSE_CATEGORIES = [
  { id: 'petrol',  label: 'Petrol',  icon: 'fuel',   tone: 25 },
  { id: 'lunch',   label: 'Lunch',   icon: 'cap',    tone: 70 },
  { id: 'parking', label: 'Parking', icon: 'pin',    tone: 277 },
  { id: 'tolls',   label: 'Tolls',   icon: 'route',  tone: 160 },
  { id: 'other',   label: 'Other',   icon: 'more-h', tone: 200 },
];

// Mock instructor expenses across all four states (pending / approved /
// reimbursed / rejected) so both screens have realistic content to render.
//   i1 = Dave (THIS_INST in instructor.jsx) — drives the instructor app
//   i2 / i4 = Siobhán / Aoife — bulk for the admin pending queue
const EXPENSES = [
  // Dave (current instructor) — list view shows a mix of states.
  // Note vs reviewerNote: the instructor's note is *their* context for the
  // owner; reviewerNote is what the owner attached when approving / rejecting
  // / marking reimbursed (e.g. "approved — include in next payroll").
  { id: 'e1', instr: 'i1', cat: 'petrol',  amount: 42.50, when: 'Today · 08:14',     submittedAt: 'Today · 08:14',     status: 'pending',    where: 'Esso · Sydenham',    note: 'Topped up for the week ahead' },
  { id: 'e2', instr: 'i1', cat: 'parking', amount: 6.00,  when: 'Yesterday · 10:30', submittedAt: 'Yesterday · 10:30', status: 'pending',    where: 'Newry test centre',  note: 'DVA visitor parking' },
  { id: 'e3', instr: 'i1', cat: 'lunch',   amount: 9.50,  when: 'Mon 8 Jun',         submittedAt: 'Mon 8 Jun · 13:42', status: 'approved',   where: 'Boucher caff',       note: '', reviewerNote: 'OK once — keep within sensible limits.', reviewedBy: 'Rachel Mooney', reviewedOn: 'Mon 8 Jun · 18:10' },
  { id: 'e4', instr: 'i1', cat: 'petrol',  amount: 38.00, when: 'Wed 3 Jun',         submittedAt: 'Wed 3 Jun · 08:55', status: 'reimbursed', where: 'Esso · Sydenham',    note: '', reviewerNote: '', reviewedBy: 'Rachel Mooney', reviewedOn: 'Wed 3 Jun · 19:20', paidOn: 'Fri 5 Jun', paidVia: 'Bank transfer', paidBy: 'Rachel Mooney' },
  { id: 'e5', instr: 'i1', cat: 'lunch',   amount: 12.50, when: 'Tue 2 Jun',         submittedAt: 'Tue 2 Jun · 14:11', status: 'rejected',   where: "Nando's",            note: 'Treated student to lunch', reviewerNote: 'Outside policy — instructor meals only, not students.', reviewedBy: 'Rachel Mooney', reviewedOn: 'Wed 3 Jun · 09:02' },
  // Other instructors — populate the admin queue
  { id: 'e6', instr: 'i2', cat: 'petrol',  amount: 36.40, when: 'Today · 09:02',     submittedAt: 'Today · 09:02',     status: 'pending',    where: 'BP · Lisburn',       note: '' },
  { id: 'e7', instr: 'i4', cat: 'tolls',   amount: 2.50,  when: 'Today · 07:45',     submittedAt: 'Today · 07:45',     status: 'pending',    where: 'Foyle Bridge',       note: '' },
  { id: 'e8', instr: 'i4', cat: 'petrol',  amount: 44.10, when: 'Yesterday',          submittedAt: 'Yesterday · 19:30', status: 'approved',   where: 'Texaco · Newry',     note: '', reviewerNote: '', reviewedBy: 'Rachel Mooney', reviewedOn: 'Today · 08:01' },
];

const expensesForInstr = (instrId) => EXPENSES.filter(e => e.instr === instrId);
const expenseCat = (id) => EXPENSE_CATEGORIES.find(c => c.id === id) || EXPENSE_CATEGORIES[4];

// lookup helpers
const byId = (arr) => Object.fromEntries(arr.map(o => [o.id, o]));
const BIKE = byId(BIKES);
const INST = byId(INSTRUCTORS);
const LOC  = byId(LOCATIONS);
const CT   = byId(COURSE_TYPES);
const STU  = byId([ME, ...OTHER_STUDENTS]);

Object.assign(window, {
  SCHOOL, PATHWAY, LOCATIONS, COURSE_TYPES, BIKES, INSTRUCTORS, ME, OTHER_STUDENTS, PENDING,
  WEEK_DATES, SESSIONS, MY_BOOKINGS, ROSTER, COMPETENCIES, compsFor, MY_PROGRESS,
  DISRUPTION, LOGISTICS, BIKE, INST, LOC, CT, STU,
  EXPENSE_CATEGORIES, EXPENSES, expensesForInstr, expenseCat,
});
