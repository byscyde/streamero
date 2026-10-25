import { useEffect, useRef, useState } from 'react';
import { api, ApiError, REFRESH_KEY } from '../lib/api';
import { applyConfig, DEFAULT_CONFIG, mergeConfig, type AppConfig } from '../lib/appearance';
import { syncDiff } from '../lib/format';
import type { LibraryIds, LibraryItemType, Playlist, User } from '../lib/types';
import { controls, flushEvents, restorePlaybackState } from '../player/player';
import { createStore, toast, useStore } from './store';

export type AuthState = 'loading' | 'signedOut' | 'signedIn';

interface Lib {
  track: Set<string>;
  album: Set<string>;
  artist: Set<string>;
  video: Set<string>;
  playlist: Set<string>;
}

export interface AppState {
  config: AppConfig;
  auth: AuthState;
  user: User | null;
  library: Lib;
  playlists: Playlist[];
  catalogTick: number; // bumped when /v1/sync/state reports catalog changes → visible screens refetch
  libraryTick: number;
}

const emptyLib = (): Lib => ({ track: new Set(), album: new Set(), artist: new Set(), video: new Set(), playlist: new Set() });

const CONFIG_CACHE = 'streamero.web.config';
function cachedConfig(): AppConfig {
  try {
    const raw = localStorage.getItem(CONFIG_CACHE);
    return raw ? mergeConfig(JSON.parse(raw)) : DEFAULT_CONFIG;
  } catch {
    return DEFAULT_CONFIG;
  }
}

export const app = createStore<AppState>({
  config: typeof localStorage !== 'undefined' ? cachedConfig() : DEFAULT_CONFIG,
  auth: 'loading',
  user: null,
  library: emptyLib(),
  playlists: [],
  catalogTick: 0,
  libraryTick: 0,
});

export const useApp = <T>(sel: (s: AppState) => T) => useStore(app, sel);
export const useConfig = () => useApp((s) => s.config);
export const useUser = () => useApp((s) => s.user);

// ---- Config ---------------------------------------------------------------------------------------
export async function loadConfig() {
  try {
    const c = mergeConfig(await api.appConfig());
    try {
      localStorage.setItem(CONFIG_CACHE, JSON.stringify(c));
    } catch {
      /* ignore */
    }
    applyConfig(c);
    app.set({ config: c });
  } catch {
    /* keep cached/default config (endpoint may be unavailable on older servers) */
  }
}

// ---- Auth -----------------------------------------------------------------------------------------
export async function bootstrap() {
  applyConfig(app.get().config);
  void loadConfig();
  api.onSessionExpired = () => {
    signedOutLocally();
    toast('Your session has ended. Please sign in again.');
  };
  // Another tab signed out (refresh token removed) → follow.
  window.addEventListener('storage', (e) => {
    if (e.key === REFRESH_KEY && !e.newValue && app.get().auth === 'signedIn') signedOutLocally();
  });
  if (!api.hasSession) {
    app.set({ auth: 'signedOut' });
    return;
  }
  try {
    const user = await api.me();
    await signedIn(user);
  } catch (e) {
    if (e instanceof ApiError && e.isNetwork) {
      app.set({ auth: 'signedOut' });
      toast(e.message, 'error');
    } else app.set({ auth: 'signedOut' });
  }
}

export async function signedIn(user: User) {
  app.set({ user, auth: 'signedIn' });
  void refreshLibrary();
  void restorePlaybackState();
  void flushEvents();
}

function signedOutLocally() {
  controls.reset();
  app.set({ auth: 'signedOut', user: null, library: emptyLib(), playlists: [] });
}

export async function signOut(everywhere = false) {
  try {
    if (everywhere) await api.logoutAll();
    else await api.logout();
  } catch (e) {
    toast(e instanceof Error ? e.message : 'Sign out failed', 'error');
    if (everywhere) return;
  }
  signedOutLocally();
}

export const setUser = (user: User) => app.set({ user });

// ---- Library --------------------------------------------------------------------------------------
export async function refreshLibrary() {
  const [ids, pls] = await Promise.all([api.libraryIds().catch(() => null as LibraryIds | null), api.myPlaylists(100).catch(() => null)]);
  app.set((s) => ({
    library: ids
      ? { track: new Set(ids.tracks), album: new Set(ids.albums), artist: new Set(ids.artists), video: new Set(ids.videos), playlist: new Set(ids.playlists) }
      : s.library,
    playlists: pls ? pls.items : s.playlists,
  }));
}

export const refreshPlaylists = async () => {
  const pls = await api.myPlaylists(100).catch(() => null);
  if (pls) app.set({ playlists: pls.items });
};

