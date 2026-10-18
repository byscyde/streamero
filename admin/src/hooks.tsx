import { createContext, useCallback, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import { ApiError } from './api';

export function useAsync<T>(fn: () => Promise<T>, deps: unknown[], opts: { pollMs?: number } = {}) {
  const [data, setData] = useState<T | undefined>();
  const [error, setError] = useState<Error | undefined>();
  const [loading, setLoading] = useState(true);
  const fnRef = useRef(fn);
  fnRef.current = fn;
  const reload = useCallback(async () => {
    setLoading(true);
    try {
      setData(await fnRef.current());
      setError(undefined);
    } catch (e) {
      setError(e as Error);
    } finally {
      setLoading(false);
    }
  }, []);
  useEffect(() => {
    void reload();
    if (!opts.pollMs) return;
    const t = setInterval(() => void fnRef.current().then(setData).catch(() => {}), opts.pollMs);
    return () => clearInterval(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);
  return { data, error, loading, reload, setData };
}

interface ToastCtx {
  notify: (message: string) => void;
  fail: (err: unknown) => void;
}
const Ctx = createContext<ToastCtx>({ notify: () => {}, fail: () => {} });

export function ToastProvider({ children }: { children: ReactNode }) {
  const [msg, setMsg] = useState<string | null>(null);
  const notify = useCallback((m: string) => {
    setMsg(m);
    setTimeout(() => setMsg(null), 3500);
  }, []);
  const fail = useCallback((e: unknown) => notify(e instanceof ApiError ? `${e.message} (${e.code})` : String((e as Error)?.message ?? e)), [notify]);
  return (
    <Ctx.Provider value={{ notify, fail }}>
      {children}
      {msg && (
        <div className="toast" role="status" aria-live="polite">
          {msg}
        </div>
      )}
    </Ctx.Provider>
  );
}

export const useToast = () => useContext(Ctx);

export function useDebounced<T>(value: T, ms = 300) {
  const [v, setV] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setV(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return v;
}
