/** Pure playback queue state machine (port of StreameroCore/PlaybackQueue.swift). Immutable updates. */
import type { Track } from './types';

export type RepeatMode = 'off' | 'all' | 'one';
export const nextRepeat = (m: RepeatMode): RepeatMode => (m === 'off' ? 'all' : m === 'all' ? 'one' : 'off');

export interface QueueItem {
  id: string; // unique per entry so a track may appear twice
  track: Track;
}

export interface PlaybackContext {
  type: string; // album, playlist, artist, mix, search, liked, radio, genre, history, queue
  id?: string;
  title?: string;
}

export interface QueueState {
  items: QueueItem[];
  unshuffled: QueueItem[];
  currentIndex: number | null;
  shuffle: boolean;
  repeat: RepeatMode;
  context?: PlaybackContext;
}

export const emptyQueue = (): QueueState => ({ items: [], unshuffled: [], currentIndex: null, shuffle: false, repeat: 'off' });

let seq = 0;
export const newEntryId = () => `q${Date.now().toString(36)}${(seq++).toString(36)}${Math.random().toString(36).slice(2, 6)}`;
const entries = (tracks: Track[]) => tracks.map((track) => ({ id: newEntryId(), track }));

export type Rng = () => number;

/** Fisher–Yates with an injectable RNG (deterministic in tests). */
export function shuffled<T>(arr: T[], rng: Rng = Math.random): T[] {
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

export const current = (q: QueueState): QueueItem | null =>
  q.currentIndex !== null && q.currentIndex < q.items.length ? q.items[q.currentIndex] : null;
export const upNext = (q: QueueState): QueueItem[] => (q.currentIndex === null ? [] : q.items.slice(q.currentIndex + 1));

/** Replaces the queue. With shuffle on, `startAt` stays first and the rest is shuffled. */
export function load(q: QueueState, tracks: Track[], startAt = 0, context?: PlaybackContext, shuffle?: boolean, rng?: Rng): QueueState {
  const items = entries(tracks);
  const base: QueueState = {
    ...q,
    items,
    unshuffled: items,
    context,
    shuffle: false,
    currentIndex: items.length ? Math.min(Math.max(0, startAt), items.length - 1) : null,
  };
  return (shuffle ?? q.shuffle) ? setShuffle(base, true, rng) : base;
}

export function setShuffle(q: QueueState, on: boolean, rng: Rng = Math.random): QueueState {
  if (on === q.shuffle) return q;
  const cur = current(q);
  if (on) {
    const rest = q.items.filter((_, i) => i !== q.currentIndex);
    const items = [...(cur ? [cur] : []), ...shuffled(rest, rng)];
    return { ...q, shuffle: true, unshuffled: q.items, items, currentIndex: cur ? 0 : null };
  }
  const present = new Set(q.items.map((i) => i.id));
  const restored = q.unshuffled.filter((i) => present.has(i.id));
  const known = new Set(restored.map((i) => i.id));
  const items = [...restored, ...q.items.filter((i) => !known.has(i.id))];
  return { ...q, shuffle: false, items, currentIndex: cur ? items.findIndex((i) => i.id === cur.id) : null };
}

/** Index that follows the current one, honouring repeat. User skips ignore repeat-one. */
export function nextIndex(q: QueueState, userInitiated: boolean): number | null {
  if (q.currentIndex === null || !q.items.length) return null;
  if (q.repeat === 'one' && !userInitiated) return q.currentIndex;
  if (q.currentIndex + 1 < q.items.length) return q.currentIndex + 1;
  return q.repeat === 'off' ? null : 0;
}

export function advance(q: QueueState, userInitiated: boolean): QueueState | null {
  const n = nextIndex(q, userInitiated);
  return n === null ? null : { ...q, currentIndex: n };
}

export type PreviousAction = { kind: 'restart' } | { kind: 'moveTo'; index: number };

/** After 3 s "previous" restarts the track, otherwise goes back. */
export function previousAction(q: QueueState, position: number): PreviousAction {
  const i = q.currentIndex;
  if (i === null || position > 3) return { kind: 'restart' };
  if (i > 0) return { kind: 'moveTo', index: i - 1 };
  if (q.repeat === 'all' && q.items.length > 1) return { kind: 'moveTo', index: q.items.length - 1 };
  return { kind: 'restart' };
}

export const jump = (q: QueueState, index: number): QueueState => (index >= 0 && index < q.items.length ? { ...q, currentIndex: index } : q);

export function playNext(q: QueueState, tracks: Track[]): QueueState {
  const add = entries(tracks);
  const at = (q.currentIndex ?? -1) + 1;
  const items = [...q.items.slice(0, at), ...add, ...q.items.slice(at)];
  const cur = current(q);
  const ui = cur ? q.unshuffled.findIndex((i) => i.id === cur.id) : -1;
  const unshuffled = [...q.unshuffled.slice(0, ui + 1), ...add, ...q.unshuffled.slice(ui + 1)];
  return { ...q, items, unshuffled, currentIndex: q.currentIndex ?? (items.length ? 0 : null) };
}

export function append(q: QueueState, tracks: Track[]): QueueState {
  const add = entries(tracks);
  const items = [...q.items, ...add];
  return { ...q, items, unshuffled: [...q.unshuffled, ...add], currentIndex: q.currentIndex ?? (items.length ? 0 : null) };
}

/** Removes an entry. Removing the current entry makes the following one current. */
export function remove(q: QueueState, itemId: string): QueueState {
  const i = q.items.findIndex((x) => x.id === itemId);
  if (i < 0) return q;
  const items = q.items.filter((x) => x.id !== itemId);
  const unshuffled = q.unshuffled.filter((x) => x.id !== itemId);
  let c = q.currentIndex;
  if (c !== null) {
    if (!items.length) c = null;
    else if (i < c) c = c - 1;
    else if (i === c) c = Math.min(c, items.length - 1);
  }
  return { ...q, items, unshuffled, currentIndex: c };
}

/** Moves an entry; indices are absolute queue positions. */
export function move(q: QueueState, from: number, to: number): QueueState {
  if (from === to || from < 0 || to < 0 || from >= q.items.length || to >= q.items.length) return q;
  const cur = current(q);
  const items = q.items.slice();
  const [it] = items.splice(from, 1);
  items.splice(to, 0, it);
  return { ...q, items, currentIndex: cur ? items.findIndex((x) => x.id === cur.id) : q.currentIndex };
}

export function clearUpNext(q: QueueState): QueueState {
  if (q.currentIndex === null) return q;
  const removed = new Set(q.items.slice(q.currentIndex + 1).map((x) => x.id));
  return { ...q, items: q.items.slice(0, q.currentIndex + 1), unshuffled: q.unshuffled.filter((x) => !removed.has(x.id)) };
}

export function updateTrack(q: QueueState, track: Track): QueueState {
  const f = (x: QueueItem) => (x.track.id === track.id ? { ...x, track } : x);
  return { ...q, items: q.items.map(f), unshuffled: q.unshuffled.map(f) };
}
