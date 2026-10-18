import { Link } from 'react-router-dom';
import { api, formatBytes } from '../api';
import { useAsync } from '../hooks';
import { Loading } from '../components/ui';

export function Overview() {
  const { data, error, loading, reload } = useAsync(() => api.get<any>('/v1/admin/overview'), [], { pollMs: 15000 });
  const activity = useAsync(() => api.get<any>('/v1/admin/activity', { days: 14 }), []);
  const c = data?.counts;
  const max = Math.max(1, ...(activity.data?.perDay ?? []).map((d: any) => d.plays));
  return (
    <>
      <h1>Overview</h1>
      <Loading error={error} loading={loading && !data} retry={reload} />
      {data && (
        <>
          <div className="grid">
            <Stat k="Tracks" v={`${c.readyTracks} / ${c.tracks}`} hint="ready / total" />
            <Stat k="Albums" v={c.albums} />
            <Stat k="Artists" v={c.artists} />
            <Stat k="Videos" v={c.videos} />
            <Stat k="Users" v={c.users} />
            <Stat k="Active (7 d)" v={c.activeUsers7d} />
            <Stat k="Plays (24 h)" v={data.plays.plays24h} />
            <Stat k="Storage" v={formatBytes(data.storage.totalBytes)} hint={data.storage.driver} />
          </div>
          <h2>Processing</h2>
          <div className="row">
            {Object.entries(data.jobs.jobs as Record<string, number>).map(([k, v]) => (
              <Link key={k} to={`/jobs?status=${k}`} className="badge">
                {k}: {v}
              </Link>
            ))}
            {Object.keys(data.jobs.jobs).length === 0 && <span className="muted">No jobs yet — upload media to get started.</span>}
          </div>
        </>
      )}
      {activity.data && (
        <>
          <h2>Plays, last 14 days</h2>
          <div className="card">
            <div className="bars" aria-label="Plays per day">
              {activity.data.perDay.map((d: any) => (
                <div key={d.day} title={`${d.day}: ${d.plays} plays, ${d.listeners} listeners`} style={{ height: `${(d.plays / max) * 100}%` }} />
              ))}
            </div>
            {activity.data.perDay.length === 0 && <p className="muted">No listening activity yet.</p>}
          </div>
          <h2>Top tracks</h2>
          <div className="table-wrap">
            <table>
              <thead><tr><th>Track</th><th>Artist</th><th>Plays</th></tr></thead>
              <tbody>
                {activity.data.topTracks.map((t: any) => (
                  <tr key={t.id}><td>{t.title}</td><td>{t.artist}</td><td>{t.plays}</td></tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
    </>
  );
}

function Stat({ k, v, hint }: { k: string; v: string | number; hint?: string }) {
  return (
    <div className="card stat">
      <div className="k">{k}</div>
      <div className="v">{v}</div>
      {hint && <div className="small-text">{hint}</div>}
    </div>
  );
}
