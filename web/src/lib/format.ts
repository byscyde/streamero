import type { PlaybackEvent } from './types';

export function formatTime(seconds: number): string {
  if (!Number.isFinite(seconds) || seconds < 0) seconds = 0;
  const s = Math.floor(seconds);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const ss = String(s % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${ss}` : `${m}:${ss}`;
}

export const formatMs = (ms: number) => formatTime(ms / 1000);

export function formatDuration(ms: number): string {
  const min = Math.round(ms / 60000);
  if (min < 60) return `${min} min`;
  return `${Math.floor(min / 60)} h ${min % 60} min`;
}

export function compactNumber(n: number | null | undefined): string {
  if (!n) return '0';
  if (n < 1000) return String(n);
  const units = [
    [1e9, 'B'],
    [1e6, 'M'],
    [1e3, 'K'],
  ] as const;
  for (const [v, u] of units) if (n >= v) return `${(n / v).toFixed(n / v < 10 ? 2 : n / v < 100 ? 1 : 0).replace(/(\.\d*?)0+$/, '$1').replace(/\.$/, '')}${u}`;
  return String(n);
}

export const plural = (n: number, one: string, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;

export function greetingFor(hour: number, name?: string | null) {
  const g = hour < 5 ? 'Good night' : hour < 12 ? 'Good morning' : hour < 18 ? 'Good afternoon' : 'Good evening';
  return name ? `${g}, ${name}` : g;
}

export const uuid = () =>
  typeof crypto !== 'undefined' && 'randomUUID' in crypto
    ? crypto.randomUUID()
    : 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
        const r = (Math.random() * 16) | 0;
        return (c === 'x' ? r : (r & 0x3) | 0x8).toString(16);
      });

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Measures real listening time of one item (pauses/seeks excluded) — port of ListeningSession. */
export class ListeningSession {
  private accumulated = 0;
  private runningSince: number | null = null;
  constructor(
    readonly trackId: string,
    readonly startedAt: number,
    readonly context?: { type: string; id?: string },
  ) {}
  resume(at: number) {
    if (this.runningSince === null) this.runningSince = at;
  }
  pause(at: number) {
    if (this.runningSince !== null) {
      this.accumulated += Math.max(0, at - this.runningSince);
      this.runningSince = null;
    }
  }
  listenedMs(at: number) {
    return this.accumulated + (this.runningSince !== null ? Math.max(0, at - this.runningSince) : 0);
  }
  /** null for plays shorter than 1 s (accidental clicks) to keep history clean. */
  finish(completed: boolean, deviceId: string, at: number): PlaybackEvent | null {
    const ms = Math.round(this.listenedMs(at));
    if (ms < 1000 && !completed) return null;
    const ctxId = this.context?.id && UUID_RE.test(this.context.id) ? this.context.id : undefined;
    return {
      clientEventId: uuid(),
      trackId: this.trackId,
      playedAt: new Date(this.startedAt).toISOString(),
      durationPlayedMs: ms,
      completed,
      contextType: this.context?.type,
      contextId: ctxId,
      deviceId,
    };
  }
}

/** Which data to refetch after a sync poll; the first poll only records the baseline. */
export function syncDiff(prev: Record<string, string | undefined> | null, cur: Record<string, string | undefined>) {
  const changed = (k: string) => !!prev && prev[k] !== cur[k];
  return { catalog: changed('catalogVersion'), library: changed('libraryVersion'), config: !!prev && !!cur.configVersion && changed('configVersion') };
}
