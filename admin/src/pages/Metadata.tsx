import { useState, type ReactNode } from 'react';
import { adminApi, api, formatDuration, isDisplayableImage, type MetadataResult, type Page } from '../api';
import { useAsync, useDebounced, useToast } from '../hooks';
import { CoverPlaceholder, ErrorBox, Modal } from '../components/ui';

export function MetadataNote() {
  return (
    <p className="callout info">
      Metadata and cover art come from <b>MusicBrainz</b> and the <b>Cover Art Archive</b> (open, official APIs). Audio itself must be uploaded or imported by you —
      STREAMERO does not download from YouTube or other streaming services.
    </p>
  );
}

function Cover({ url }: { url?: string | null }) {
  const [broken, setBroken] = useState(false);
  if (!isDisplayableImage(url) || broken) return <CoverPlaceholder />;
  return <img className="thumb lg" src={url!} alt="" onError={() => setBroken(true)} />;
}

/** Search box + results; `action` renders the per-result button(s). */
export function MetadataSearch({ initialQuery = '', action }: { initialQuery?: string; action: (r: MetadataResult) => ReactNode }) {
  const [q, setQ] = useState(initialQuery);
  const [submitted, setSubmitted] = useState(initialQuery.trim());
  const res = useAsync(() => (submitted ? adminApi.metadata.search(submitted) : Promise.resolve<MetadataResult[] | undefined>(undefined)), [submitted]);
  return (
    <div className="stack">
      <form className="row" onSubmit={(e) => { e.preventDefault(); setSubmitted(q.trim()); if (q.trim() === submitted) void res.reload(); }}>
        <input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Artist and/or song title" aria-label="Metadata search" style={{ flex: 1, minWidth: 220 }} autoFocus />
        <button className="primary" disabled={!q.trim()}>Search</button>
      </form>
      {res.error && <ErrorBox error={res.error} />}
      {res.loading && submitted && <p className="muted">Searching MusicBrainz…</p>}
      {!res.loading && res.data && res.data.length === 0 && <p className="muted">No recordings found. Try fewer words or only the title.</p>}
      {!res.loading && res.data && res.data.length > 0 && (
        <ul className="results" aria-label="Metadata results">
          {res.data.map((r) => (
            <li key={`${r.id}-${r.albumId ?? ''}`}>
              <Cover url={r.coverUrl} />
              <div className="grow">
                <div className="title-font strong">{r.title}</div>
                <div className="small-text">
                  {r.artist}{r.album ? ` · ${r.album}` : ''}{r.year ? ` · ${r.year}` : ''}{r.durationMs ? ` · ${formatDuration(r.durationMs)}` : ''}
                </div>
                {!!r.genres?.length && <div className="tags">{r.genres.slice(0, 6).map((g) => <span key={g} className="badge">{g}</span>)}</div>}
              </div>
              <div className="row nowrap">{action(r)}</div>
            </li>
          ))}
        </ul>
      )}
      {res.data?.some((r) => r.coverUrl && !isDisplayableImage(r.coverUrl)) && (
        <p className="small-text">Cover previews are hidden because the dashboard only loads same-origin images; the cover is still downloaded when you apply.</p>
      )}
    </div>
  );
}

/** "Find metadata" dialog for one track (opened from the track editor). */
export function MetadataDialog({ track, onClose, onApplied }: { track: { id: string; title: string; artistName: string }; onClose: () => void; onApplied: () => void }) {
  const [overwrite, setOverwrite] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const [err, setErr] = useState<unknown>(null);
  const { notify } = useToast();
  const apply = async (r: MetadataResult) => {
    setBusy(r.id);
    setErr(null);
    try {
      await adminApi.metadata.apply({ trackId: track.id, recordingId: r.id, ...(r.albumId ? { releaseId: r.albumId } : {}), overwrite });
      notify(`Applied “${r.title}” metadata`);
      onApplied();
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(null);
    }
  };
  return (
    <Modal title="Find metadata" onClose={onClose} wide>
      <div className="stack">
        <MetadataNote />
        <label className="check"><input type="checkbox" checked={overwrite} onChange={(e) => setOverwrite(e.target.checked)} /> Overwrite existing fields (otherwise only empty fields are filled)</label>
        <ErrorBox error={err} />
        <MetadataSearch initialQuery={`${track.artistName} ${track.title}`.trim()} action={(r) => (
          <button className="small primary" disabled={!!busy} onClick={() => apply(r)}>{busy === r.id ? 'Applying…' : 'Apply'}</button>
        )} />
      </div>
    </Modal>
  );
}

