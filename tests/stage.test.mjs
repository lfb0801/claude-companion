import test from 'node:test';
import assert from 'node:assert/strict';
import {initial,reduce} from '../state.js';

// Browser globals the stage touches, stubbed for node.
globalThis.requestAnimationFrame = () => {};
globalThis.devicePixelRatio = 1;
const {Theater, ENTER, OFFSTAGE, STAMP_COOLDOWN, DENY_HOLD, GREET, looks, ACCESSORIES} = await import('../theater.js');

const session = (id, prompt = null) => ({id, folder: `proj-${id}`, title: `Task ${id}`, prompt});
const ask = (id, kind = 'permission') => ({id, kind, text: `Bash: npm test (${id})`, detail: 'Run the tests'});

// A stage wired to the reducer the way app.js wires it: an answer clears the prompt.
function rig(sessions = []) {
  const answers = [];
  let state = reduce(initial(), {type: 'sessions', sessions});
  const t = new Theater({getContext: () => ({})}, e => { answers.push(e); dispatch({type: 'answered', id: e.owner, prompt: e.id}); });
  function dispatch(action) { state = reduce(state, action); t.sync(state); }
  t.sync(state);
  return {t, answers, dispatch, get state() { return state; }, settle(n = ENTER + 1) { for (let i = 0; i < n; i++) t.tick(); }};
}

test('reducer: tools toggle, sessions update in place, and only the first answer to a prompt counts', () => {
  let s = initial();
  for (const tool of ['whip', 'cannon', 'stamp', 'intern']) { s = reduce(s, {type: tool}); assert.equal(s[tool], true); }
  assert.equal(reduce(reduce(initial(), {type: 'crack'}), {type: 'fire'}).crack, 0, 'crack and fire need their tool');
  s = reduce(s, {type: 'sessions', sessions: [session('a'), session('b')]});
  s = reduce(s, {type: 'session', session: {id: 'a', title: 'Renamed'}});
  assert.deepEqual(s.sessions.map(x => [x.id, x.title, x.folder]), [['a', 'Renamed', 'proj-a'], ['b', 'Task b', 'proj-b']]);
  s = reduce(s, {type: 'session', session: {id: 'c', folder: 'new'}});
  assert.equal(s.sessions.at(-1).prompt, null);
  s = reduce(s, {type: 'prompt', id: 'a', prompt: ask('p1')});
  s = reduce(s, {type: 'prompt', id: 'a', prompt: ask('p2')});
  assert.equal(reduce(s, {type: 'answered', id: 'a', prompt: 'p1'}).sessions[0].prompt.id, 'p2', 'a stale answer is ignored');
  assert.equal(reduce(s, {type: 'answered', id: 'a', prompt: 'p2'}).sessions[0].prompt, null);
  assert.deepEqual(reduce(s, {type: 'end', id: 'b'}).sessions.map(x => x.id), ['a', 'c']);
  const r = reduce(s, {type: 'reset'});
  assert.equal(r.whip, false); assert.equal(r.sessions.length, 3);
});

test('a character is on stage only while its session needs you: it slides in from the right and leaves after the answer', () => {
  const r = rig([session('a'), session('b')]);
  assert.equal(r.t.entities.size, 0, 'idle sessions wait off stage');
  r.dispatch({type: 'prompt', id: 'a', prompt: ask('p1')});
  const a = r.t.entities.get('a');
  assert.ok(a && r.t.enterDx(a) > 0 && a.x + r.t.enterDx(a) === OFFSTAGE, 'starts off stage right');
  assert.equal(a.folder, 'proj-a'); assert.equal(a.title, 'Task a'); assert.equal(a.box.text, 'Bash: npm test (p1)');
  r.settle();
  assert.equal(r.t.enterDx(a), 0);
  assert.ok(a.x >= 1000, 'grouped on the right');
  r.dispatch({type: 'answered', id: 'a', prompt: 'p1'}); // answered somewhere else, e.g. the terminal
  assert.equal(r.t.entities.size, 0);
  assert.equal(r.t.departures.length, 1);
  for (let i = 0; i < 80; i++) r.t.tick();
  assert.equal(r.t.departures.length, 0);
});

