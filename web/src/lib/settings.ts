/** Per-device settings kept in localStorage (quality, volume, recent local searches, device id). */
import type { StreamProfile } from './types';
import { uuid } from './format';

const get = (k: string) => {
  try {
    return localStorage.getItem(k);
  } catch {
    return null;
  }
};
const set = (k: string, v: string | null) => {
  try {
    if (v === null) localStorage.removeItem(k);
    else localStorage.setItem(k, v);
  } catch {
    /* ignore */
  }
};

export const PROFILES: { id: StreamProfile; title: string; detail: string }[] = [
  { id: 'data_saver', title: 'Data Saver', detail: 'AAC up to 96 kbps' },
  { id: 'standard', title: 'Standard', detail: 'AAC up to 160 kbps' },
  { id: 'high', title: 'High', detail: 'AAC up to 256 kbps' },
  { id: 'lossless', title: 'Lossless', detail: 'When the original is lossless and your browser can decode it' },
];

export const settings = {
  get quality(): StreamProfile {
    const v = get('streamero.web.quality');
    return PROFILES.some((p) => p.id === v) ? (v as StreamProfile) : 'high';
  },
  set quality(v: StreamProfile) {
    set('streamero.web.quality', v);
  },
  get volume(): number {
    const v = Number(get('streamero.web.volume'));
    return Number.isFinite(v) && get('streamero.web.volume') !== null ? Math.max(0, Math.min(1, v)) : 0.8;
  },
  set volume(v: number) {
    set('streamero.web.volume', String(v));
  },
  get deviceId(): string {
    let id = get('streamero.web.device');
    if (!id) {
      id = `web-${uuid()}`;
      set('streamero.web.device', id);
    }
    return id;
  },
  get pendingEvents(): unknown[] {
    try {
      return JSON.parse(get('streamero.web.events') ?? '[]');
    } catch {
      return [];
    }
  },
  set pendingEvents(v: unknown[]) {
    set('streamero.web.events', v.length ? JSON.stringify(v.slice(-500)) : null);
  },
};
