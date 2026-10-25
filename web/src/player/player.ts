/**
 * Player controller: owns the queue, talks to the AudioEngine, reports listening to the API
 * (playback events, track progress, cross-device playback state) and drives the Media Session.
 */
import { api, ApiError, media } from '../lib/api';
import { loadEq, saveEq, type EqSettings } from '../lib/eq';
import { ListeningSession } from '../lib/format';
import * as Q from '../lib/queue';
import { settings } from '../lib/settings';
import type { PlaybackEvent, StreamProfile, Track, TrackStream } from '../lib/types';
import { createStore, toast, useStore } from '../state/store';
import { AudioEngine } from './engine';

export interface PlayerState {
  queue: Q.QueueState;
  playing: boolean;
  waiting: boolean;
  time: number;
  duration: number;
  buffered: number;
  volume: number;
  muted: boolean;
  eq: EqSettings;
  stream: Pick<TrackStream, 'profile' | 'delivery'> | null;
  expanded: boolean; // full-screen player open
  panel: 'none' | 'queue' | 'lyrics' | 'eq';
}

export const player = createStore<PlayerState>({
  queue: Q.emptyQueue(),
  playing: false,
  waiting: false,
  time: 0,
  duration: 0,
  buffered: 0,
  volume: settings.volume,
  muted: false,
  eq: typeof localStorage !== 'undefined' ? loadEq() : loadEq({ getItem: () => null }),
  stream: null,
  expanded: false,
  panel: 'none',
});

export const usePlayer = <T>(sel: (s: PlayerState) => T) => useStore(player, sel);
export const useCurrentTrack = () => usePlayer((s) => Q.current(s.queue)?.track ?? null);

// ---- Stream URL cache -----------------------------------------------------------------------------
const streamCache = new Map<string, { s: TrackStream; until: number }>();

async function resolveStream(track: Track): Promise<TrackStream> {
  const wanted: StreamProfile = settings.quality;
  const key = `${track.id}:${wanted}`;
  const hit = streamCache.get(key);
  if (hit && hit.until > Date.now()) return hit.s;
  let s = await api.trackStream(track.id, wanted);
  // Lossless is delivered as ALAC/FLAC which not every browser decodes: fall back to "high".
  if (engine && s.mimeType && !engine.canPlay(s.mimeType) && wanted !== 'high') s = await api.trackStream(track.id, 'high');
  const until = Math.min(Date.parse(s.expiresAt) || Date.now() + 3600_000, Date.now() + 6 * 3600_000) - 60_000;
  streamCache.set(key, { s, until });
  return s;
}

// ---- Engine ---------------------------------------------------------------------------------------
let engine: AudioEngine | null = null;
let session: ListeningSession | null = null;
let loadToken = 0;
let preloadingFor: string | null = null;
let lastProgressSave = 0;

function eng(): AudioEngine {
  if (engine) return engine;
  engine = new AudioEngine({
    onTime(time, duration, buffered) {
      player.set({ time, duration: duration || player.get().duration, buffered });
      maybePreloadNext(time, duration);
      if (player.get().playing && Date.now() - lastProgressSave > 30_000) saveProgress();
    },
    onPlaying(playing) {
      player.set({ playing });
      const now = Date.now();
      if (playing) session?.resume(now);
      else {
        session?.pause(now);
        saveProgress();
        scheduleStateSync();
      }
      updateMediaSessionState();
    },
    onWaiting(waiting) {
      player.set({ waiting });
    },
    onEnded() {
      finishSession(true);
      const next = Q.advance(player.get().queue, false);
      if (!next) {
        player.set({ playing: false, time: 0 });
        scheduleStateSync();
        return;
      }
      player.set({ queue: next });
      void startCurrent(true);
    },
    onError(message) {
      player.set({ playing: false, waiting: false });
      toast(message, 'error');
    },
  });
  const s = player.get();
  engine.setVolume(s.volume, s.muted);
  engine.setEq(s.eq);
  return engine;
}

/** Exposed for the EQ visualiser. */
export const getAnalyser = () => engine?.analyser ?? null;