test('a new prompt for a waiting character replaces its box and makes it a target again', () => {
  const r = rig([session('a', ask('p1'))]); r.settle();
  r.t.entities.get('a').answered = true;
  r.dispatch({type: 'prompt', id: 'a', prompt: ask('p2', 'question')});
  const a = r.t.entities.get('a');
  assert.equal(a.box.id, 'p2'); assert.equal(a.box.kind, 'question'); assert.equal(a.answered, false);
});

test('layout never stacks two characters on one spot, and a freed slot is reused', () => {
  const r = rig(Array.from({length: 24}, (_, i) => session(`s${i}`, ask(`p${i}`))));
  const spots = [...r.t.entities.values()].map(a => `${a.x},${a.y}`);
  assert.equal(new Set(spots).size, 24);
  const freed = r.t.entities.get('s3').slot;
  r.dispatch({type: 'answered', id: 's3', prompt: 'p3'});
  r.dispatch({type: 'session', session: session('late')});
  r.dispatch({type: 'prompt', id: 'late', prompt: ask('px')});
  assert.equal(r.t.entities.get('late').slot, freed);
});

test('up to 15 waiting sessions: no prompt box overlaps another box or any character, and all of it stays on stage', () => {
  const r = rig(Array.from({length: 15}, (_, i) => session(`s${i}`, ask(`p${i}`))));
  const L = [...r.t.entities.values()];
  // A character's footprint: sprite (half height 62) plus its two label lines (down to y + 104).
  const body = a => ({x: a.x - a.r, y: a.y - 62, w: a.r * 2, h: 62 + 104});
  const overlap = (p, q) => p.x < q.x + q.w && q.x < p.x + p.w && p.y < q.y + q.h && q.y < p.y + p.h;
  const rects = [...L.map(a => ['box ' + a.id, a.box]), ...L.map(a => ['body ' + a.id, body(a)])];
  for (const [n, p] of rects) {
    assert.ok(p.x >= 0 && p.y >= 0 && p.x + p.w <= 1600 && p.y + p.h <= 900, `${n} on stage`);
    for (const [m, q] of rects) if (n < m) assert.ok(!overlap(p, q), `${n} overlaps ${m}`);
  }
  assert.equal(L[0].x, Math.max(...L.map(a => a.x)), 'the first session takes the rightmost column');
});

test('whip: one swing answers one prompt with allow, even with many overlapping characters', () => {
  const r = rig(Array.from({length: 6}, (_, i) => session(`s${i}`, ask(`p${i}`)))); r.settle();
  r.dispatch({type: 'whip'});
  for (const a of r.t.entities.values()) { a.x = 100; a.y = 100; a.r = 30; a.box = {...a.box, x: 0, y: 0, w: 10, h: 10}; }
  r.t.whip = {step: () => false, points: [{x: 0, y: 100, px: 0, py: 100}, {x: 50, y: 100, px: 50, py: 100}, {x: 150, y: 100, px: 50, py: 100}]};
  for (let i = 0; i < 60; i++) r.t.tick();
  assert.equal(r.answers.length, 1);
  assert.deepEqual({...r.answers[0], owner: undefined, id: undefined}, {type: 'answer', owner: undefined, id: undefined, decision: 'allow', source: 'whip'});
  r.t.swing.reset(); r.t.tick();
  assert.equal(r.answers.length, 2);
});

test('cannon: a shot answers the nearest prompt with allow and is spent', () => {
  const r = rig([session('a', ask('p1')), session('b', ask('p2'))]); r.settle();
  r.dispatch({type: 'cannon'});
  const a = r.t.entities.get('a'), m = a.box;
  r.t.shots = [{x: m.x - 10, y: m.y + 40, px: m.x - 40, py: m.y + 40, vx: 30, vy: 0, life: 20}];
  r.t.tick(); r.t.tick();
  assert.deepEqual(r.answers.map(e => [e.owner, e.id, e.decision, e.source]), [['a', 'p1', 'allow', 'cannon']]);
  assert.equal(r.t.shots.length, 0);
});

