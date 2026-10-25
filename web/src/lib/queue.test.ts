import { describe, expect, it } from 'vitest';
import * as Q from './queue';
import type { Track } from './types';

const tr = (id: string): Track => ({ id, title: id, durationMs: 1000, explicit: false, genres: [], moods: [], artist: { id: 'a', name: 'A' }, isLiked: false, hasLyrics: false });
const tracks = ['a', 'b', 'c', 'd', 'e'].map(tr);
const ids = (q: Q.QueueState) => q.items.map((i) => i.track.id);

/** Deterministic RNG (mulberry32). */
function rng(seed: number) {
  return () => {
    seed |= 0;
    seed = (seed + 0x6d2b79f5) | 0;
    let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

describe('queue', () => {
  it('loads and advances, stopping at the end with repeat off', () => {
    let q = Q.load(Q.emptyQueue(), tracks, 3);
    expect(Q.current(q)!.track.id).toBe('d');
    expect(Q.upNext(q).map((i) => i.track.id)).toEqual(['e']);
    q = Q.advance(q, false)!;
    expect(Q.current(q)!.track.id).toBe('e');
    expect(Q.advance(q, false)).toBeNull();
  });

  it('honours repeat all and repeat one (user skips ignore repeat one)', () => {
    let q: Q.QueueState = { ...Q.load(Q.emptyQueue(), tracks, 4), repeat: 'all' };
    expect(Q.nextIndex(q, false)).toBe(0);
    q = { ...q, repeat: 'one' };
    expect(Q.nextIndex(q, false)).toBe(4);
    expect(Q.nextIndex(q, true)).toBe(0); // a user skip at the end wraps around (repeat is on)
    expect(Q.nextRepeat('off')).toBe('all');
    expect(Q.nextRepeat('all')).toBe('one');
    expect(Q.nextRepeat('one')).toBe('off');
  });

  it('shuffle keeps the current track first, contains every track and restores order', () => {
    const q0 = Q.load(Q.emptyQueue(), tracks, 2);
    const s = Q.setShuffle(q0, true, rng(42));
    expect(Q.current(s)!.track.id).toBe('c');
    expect(s.currentIndex).toBe(0);
    expect([...ids(s)].sort()).toEqual(['a', 'b', 'c', 'd', 'e']);
    expect(ids(s)).not.toEqual(['c', 'a', 'b', 'd', 'e']); // seed produces a real permutation
    const off = Q.setShuffle(Q.advance(s, true)!, false);
    expect(ids(off)).toEqual(['a', 'b', 'c', 'd', 'e']);
    expect(Q.current(off)!.track.id).toBe(ids(s)[1]);
  });

  it('shuffled() is a deterministic permutation for a seeded RNG', () => {
    expect(Q.shuffled([1, 2, 3, 4, 5, 6], rng(1))).toEqual(Q.shuffled([1, 2, 3, 4, 5, 6], rng(1)));
    expect(Q.shuffled([1, 2, 3, 4, 5, 6], rng(7)).sort()).toEqual([1, 2, 3, 4, 5, 6]);
  });

  it('keeps entries added while shuffled when shuffle is turned off', () => {
    let q = Q.setShuffle(Q.load(Q.emptyQueue(), tracks, 0), true, rng(3));
    q = Q.append(q, [tr('z')]);
    q = Q.setShuffle(q, false);
    expect(ids(q)).toEqual(['a', 'b', 'c', 'd', 'e', 'z']);
  });

  it('previous restarts after 3 s, otherwise goes back (wrapping with repeat all)', () => {
    const q = Q.load(Q.emptyQueue(), tracks, 1);
    expect(Q.previousAction(q, 10)).toEqual({ kind: 'restart' });
    expect(Q.previousAction(q, 1)).toEqual({ kind: 'moveTo', index: 0 });
    const first = Q.jump(q, 0);
    expect(Q.previousAction(first, 1)).toEqual({ kind: 'restart' });
    expect(Q.previousAction({ ...first, repeat: 'all' }, 1)).toEqual({ kind: 'moveTo', index: 4 });
  });

  it('play next inserts after the current entry; add to queue appends', () => {
    let q = Q.load(Q.emptyQueue(), tracks, 1);
    q = Q.playNext(q, [tr('x')]);
    q = Q.append(q, [tr('y')]);
    expect(ids(q)).toEqual(['a', 'b', 'x', 'c', 'd', 'e', 'y']);
    expect(Q.current(q)!.track.id).toBe('b');
    const fresh = Q.append(Q.emptyQueue(), [tr('k')]);
    expect(fresh.currentIndex).toBe(0);
  });

  it('removes and moves entries while keeping the current one', () => {
    let q = Q.load(Q.emptyQueue(), tracks, 2);
    q = Q.remove(q, q.items[0].id);
    expect(Q.current(q)!.track.id).toBe('c');
    expect(q.currentIndex).toBe(1);
    q = Q.remove(q, Q.current(q)!.id); // removing current → next becomes current
    expect(Q.current(q)!.track.id).toBe('d');
    q = Q.move(q, 2, 0);
    expect(ids(q)).toEqual(['e', 'b', 'd']);
    expect(Q.current(q)!.track.id).toBe('d');
    q = Q.clearUpNext(q);
    expect(ids(q)).toEqual(['e', 'b', 'd']);
    q = Q.clearUpNext(Q.jump(q, 0));
    expect(ids(q)).toEqual(['e']);
  });

  it('allows the same track twice with distinct entry ids', () => {
    const q = Q.load(Q.emptyQueue(), [tr('a'), tr('a')]);
    expect(q.items[0].id).not.toBe(q.items[1].id);
    const u = Q.updateTrack(q, { ...tr('a'), isLiked: true });
    expect(u.items.every((i) => i.track.isLiked)).toBe(true);
  });
});