async function startCurrent(autoplay: boolean, startAt = 0) {
  const item = Q.current(player.get().queue);
  const e = eng();
  if (!item) {
    e.stop();
    return;
  }
  const token = ++loadToken;
  preloadingFor = null;
  player.set({ time: startAt, duration: item.track.durationMs / 1000, waiting: autoplay, buffered: 0 });
  updateMediaSessionMetadata(item.track);
  try {
    const s = await resolveStream(item.track);
    if (token !== loadToken) return;
    player.set({ stream: { profile: s.profile, delivery: s.delivery } });
    session = new ListeningSession(item.track.id, Date.now(), player.get().queue.context);
    await e.load(item.id, media(s.url)!, startAt, autoplay);
  } catch (err) {
    if (token !== loadToken) return;
    player.set({ waiting: false, playing: false });
    toast(err instanceof ApiError && err.status === 404 ? 'This track is no longer available.' : err instanceof Error ? err.message : 'Playback failed', 'error');
  }
  scheduleStateSync();
}

function maybePreloadNext(time: number, duration: number) {
  if (!duration || duration - time > 25) return;
  const q = player.get().queue;
  const n = Q.nextIndex(q, false);
  if (n === null || n === q.currentIndex) return;
  const next = q.items[n];
  if (preloadingFor === next.id) return;
  preloadingFor = next.id;
  resolveStream(next.track)
    .then((s) => {
      if (preloadingFor === next.id) eng().preload(next.id, media(s.url)!);
    })
    .catch(() => undefined);
}

// ---- Listening reports ----------------------------------------------------------------------------
let flushTimer: ReturnType<typeof setTimeout> | null = null;

function finishSession(completed: boolean) {
  if (!session) return;
  const ev = session.finish(completed, settings.deviceId, Date.now());
  session = null;
  if (!ev) return;
  settings.pendingEvents = [...settings.pendingEvents, ev];
  if (!flushTimer) flushTimer = setTimeout(flushEvents, 2000);
}

export async function flushEvents(keepalive = false) {
  flushTimer = null;
  const pending = settings.pendingEvents as PlaybackEvent[];
  if (!pending.length || !api.hasSession) return;
  const batch = pending.slice(0, 100);
  try {
    await api.sendPlaybackEvents(batch, keepalive); // idempotent on clientEventId
    const sent = new Set(batch.map((e) => e.clientEventId));
    settings.pendingEvents = (settings.pendingEvents as PlaybackEvent[]).filter((e) => !sent.has(e.clientEventId));
  } catch (e) {
    if (e instanceof ApiError && e.status >= 400 && e.status < 500 && e.status !== 401 && e.status !== 429) settings.pendingEvents = [];
  }
}

function saveProgress(keepalive = false) {
  const item = Q.current(player.get().queue);
  if (!item || !api.hasSession) return;
  lastProgressSave = Date.now();
  const t = player.get().time;
  if (t > 5) api.saveTrackProgress(item.track.id, t * 1000, keepalive).catch(() => undefined);
}

// ---- Cross-device playback state ------------------------------------------------------------------
let stateVersion = 0;
let stateTimer: ReturnType<typeof setTimeout> | null = null;

function snapshot() {
  const s = player.get();
  const q = s.queue;
  // Same shape as the iOS PlaybackSnapshot so both clients can resume each other's queue.
  const strip = (i: Q.QueueItem) => ({ id: i.id, kind: 'track', track: i.track });
  return {
    queue: {
      items: q.items.slice(0, 300).map(strip),
      unshuffled: q.unshuffled.slice(0, 300).map(strip),
      currentIndex: q.currentIndex,
      shuffle: q.shuffle,
      repeatMode: q.repeat,
      context: q.context ?? null,
    },
    positionMs: Math.round(s.time * 1000),
    savedAt: new Date().toISOString(),
    playbackRate: 1,
  };
}

function scheduleStateSync() {
  if (stateTimer) clearTimeout(stateTimer);
  stateTimer = setTimeout(pushState, 3000);
}

async function pushState(retry = true) {
  stateTimer = null;
  if (!api.hasSession || !player.get().queue.items.length) return;
  try {
    const r = await api.putPlaybackState(snapshot(), stateVersion, settings.deviceId);
    stateVersion = r.version;
  } catch (e) {
    if (e instanceof ApiError && e.code === 'version_conflict' && retry) {
      const cur = await api.playbackState().catch(() => null);
      if (cur) {
        stateVersion = cur.version;
        await pushState(false);
      }
    }
  }
}

