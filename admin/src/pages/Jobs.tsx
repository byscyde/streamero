import { useState } from 'react';
import { Link, useParams, useSearchParams } from 'react-router-dom';
import { api, type Page } from '../api';
import { useAsync, useToast } from '../hooks';
import { fmtDate, Loading, Pager, Progress, StatusBadge } from '../components/ui';

export function Jobs() {
  const [params, setParams] = useSearchParams();
  const status = params.get('status') ?? '';
  const [offset, setOffset] = useState(0);
  const { data, error, loading, reload } = useAsync(() => api.get<Page<any>>('/v1/admin/jobs', { status, offset, limit: 30 }), [status, offset], { pollMs: 4000 });
  const { fail, notify } = useToast();
  return (
    <>
      <div className="row">
        <h1>Processing queue</h1>
        <span className="spacer" />
        <select value={status} onChange={(e) => { setOffset(0); setParams(e.target.value ? { status: e.target.value } : {}); }} aria-label="Filter by status">
          <option value="">All statuses</option>
          {['queued', 'running', 'succeeded', 'failed', 'cancelled'].map((s) => <option key={s}>{s}</option>)}
        </select>
      </div>
      <Loading error={error} loading={loading && !data} retry={reload} />
      {data && (
        <div className="table-wrap">
          <table>
            <thead><tr><th>Job</th><th>Type</th><th>Status</th><th>Progress</th><th>Attempts</th><th>Created</th><th /></tr></thead>
            <tbody>
              {data.items.map((j) => (
                <tr key={j.id}>
                  <td className="wrap"><Link to={`/jobs/${j.id}`}>{j.filename ?? j.id.slice(0, 8)}</Link>{j.error && <div className="error small-text">{j.error.slice(0, 120)}</div>}</td>
                  <td>{j.type}</td>
                  <td><StatusBadge status={j.status} /></td>
                  <td><Progress value={j.progress} /></td>
                  <td>{j.attempts}/{j.maxAttempts}</td>
                  <td>{fmtDate(j.createdAt)}</td>
                  <td className="row">
                    {['failed', 'cancelled'].includes(j.status) && <button className="small" onClick={() => api.post(`/v1/admin/jobs/${j.id}/retry`).then(() => { notify('Retrying'); reload(); }).catch(fail)}>Retry</button>}
                    {j.status === 'queued' && <button className="small danger" onClick={() => api.post(`/v1/admin/jobs/${j.id}/cancel`).then(reload).catch(fail)}>Cancel</button>}
                  </td>
                </tr>
              ))}
              {data.items.length === 0 && <tr><td colSpan={7} className="muted">No jobs.</td></tr>}
            </tbody>
          </table>
        </div>
      )}
      <Pager page={data} onChange={setOffset} />
    </>
  );
}

export function JobDetail() {
  const { id } = useParams();
  const { data, error, loading } = useAsync(() => api.get<any>(`/v1/admin/jobs/${id}`), [id], { pollMs: 2500 });
  return (
    <>
      <p><Link to="/jobs">← Queue</Link></p>
      <Loading error={error} loading={loading && !data} />
      {data && (
        <>
          <div className="row"><h1>{data.filename ?? data.type}</h1><StatusBadge status={data.status} /></div>
          <div className="grid">
            <div className="card"><div className="small-text">Progress</div><Progress value={data.progress} /><div>{data.progress}%</div></div>
            <div className="card"><div className="small-text">Type</div>{data.type}</div>
            <div className="card"><div className="small-text">Started</div>{fmtDate(data.startedAt)}</div>
            <div className="card"><div className="small-text">Finished</div>{fmtDate(data.finishedAt)}</div>
          </div>
          {data.result?.trackId && <p><Link to={`/tracks?focus=${data.result.trackId}`}>Open track →</Link></p>}
          {data.result?.videoId && <p><Link to={`/videos`}>Open videos →</Link></p>}
          <h2>Log</h2>
          <pre className="log">{(data.logs ?? []).map((l: any) => `${new Date(l.at).toLocaleTimeString()}  ${l.message}`).join('\n') || 'No log entries yet.'}</pre>
          <h2>Provenance</h2>
          <pre className="log">{JSON.stringify(data.provenance, null, 2)}</pre>
          {data.result && (<><h2>Result</h2><pre className="log">{JSON.stringify(data.result, null, 2)}</pre></>)}
        </>
      )}
    </>
  );
}