test('stamp: a click on a prompt denies it, empty ground marks NO TARGET, and the cooldown gates repeats', () => {
  const r = rig([session('a', ask('p1'))]); r.settle();
  r.dispatch({type: 'stamp'});
  assert.equal(r.t.stamp({x: 10, y: 10}), true);
  assert.equal(r.answers.length, 0); assert.equal(r.t.marks[0].text, 'NO TARGET');
  const box = r.t.entities.get('a').box;
  assert.equal(r.t.stamp({x: box.x + 5, y: box.y + 5}), false, 'cooling down');
  for (let i = 0; i < STAMP_COOLDOWN; i++) r.t.tick();
  assert.equal(r.t.stamp({x: box.x + 5, y: box.y + 5}), true);
  assert.deepEqual(r.answers.map(e => [e.owner, e.id, e.decision, e.source]), [['a', 'p1', 'deny', 'stamp']]);
  const gone = r.t.departures[0];
  assert.equal(gone.hold, DENY_HOLD); assert.equal(gone.messages.length, 1, 'the denied box stays visible while it leaves');
});

test('Intern: approves every waiting prompt in every session, one at a time, oldest first', () => {
  const r = rig([session('a', ask('p1')), session('b', ask('p2')), session('c', ask('p3'))]); r.settle();
  r.dispatch({type: 'intern'});
  for (let i = 0; i < 1500 && r.answers.length < 3; i++) r.t.tick();
  assert.deepEqual(r.answers.map(e => [e.owner, e.decision, e.source]), [['a', 'allow', 'intern'], ['b', 'allow', 'intern'], ['c', 'allow', 'intern']]);
  r.dispatch({type: 'prompt', id: 'b', prompt: ask('p4')});
  for (let i = 0; i < 1500 && r.answers.length < 4; i++) r.t.tick();
  assert.equal(r.answers.at(-1).id, 'p4');
  r.dispatch({type: 'intern'});
  assert.equal(r.t.autoWhipper, null);
});

test('a prompt gets one answer even when several tools land on it at once', () => {
  const r = rig([session('a', ask('p1'))]); r.settle();
  const a = r.t.entities.get('a');
  assert.equal(r.t.answer(a, 'allow', 'whip'), true);
  assert.equal(r.t.answer(a, 'deny', 'stamp'), false);
  assert.equal(r.answers.length, 1);
});

test('SessionStart: a character makes a short entrance and leaves again, unless a prompt arrives meanwhile', () => {
  const r = rig([session('a'), session('b')]);
  r.t.greet(session('a'));
  assert.ok(r.t.entities.has('a'));
  r.dispatch({type: 'whip'}); // a sync while greeting keeps it on stage
  assert.ok(r.t.entities.has('a'));
  for (let i = 0; i < GREET; i++) r.t.tick();
  assert.equal(r.t.entities.has('a'), false);
  assert.equal(r.t.departures.length, 1);
  r.t.greet(session('b'));
  r.dispatch({type: 'prompt', id: 'b', prompt: ask('p1')});
  for (let i = 0; i < GREET * 2; i++) r.t.tick();
  assert.ok(r.t.entities.has('b'), 'stays: it needs you now');
  assert.equal(r.t.entities.get('b').greet, 0);
});

test('each project gets a stable hue and accessory from its folder, and the label shows folder and title', () => {
  assert.deepEqual(looks('/work/a'), looks('/work/a'));
  const all = new Set(Array.from({length: 40}, (_, i) => JSON.stringify(looks(`/work/p${i}`))));
  assert.ok(all.size > 30, 'different projects look different');
  assert.ok(Array.from({length: 40}, (_, i) => looks(`/x/${i}`).accessory).every(a => ACCESSORIES.includes(a)));
  const r = rig([{...session('a', ask('p1')), cwd: '/work/a'}]);
  const a = r.t.entities.get('a');
  assert.equal(a.hue, looks('/work/a').hue);
  assert.equal(a.folder, 'proj-a'); assert.equal(a.title, 'Task a');
  r.dispatch({type: 'session', session: {id: 'a', title: 'Renamed by ai-title'}});
  assert.equal(a.title, 'Renamed by ai-title');
});