/** Restores the last queue from the server (paused), so playback follows the user across devices. */
export async function restorePlaybackState() {
  try {
    const r = await api.playbackState();
    stateVersion = r.version ?? 0;
    const st = r.state as { queue?: { items?: { id: string; track: Track }[]; currentIndex?: number | null; shuffle?: boolean; repeatMode?: Q.RepeatMode; context?: Q.PlaybackContext; unshuffled?: { id: string; track: Track }[] }; positionMs?: number } | null;
    const items = st?.queue?.items?.filter((i) => i?.track?.id) ?? [];
    if (!items.length || player.get().queue.items.length) return;
    const q: Q.QueueState = {
      items: items.map((i) => ({ id: i.id || Q.newEntryId(), track: i.track })),
      unshuffled: (st!.queue!.unshuffled ?? items).filter((i) => i?.track?.id).map((i) => ({ id: i.id || Q.newEntryId(), track: i.track })),
      currentIndex: Math.min(Math.max(0, st!.queue!.currentIndex ?? 0), items.length - 1),
      shuffle: !!st!.queue!.shuffle,
      repeat: (['off', 'all', 'one'] as const).includes(st!.queue!.repeatMode as Q.RepeatMode) ? st!.queue!.repeatMode! : 'off',
      context: st!.queue!.context ?? undefined,
    };
    player.set({ queue: q });
    const pos = (st!.positionMs ?? 0) / 1000;
    player.set({ time: pos, duration: Q.current(q)!.track.durationMs / 1000 });
    updateMediaSessionMetadata(Q.current(q)!.track);
    pendingRestoreAt = pos;
  } catch {
    /* nothing to restore */
  }
}
let pendingRestoreAt: number | null = null;

// ---- Media Session --------------------------------------------------------------------------------
function updateMediaSessionMetadata(t: Track) {
  if (typeof navigator === 'undefined' || !('mediaSession' in navigator)) return;
  const art = media(t.artworkUrl ?? t.album?.artworkUrl);
  navigator.mediaSession.metadata = new MediaMetadata({
    title: t.title,
    artist: t.artist.name,
    album: t.album?.title ?? '',
    artwork: art
      ? [
          { src: `${art}${art.includes('?') ? '&' : '?'}size=small`, sizes: '300x300', type: 'image/jpeg' },
          { src: `${art}${art.includes('?') ? '&' : '?'}size=large`, sizes: '1000x1000', type: 'image/jpeg' },
        ]
      : [{ src: '/icon-512.png', sizes: '512x512', type: 'image/png' }],
  });
  document.title = `${t.title} · ${t.artist.name} — STREAMERO`;
}

function updateMediaSessionState() {
  if (typeof navigator === 'undefined' || !('mediaSession' in navigator)) return;
  const s = player.get();
  navigator.mediaSession.playbackState = s.playing ? 'playing' : 'paused';
  try {
    if (s.duration) navigator.mediaSession.setPositionState({ duration: s.duration, position: Math.min(s.time, s.duration), playbackRate: 1 });
  } catch {
    /* unsupported */
  }
}

export function installMediaSession() {
  if (typeof navigator === 'undefined' || !('mediaSession' in navigator)) return;
  const ms = navigator.mediaSession;
  const set = (a: MediaSessionAction, h: MediaSessionActionHandler) => {
    try {
      ms.setActionHandler(a, h);
    } catch {
      /* unsupported action */
    }
  };
  set('play', () => void controls.play());
  set('pause', () => controls.pause());
  set('previoustrack', () => controls.previous());
  set('nexttrack', () => controls.next());
  set('seekto', (d) => d.seekTime !== undefined && controls.seek(d.seekTime));
  set('seekbackward', (d) => controls.seek(player.get().time - (d.seekOffset ?? 10)));
  set('seekforward', (d) => controls.seek(player.get().time + (d.seekOffset ?? 10)));
  set('stop', () => controls.pause());
}

