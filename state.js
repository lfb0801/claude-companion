// Companion state: which tools are armed, and the sessions the stage shows.
// A session is {id, folder, title, prompt}. prompt is null, or {id, kind, text, detail} while the
// session needs you (kind: 'permission' | 'question' | 'plan' | 'input').
export const TOOLS = ['whip', 'cannon', 'stamp', 'intern'];

export const initial = () => ({whip: false, cannon: false, stamp: false, intern: false, muted: false, crack: 0, fire: 0, sessions: []});

const withSession = (s, id, fn) => ({...s, sessions: s.sessions.map(x => x.id === id ? fn(x) : x)});

export function reduce(s, action) {
  switch (action.type) {
    case 'whip': case 'cannon': case 'stamp': case 'intern':
      return {...s, [action.type]: !s[action.type]};
    case 'mute': return {...s, muted: !s.muted};
    case 'crack': return s.whip ? {...s, crack: s.crack + 1} : s;
    case 'fire': return s.cannon ? {...s, fire: s.fire + 1} : s;
    case 'sessions': return {...s, sessions: action.sessions.map(x => ({prompt: null, ...x}))};
    case 'session': {
      const rest = s.sessions.filter(x => x.id !== action.session.id);
      const old = s.sessions.find(x => x.id === action.session.id);
      return {...s, sessions: old ? s.sessions.map(x => x === old ? {...old, ...action.session} : x) : [...rest, {prompt: null, ...action.session}]};
    }
    case 'end': return {...s, sessions: s.sessions.filter(x => x.id !== action.id)};
    case 'prompt': return withSession(s, action.id, x => ({...x, prompt: action.prompt}));
    // Only the first answer to a prompt counts: a stale prompt id changes nothing.
    case 'answered': return withSession(s, action.id, x => x.prompt?.id === action.prompt ? {...x, prompt: null} : x);
    case 'reset': return {...initial(), muted: s.muted, sessions: s.sessions};
    default: return s;
  }
}
