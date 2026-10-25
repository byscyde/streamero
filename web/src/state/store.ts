import { useSyncExternalStore } from 'react';

/** Minimal external store with selector subscriptions (no extra dependency). */
export function createStore<S>(initial: S) {
  let state = initial;
  const listeners = new Set<() => void>();
  return {
    get: () => state,
    set(patch: Partial<S> | ((s: S) => Partial<S>)) {
      const p = typeof patch === 'function' ? (patch as (s: S) => Partial<S>)(state) : patch;
      state = { ...state, ...p };
      listeners.forEach((l) => l());
    },
    subscribe(l: () => void) {
      listeners.add(l);
      return () => listeners.delete(l);
    },
  };
}

export type Store<S> = ReturnType<typeof createStore<S>>;

export function useStore<S, T>(store: Store<S>, selector: (s: S) => T): T {
  return useSyncExternalStore(store.subscribe, () => selector(store.get()), () => selector(store.get()));
}

// ---- Toasts -------------------------------------------------------------------------------------
export interface Toast {
  id: number;
  text: string;
  kind: 'info' | 'error' | 'success';
}
export const toasts = createStore<{ items: Toast[] }>({ items: [] });
let toastSeq = 0;
export function toast(text: string, kind: Toast['kind'] = 'info') {
  const id = ++toastSeq;
  toasts.set((s) => ({ items: [...s.items.slice(-3), { id, text, kind }] }));
  setTimeout(() => toasts.set((s) => ({ items: s.items.filter((t) => t.id !== id) })), 3800);
}
export const errorText = (e: unknown) => (e instanceof Error ? e.message : 'Something went wrong');
