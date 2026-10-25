import { useState, type ReactNode } from 'react';
import { ApiError, type Page } from '../api';

export function Pager<T>({ page, onChange }: { page?: Page<T>; onChange: (offset: number) => void }) {
  if (!page) return null;
  const start = page.items.length ? page.offset + 1 : 0;
  return (
    <div className="pager">
      <span>
        {start}–{page.offset + page.items.length}
        {page.total !== undefined ? ` of ${page.total}` : ''}
      </span>
      <button className="small" disabled={page.offset === 0} onClick={() => onChange(Math.max(0, page.offset - page.limit))}>
        Previous
      </button>
      <button className="small" disabled={page.nextOffset === null} onClick={() => onChange(page.nextOffset ?? 0)}>
        Next
      </button>
    </div>
  );
}

/** Destructive actions always require explicit confirmation. */
export function ConfirmButton({ label, confirm, onConfirm, className = 'danger small' }: { label: string; confirm: string; onConfirm: () => Promise<void> | void; className?: string }) {
  const [busy, setBusy] = useState(false);
  return (
    <button
      className={className}
      disabled={busy}
      onClick={async () => {
        if (!window.confirm(confirm)) return;
        setBusy(true);
        try {
          await onConfirm();
        } finally {
          setBusy(false);
        }
      }}
    >
      {label}
    </button>
  );
}

export function Modal({ title, onClose, children, wide }: { title: string; onClose: () => void; children: ReactNode; wide?: boolean }) {
  return (
    <div className="modal-bg" onMouseDown={(e) => { if (e.target === e.currentTarget) onClose(); }} onKeyDown={(e) => { if (e.key === 'Escape') { e.stopPropagation(); onClose(); } }} role="dialog" aria-modal="true" aria-label={title}>
      <div className={`card modal${wide ? ' wide' : ''}`}>
        <div className="row">
          <h2 className="modal-title">{title}</h2>
          <span className="spacer" />
          <button className="small" onClick={onClose} aria-label="Close">
            ✕
          </button>
        </div>
        <div style={{ marginTop: 14 }}>{children}</div>
      </div>
    </div>
  );
}

export function StatusBadge({ status }: { status: string }) {
  const cls = ['ready', 'succeeded', 'completed', 'admin'].includes(status)
    ? 'ok'
    : ['processing', 'running', 'queued', 'editor'].includes(status)
      ? 'warn'
      : ['failed', 'cancelled', 'disabled'].includes(status)
        ? 'bad'
        : '';
  return <span className={`badge ${cls}`}>{status}</span>;
}

export function Loading({ error, loading, retry }: { error?: Error; loading: boolean; retry?: () => void }) {
  if (error)
    return (
      <p className="error">
        {error.message} {retry && <button className="small" onClick={retry}>Retry</button>}
      </p>
    );
  return loading ? <p className="muted">Loading…</p> : null;
}

export function Progress({ value }: { value: number }) {
  return (
    <div className="progress" role="progressbar" aria-valuenow={Math.round(value)} aria-valuemin={0} aria-valuemax={100}>
      <div style={{ width: `${Math.max(0, Math.min(100, value))}%` }} />
    </div>
  );
}

export const fmtDate = (d?: string | null) => (d ? new Date(d).toLocaleString() : '—');

/** Renders an API error with its code and any validation details so admins can see exactly what failed. */
export function ErrorBox({ error }: { error: unknown }) {
  if (!error) return null;
  const e = error as Error;
  const api = error instanceof ApiError ? error : null;
  const details = api?.details;
  let list: string[] = [];
  if (Array.isArray(details)) list = details.map((d) => (typeof d === 'string' ? d : d?.message ? `${d.path ? `${Array.isArray(d.path) ? d.path.join('.') : d.path}: ` : ''}${d.message}` : JSON.stringify(d)));
  else if (details && typeof details === 'object') list = Object.entries(details as Record<string, unknown>).map(([k, v]) => `${k}: ${typeof v === 'string' ? v : JSON.stringify(v)}`);
  return (
    <div className="callout danger" role="alert">
      <b>{e?.message ?? String(error)}</b>
      {api && <span className="small-text"> ({api.status} · {api.code})</span>}
      {list.length > 0 && <ul>{list.map((l, i) => <li key={i}>{l}</li>)}</ul>}
    </div>
  );
}

/** Square placeholder used where a cover image is missing or cannot be shown under the CSP. */
export function CoverPlaceholder({ size = 44 }: { size?: number }) {
  return (
    <span className="cover-ph" style={{ width: size, height: size }} aria-hidden="true">
      <svg viewBox="0 0 24 24" width={size * 0.45} height={size * 0.45}><path fill="currentColor" d="M9 17.5a2.5 2.5 0 1 1-2-2.45V5l11-2v11.5a2.5 2.5 0 1 1-2-2.45V6.4L9 7.7v9.8Z" /></svg>
    </span>
  );
}
