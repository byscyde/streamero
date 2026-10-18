import { useState } from 'react';
import { api, formatBytes, type Page } from '../api';
import { useAsync, useDebounced, useToast } from '../hooks';
import { ConfirmButton, fmtDate, Loading, Pager, StatusBadge } from '../components/ui';

export function Users({ me }: { me: any }) {
  const [q, setQ] = useState('');
  const [offset, setOffset] = useState(0);
  const dq = useDebounced(q);
  const { data, error, loading, reload } = useAsync(() => api.get<Page<any>>('/v1/admin/users', { q: dq, offset, limit: 50 }), [dq, offset]);
  const { notify, fail } = useToast();
  const update = (id: string, body: object) => api.patch(`/v1/admin/users/${id}`, body).then(() => { notify('Updated'); reload(); }).catch(fail);
  return (
    <>
      <h1>Users & roles</h1>
      <p className="muted">Roles: <b>admin</b> (everything), <b>editor</b> (catalog & ingestion), <b>user</b> (listening). Permissions are enforced by the API, not by this page.</p>
      <input value={q} onChange={(e) => { setQ(e.target.value); setOffset(0); }} placeholder="Search email or name" aria-label="Search users" />
      <Loading error={error} loading={loading && !data} retry={reload} />
      {data && (
        <div className="table-wrap" style={{ marginTop: 12 }}>
          <table>
            <thead><tr><th>User</th><th>Role</th><th>Verified</th><th>Joined</th><th>Last played</th><th>Status</th><th /></tr></thead>
            <tbody>
              {data.items.map((u) => (
                <tr key={u.id}>
                  <td className="wrap">{u.displayName}<div className="small-text">{u.email}</div></td>
                  <td>
                    <select value={u.role} disabled={u.id === me.id} aria-label={`Role for ${u.email}`} onChange={(e) => update(u.id, { role: e.target.value })}>
                      <option value="user">user</option><option value="editor">editor</option><option value="admin">admin</option>
                    </select>
                  </td>
                  <td>{u.emailVerified ? '✓' : '—'}</td>
                  <td>{fmtDate(u.createdAt)}</td>
                  <td>{fmtDate(u.lastPlayedAt)}</td>
                  <td><StatusBadge status={u.disabled ? 'disabled' : 'active'} /></td>
                  <td>
                    {u.id !== me.id && (u.disabled
                      ? <button className="small" onClick={() => update(u.id, { disabled: false })}>Enable</button>
                      : <ConfirmButton label="Disable" confirm={`Disable ${u.email}? They are signed out everywhere.`} onConfirm={() => update(u.id, { disabled: true })} />)}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <Pager page={data} onChange={setOffset} />
    </>
  );
}

export function Storage() {
  const { data, error, loading } = useAsync(() => api.get<any>('/v1/admin/storage'), []);
  return (
    <>
      <h1>Storage</h1>
      <Loading error={error} loading={loading} />
      {data && (
        <>
          <div className="grid">
            <div className="card stat"><div className="k">Total</div><div className="v">{formatBytes(data.totalBytes)}</div><div className="small-text">driver: {data.driver}</div></div>
          </div>
          <h2>By asset type</h2>
          <div className="table-wrap"><table><thead><tr><th>Kind</th><th>Assets</th><th>Size</th></tr></thead><tbody>
            {data.byKind.map((k: any) => <tr key={k.kind}><td>{k.kind}</td><td>{k.assets}</td><td>{formatBytes(k.bytes)}</td></tr>)}
          </tbody></table></div>
          <p className="small-text">Originals are kept at full quality. Deleting catalog entries removes media only when no other item references it.</p>
        </>
      )}
    </>
  );
}

export function AuditLogs() {
  const [action, setAction] = useState('');
  const [offset, setOffset] = useState(0);
  const da = useDebounced(action);
  const { data, error, loading } = useAsync(() => api.get<Page<any>>('/v1/admin/audit-logs', { action: da, offset, limit: 50 }), [da, offset]);
  return (
    <>
      <h1>Audit log</h1>
      <input value={action} onChange={(e) => { setAction(e.target.value); setOffset(0); }} placeholder="Filter by action prefix (e.g. auth., track.)" aria-label="Filter actions" />
      <Loading error={error} loading={loading && !data} />
      {data && (
        <div className="table-wrap" style={{ marginTop: 12 }}>
          <table>
            <thead><tr><th>Time</th><th>Actor</th><th>Action</th><th>Target</th><th>IP</th><th>Details</th></tr></thead>
            <tbody>
              {data.items.map((a) => (
                <tr key={a.id}>
                  <td>{fmtDate(a.createdAt)}</td><td>{a.actor ?? 'system'}</td><td><code>{a.action}</code></td>
                  <td>{a.targetType ? `${a.targetType}:${String(a.targetId).slice(0, 8)}` : '—'}</td><td>{a.ip ?? '—'}</td>
                  <td className="wrap small-text">{Object.keys(a.metadata ?? {}).length ? JSON.stringify(a.metadata) : ''}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <Pager page={data} onChange={setOffset} />
    </>
  );
}

const SECTION_KINDS = ['continue_listening', 'recently_played', 'made_for_you', 'continue_watching', 'favorite_artists', 'recently_added', 'trending', 'album_recommendations', 'music_videos', 'featured_playlists', 'genres', 'moods', 'editorial'];

export function HomeSections() {
  const { data, error, loading, setData } = useAsync(() => api.get<any[]>('/v1/admin/home-sections'), []);
  const { notify, fail } = useToast();
  const move = (i: number, d: number) => {
    if (!data) return;
    const next = [...data];
    const [x] = next.splice(i, 1);
    next.splice(Math.max(0, Math.min(next.length, i + d)), 0, x);
    setData(next);
  };
  const patch = (i: number, p: object) => setData(data!.map((s, j) => (j === i ? { ...s, ...p } : s)));
  return (
    <>
      <h1>Home feed</h1>
      <p className="muted">Sections appear in the app in this order. Empty sections are hidden automatically for each listener.</p>
      <Loading error={error} loading={loading} />
      {data && (
        <>
          <div className="table-wrap"><table><thead><tr><th>Order</th><th>Title</th><th>Kind</th><th>Enabled</th><th>Config (JSON)</th><th /></tr></thead><tbody>
            {data.map((s, i) => (
              <tr key={s.id ?? i}>
                <td className="row"><button className="small" aria-label="Move up" onClick={() => move(i, -1)}>↑</button><button className="small" aria-label="Move down" onClick={() => move(i, 1)}>↓</button></td>
                <td><input value={s.title} onChange={(e) => patch(i, { title: e.target.value })} /></td>
                <td><select value={s.kind} onChange={(e) => patch(i, { kind: e.target.value })}>{SECTION_KINDS.map((k) => <option key={k}>{k}</option>)}</select></td>
                <td><input type="checkbox" checked={s.enabled} onChange={(e) => patch(i, { enabled: e.target.checked })} aria-label="Enabled" /></td>
                <td><input defaultValue={JSON.stringify(s.config ?? {})} onBlur={(e) => { try { patch(i, { config: JSON.parse(e.target.value || '{}') }); } catch { fail(new Error('Invalid JSON')); } }} /></td>
                <td><button className="small danger" onClick={() => setData(data.filter((_, j) => j !== i))}>Remove</button></td>
              </tr>
            ))}
          </tbody></table></div>
          <div className="row" style={{ marginTop: 12 }}>
            <button onClick={() => setData([...data, { kind: 'editorial', title: 'Editor’s picks', enabled: true, config: {} }])}>Add section</button>
            <span className="spacer" />
            <button className="primary" onClick={() => api.put<any[]>('/v1/admin/home-sections', { sections: data.map(({ id, kind, title, enabled, config }) => ({ id, kind, title, enabled, config })) })
              .then((r) => { setData(r); notify('Home feed saved'); }).catch(fail)}>Save</button>
          </div>
        </>
      )}
    </>
  );
}

export function SystemHealth() {
  const { data, error, loading } = useAsync(() => api.get<any>('/v1/admin/system'), [], { pollMs: 10000 });
  const config = useAsync(() => api.get<any>('/v1/admin/config'), []);
  return (
    <>
      <h1>System health</h1>
      <Loading error={error} loading={loading && !data} />
      {data && (
        <>
          <div className="grid">
            {Object.entries(data.checks).map(([k, v]) => (
              <div className="card stat" key={k}>
                <div className="k">{k}</div>
                <div className="v">{typeof v === 'boolean' ? (v ? <span className="badge ok">healthy</span> : <span className="badge bad">down</span>) : String(v)}</div>
              </div>
            ))}
            <div className="card stat"><div className="k">API memory</div><div className="v">{data.runtime.memoryMb} MB</div><div className="small-text">Node {data.runtime.node}, up {Math.round(data.runtime.uptimeSeconds / 60)} min</div></div>
          </div>
          <h2>Queue</h2>
          <div className="row">{Object.entries(data.jobs.queue ?? {}).map(([k, v]) => <span className="badge" key={k}>{k}: {String(v)}</span>)}</div>
          <h2>Migrations</h2>
          <div className="table-wrap"><table><tbody>{data.migrations.map((m: any) => <tr key={m.name}><td>{m.name}</td><td>{fmtDate(m.applied_at)}</td></tr>)}</tbody></table></div>
        </>
      )}
      {config.data && (
        <>
          <h2>Configuration (non-secret)</h2>
          <pre className="log">{JSON.stringify(config.data, null, 2)}</pre>
        </>
      )}
    </>
  );
}

export { ConfirmButton };