/** Standalone page: search, then apply a result to any catalog track. */
export function MetadataPage() {
  const [target, setTarget] = useState<MetadataResult | null>(null);
  return (
    <>
      <h1>Metadata lookup</h1>
      <MetadataNote />
      <div className="card">
        <MetadataSearch action={(r) => <button className="small" onClick={() => setTarget(r)}>Apply to track…</button>} />
      </div>
      <p className="small-text" style={{ marginTop: 12 }}>
        Tip: set <code>METADATA_AUTOFILL=true</code> on the server to fill missing tags automatically after ingestion (only matches with ≥ 90 % confidence).
      </p>
      {target && <ApplyToTrackDialog result={target} onClose={() => setTarget(null)} />}
    </>
  );
}

function ApplyToTrackDialog({ result, onClose }: { result: MetadataResult; onClose: () => void }) {
  const [q, setQ] = useState(result.title);
  const dq = useDebounced(q);
  const tracks = useAsync(() => api.get<Page<any>>('/v1/admin/tracks', { q: dq, limit: 20 }), [dq]);
  const [picked, setPicked] = useState<any>(null);
  const [overwrite, setOverwrite] = useState(false);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const { notify } = useToast();
  return (
    <Modal title="Apply to track" onClose={onClose} wide>
      <div className="stack">
        <div className="callout">
          Applying <b>{result.title}</b> — {result.artist}{result.album ? ` · ${result.album}` : ''}{result.year ? ` (${result.year})` : ''}
        </div>
        <input value={q} onChange={(e) => { setQ(e.target.value); setPicked(null); }} placeholder="Search your catalog" aria-label="Search tracks" autoFocus />
        {tracks.error && <ErrorBox error={tracks.error} />}
        <ul className="results pick" aria-label="Catalog tracks">
          {tracks.data?.items.map((t) => (
            <li key={t.id} className={picked?.id === t.id ? 'selected' : ''}>
              <label className="check grow">
                <input type="radio" name="track" checked={picked?.id === t.id} onChange={() => setPicked(t)} />
                <span>
                  <span className="title-font strong">{t.title}</span>
                  <span className="small-text"> · {t.artist?.name}{t.album?.title ? ` · ${t.album.title}` : ''} · {formatDuration(t.durationMs)}</span>
                </span>
              </label>
            </li>
          ))}
          {tracks.data && tracks.data.items.length === 0 && <li className="muted">No tracks match.</li>}
          {tracks.loading && !tracks.data && <li className="muted">Loading…</li>}
        </ul>
        <label className="check"><input type="checkbox" checked={overwrite} onChange={(e) => setOverwrite(e.target.checked)} /> Overwrite existing fields</label>
        <ErrorBox error={err} />
        <div className="row"><span className="spacer" /><button onClick={onClose}>Cancel</button>
          <button className="primary" disabled={!picked || busy} onClick={async () => {
            setBusy(true);
            setErr(null);
            try {
              await adminApi.metadata.apply({ trackId: picked.id, recordingId: result.id, ...(result.albumId ? { releaseId: result.albumId } : {}), overwrite });
              notify(`Metadata applied to “${picked.title}”`);
              onClose();
            } catch (e) {
              setErr(e);
            } finally {
              setBusy(false);
            }
          }}>{busy ? 'Applying…' : 'Apply'}</button>
        </div>
      </div>
    </Modal>
  );
}