// ---- Public controls ------------------------------------------------------------------------------
export const controls = {
  playTracks(tracks: Track[], startIndex = 0, context?: Q.PlaybackContext, opts: { shuffle?: boolean } = {}) {
    if (!tracks.length) return;
    finishSession(false);
    pendingRestoreAt = null;
    const q = Q.load(player.get().queue, tracks, startIndex, context, opts.shuffle);
    player.set({ queue: q });
    void startCurrent(true);
  },
  async play() {
    const s = player.get();
    if (!Q.current(s.queue)) return;
    if (pendingRestoreAt !== null || !eng().element.src) {
      const at = pendingRestoreAt ?? s.time;
      pendingRestoreAt = null;
      await startCurrent(true, at);
      return;
    }
    await eng().play();
  },
  pause() {
    engine?.pause();
  },
  toggle() {
    if (player.get().playing) controls.pause();
    else void controls.play();
  },
  next() {
    const q = player.get().queue;
    const n = Q.advance(q, true);
    if (!n) return;
    finishSession(false);
    pendingRestoreAt = null;
    player.set({ queue: n });
    void startCurrent(true);
  },
  previous() {
    const s = player.get();
    const a = Q.previousAction(s.queue, s.time);
    if (a.kind === 'restart') {
      controls.seek(0);
      return;
    }
    finishSession(false);
    pendingRestoreAt = null;
    player.set({ queue: Q.jump(s.queue, a.index) });
    void startCurrent(true);
  },
  jumpTo(index: number) {
    finishSession(false);
    pendingRestoreAt = null;
    player.set({ queue: Q.jump(player.get().queue, index) });
    void startCurrent(true);
  },
  seek(t: number) {
    const s = player.get();
    const clamped = Math.max(0, Math.min(t, s.duration || t));
    if (pendingRestoreAt !== null) pendingRestoreAt = clamped;
    else engine?.seek(clamped);
    player.set({ time: clamped });
    updateMediaSessionState();
  },
  setVolume(v: number) {
    const volume = Math.max(0, Math.min(1, v));
    settings.volume = volume;
    player.set({ volume, muted: volume === 0 ? player.get().muted : false });
    eng().setVolume(volume, player.get().muted);
  },
  toggleMute() {
    const muted = !player.get().muted;
    player.set({ muted });
    eng().setVolume(player.get().volume, muted);
  },
  toggleShuffle() {
    player.set((s) => ({ queue: Q.setShuffle(s.queue, !s.queue.shuffle) }));
    engine?.clearPreload();
    preloadingFor = null;
    scheduleStateSync();
  },
  cycleRepeat() {
    player.set((s) => ({ queue: { ...s.queue, repeat: Q.nextRepeat(s.queue.repeat) } }));
    engine?.clearPreload();
    preloadingFor = null;
    scheduleStateSync();
  },
  playNext(tracks: Track[]) {
    const empty = !Q.current(player.get().queue);
    player.set((s) => ({ queue: Q.playNext(s.queue, tracks) }));
    if (empty) void startCurrent(true);
    else toast(tracks.length === 1 ? `“${tracks[0].title}” will play next` : `${tracks.length} tracks will play next`);
    preloadingFor = null;
    engine?.clearPreload();
    scheduleStateSync();
  },
  addToQueue(tracks: Track[]) {
    const empty = !Q.current(player.get().queue);
    player.set((s) => ({ queue: Q.append(s.queue, tracks) }));
    if (empty) void startCurrent(true);
    else toast(tracks.length === 1 ? `Added “${tracks[0].title}” to the queue` : `Added ${tracks.length} tracks to the queue`);
    scheduleStateSync();
  },
  removeFromQueue(itemId: string) {
    const before = Q.current(player.get().queue)?.id;
    player.set((s) => ({ queue: Q.remove(s.queue, itemId) }));
    preloadingFor = null;
    engine?.clearPreload();
    if (before === itemId) void startCurrent(player.get().playing);
    scheduleStateSync();
  },
  moveInQueue(from: number, to: number) {
    player.set((s) => ({ queue: Q.move(s.queue, from, to) }));
    preloadingFor = null;
    engine?.clearPreload();
    scheduleStateSync();
  },
  clearUpNext() {
    player.set((s) => ({ queue: Q.clearUpNext(s.queue) }));
    engine?.clearPreload();
    scheduleStateSync();
  },
  updateTrack(t: Track) {
    player.set((s) => ({ queue: Q.updateTrack(s.queue, t) }));
  },
  setEq(eq: EqSettings) {
    saveEq(eq);
    player.set({ eq });
    eng().setEq(eq);
  },
  setExpanded(expanded: boolean) {
    player.set({ expanded });
  },
  togglePanel(panel: PlayerState['panel']) {
    player.set((s) => ({ panel: s.panel === panel ? 'none' : panel }));
  },
  /** Stops everything (sign-out). */
  reset() {
    finishSession(false);
    engine?.stop();
    player.set({ queue: Q.emptyQueue(), playing: false, time: 0, duration: 0, stream: null, expanded: false, panel: 'none' });
    document.title = 'STREAMERO';
  },
  /** Quality changed in settings: drop cached URLs so the next track uses the new profile. */
  invalidateStreams() {
    streamCache.clear();
    engine?.clearPreload();
    preloadingFor = null;
  },
};

if (typeof window !== 'undefined') {
  window.addEventListener('pagehide', () => {
    finishSession(false);
    saveProgress(true);
    void flushEvents(true); // events stay queued in localStorage until acknowledged
  });
  setInterval(() => void flushEvents(), 30_000);
}