export const useSaved = (type: LibraryItemType, id: string | undefined) => useApp((s) => (id ? s.library[type].has(id) : false));

/** Optimistic like/save/follow; rolls back on failure. */
export async function toggleSaved(type: LibraryItemType, id: string, label?: string) {
  const was = app.get().library[type].has(id);
  const apply = (on: boolean) =>
    app.set((s) => {
      const set = new Set(s.library[type]);
      if (on) set.add(id);
      else set.delete(id);
      return { library: { ...s.library, [type]: set } };
    });
  apply(!was);
  try {
    await api.setSaved(type, id, !was);
    const verb = { track: ['Added to Liked Songs', 'Removed from Liked Songs'], album: ['Album saved', 'Album removed'], artist: ['Following', 'Unfollowed'], video: ['Added to Liked Videos', 'Removed from Liked Videos'], playlist: ['Playlist saved', 'Playlist removed'] }[type];
    toast(label ? `${!was ? verb[0] : verb[1]}${type === 'artist' ? ` ${label}` : ''}` : !was ? verb[0] : verb[1], 'success');
    if (type === 'playlist') void refreshPlaylists();
  } catch (e) {
    apply(was);
    toast(e instanceof Error ? e.message : 'Could not update your library', 'error');
  }
}

// ---- Sync polling (/v1/sync/state every 30 s while visible, and on focus) --------------------------
let lastSync: Record<string, string | undefined> | null = null;
let polling = false;

export async function pollSync() {
  if (polling) return;
  polling = true;
  try {
    if (app.get().auth !== 'signedIn') {
      await loadConfig(); // public endpoint; keeps the welcome screen current
      return;
    }
    const s = await api.syncState();
    const cur = { catalogVersion: s.catalogVersion, libraryVersion: s.libraryVersion, configVersion: s.configVersion };
    const d = syncDiff(lastSync, cur);
    lastSync = cur;
    // configVersion equals the config document's version (docs/APP_CONFIG.md): refetch when they differ.
    if (d.config || (s.configVersion && s.configVersion !== app.get().config.version)) await loadConfig();
    if (d.catalog) app.set((x) => ({ catalogTick: x.catalogTick + 1 }));
    if (d.library) {
      await refreshLibrary();
      app.set((x) => ({ libraryTick: x.libraryTick + 1 }));
    }
  } catch {
    /* offline: try again next tick */
  } finally {
    polling = false;
  }
}

export function startSyncPolling() {
  const tick = () => {
    if (document.visibilityState === 'visible') void pollSync();
  };
  const id = setInterval(tick, 30_000);
  window.addEventListener('focus', tick);
  document.addEventListener('visibilitychange', tick);
  return () => {
    clearInterval(id);
    window.removeEventListener('focus', tick);
    document.removeEventListener('visibilitychange', tick);
  };
}

// ---- Data hook ------------------------------------------------------------------------------------
export interface Loadable<T> {
  data: T | undefined;
  error: Error | undefined;
  loading: boolean;
  reload: () => void;
  setData: (fn: (d: T | undefined) => T | undefined) => void;
}

/**
 * Loads data and refetches when deps change or when the sync poll reports catalog/library changes
 * (`watch`), so visible screens stay fresh without a reload.
 */
export function useLoad<T>(fn: () => Promise<T>, deps: unknown[], watch: 'catalog' | 'library' | 'both' | 'none' = 'both'): Loadable<T> {
  const tick = useApp((s) => (watch === 'none' ? 0 : watch === 'catalog' ? s.catalogTick : watch === 'library' ? s.libraryTick : s.catalogTick * 100000 + s.libraryTick));
  const [state, setState] = useState<{ data?: T; error?: Error; loading: boolean }>({ loading: true });
  const [n, setN] = useState(0);
  const fnRef = useRef(fn);
  fnRef.current = fn;
  const firstDeps = useRef<string>('');
  useEffect(() => {
    let alive = true;
    const key = JSON.stringify(deps);
    const depsChanged = key !== firstDeps.current;
    firstDeps.current = key;
    // Background refreshes (sync tick) keep showing current data; navigation shows a loader.
    if (depsChanged) setState({ loading: true });
    fnRef
      .current()
      .then((data) => alive && setState({ data, loading: false }))
      .catch((error) => alive && setState((s) => ({ data: depsChanged ? undefined : s.data, error, loading: false })));
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick, n]);
  return {
    data: state.data,
    error: state.error,
    loading: state.loading,
    reload: () => setN((x) => x + 1),
    setData: (f) => setState((s) => ({ ...s, data: f(s.data) })),
  };
}
