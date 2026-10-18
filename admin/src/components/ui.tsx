import { useState, type ReactNode } from 'react';
import type { Page } from '../api';

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

export function Modal({ title, onClose, children }: { title: string; onClose: () => void; children: ReactNode }) {
  return (
    <div className="modal-bg" onClick={onClose} role="dialog" aria-modal="true" aria-label={title}>
      <div className="card modal" onClick={(e) => e.stopPropagation()}>
        <div className="row">
          <h2 style={{ margin: 0 }}>{title}</h2>
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