test('pick finds the character or prompt box under the pointer, for clicks and hover', () => {
  const r = rig([session('a', ask('p1'))]);
  assert.equal(r.t.pick({x: 5, y: 5}), null);
  r.settle();
  const a = r.t.entities.get('a');
  assert.equal(r.t.pick({x: a.x, y: a.y}), a);
  assert.equal(r.t.pick({x: a.box.x + 3, y: a.box.y + 3}), a);
});

test('cannon entry plays the local cue once per activation and stops on mute', () => {
  const AudioClass = globalThis.Audio; let played = 0, paused = 0;
  globalThis.Audio = class { constructor(src) { this.src = src; } play() { played++; return Promise.resolve(); } pause() { paused++; } };
  try {
    const r = rig();
    assert.equal(r.t.cue.src, 'assets/audio/little-friend.mp3');
    r.dispatch({type: 'cannon'}); assert.equal(played, 1); assert.equal(r.t.cannonEntry, 90);
    r.dispatch({type: 'fire'}); assert.equal(played, 1);
    r.dispatch({type: 'mute'}); assert.ok(paused >= 1);
    r.dispatch({type: 'mute'}); r.dispatch({type: 'cannon'}); r.dispatch({type: 'cannon'});
    assert.equal(played, 2);
  } finally { globalThis.Audio = AudioClass; }
});

test('sounds are synthesized, honour mute, and each kind keeps a minimum gap', () => {
  let nodes = 0;
  const stub = () => new Proxy(function () {}, {get: (_, k) => (k === 'then' ? undefined : stub()), apply: () => stub()});
  const audio = {state: 'running', currentTime: 0, sampleRate: 8000, destination: {}, createGain: () => stub(), createOscillator: () => { nodes++; return stub(); }, createBufferSource: () => { nodes++; return stub(); }, createBiquadFilter: () => stub(), createBuffer: (c, n) => ({getChannelData: () => new Float32Array(n)})};
  const {t} = rig(); t.audio = audio;
  for (const kind of ['ping', 'whoosh', 'warn', 'toggle', 'approve', 'crack', 'fire', 'thunk', 'tally']) {
    audio.currentTime += 5; const before = nodes;
    t.sound(kind, 1); const made = nodes - before; assert.ok(made > 0, kind);
    t.sound(kind, 1); assert.equal(nodes - before, made, `${kind} gap`);
  }
  const before = nodes; audio.currentTime += 5; t.s = {...t.s, muted: true}; t.sound('whoosh');
  assert.equal(nodes, before);
});

test('everything draws without error on a recording canvas: quiet stage, arrivals, prompts, tools, departures, Intern', () => {
  const calls = [];
  const ctx = new Proxy({}, {get: (o, k) => k in o ? o[k] : k === 'measureText' ? () => ({width: 10}) : (...a) => { calls.push(k); return {addColorStop() {}}; }, set: (o, k, v) => { o[k] = v; return true; }});
  const canvas = {width: 1600, height: 900, getContext: () => ctx, getBoundingClientRect: () => ({width: 1600, height: 900})};
  const answers = [];
  const t = new Theater(canvas, e => answers.push(e));
  let s = reduce(initial(), {type: 'sessions', sessions: [session('a')]});
  t.sync(s); t.draw();
  assert.ok(calls.includes('fillText'), 'the quiet stage says so');
  for (const kind of ['permission', 'question', 'plan', 'input']) s = reduce(s, {type: 'session', session: session(kind, ask(kind, kind))});
  for (const tool of ['whip', 'cannon', 'stamp', 'intern']) s = reduce(s, {type: tool});
  t.sync(s);
  for (let i = 0; i < 400; i++) { t.tick(); if (i % 20 === 0) { t.draw(); t.drawAutoWhipper(); } }
  t.stamp({x: 10, y: 10}); t.fire(); t.shake(10); t.draw();
  s = reduce(s, {type: 'answered', id: 'plan', prompt: 'plan'}); t.sync(s); t.draw();
  assert.ok(calls.includes('drawImage') || calls.includes('roundRect'));
});
