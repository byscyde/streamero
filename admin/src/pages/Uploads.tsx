import { useRef, useState } from 'react';
import { Link } from 'react-router-dom';
import { api, formatBytes, uploadFile } from '../api';
import { useToast } from '../hooks';
import { Progress } from '../components/ui';

interface Item {
  file: File;
  progress: number;
  status: 'pending' | 'uploading' | 'done' | 'error' | 'cancelled';
  jobId?: string;
  error?: string;
  abort?: AbortController;
}

const ACCEPT = '.mp3,.m4a,.aac,.flac,.wav,.aif,.aiff,.alac,.ogg,.opus,.wv,.ape,.caf,.mp4,.m4v,.mov,.mkv,.webm,.avi,.ts';

export function Uploads() {
  const [items, setItems] = useState<Item[]>([]);
  const [over, setOver] = useState(false);
  const [note, setNote] = useState('');
  const [genres, setGenres] = useState('');
  const [force, setForce] = useState(false);
  const input = useRef<HTMLInputElement>(null);
  const { notify, fail } = useToast();

  const update = (file: File, patch: Partial<Item>) => setItems((list) => list.map((i) => (i.file === file ? { ...i, ...patch } : i)));

  const add = (files: FileList | null) => {
    if (!files) return;
    const next = [...files].map((file) => ({ file, progress: 0, status: 'pending' as const }));
    setItems((l) => [...l, ...next]);
  };

  const start = async () => {
    for (const item of items.filter((i) => i.status === 'pending' || i.status === 'error')) {
      const abort = new AbortController();
      update(item.file, { status: 'uploading', abort, error: undefined });
      try {
        const overrides = genres ? { genres: genres.split(',').map((g) => g.trim()).filter(Boolean) } : {};
        const res = await uploadFile(item.file, 'media', { authorizationNote: note || null, overrides, force }, (p) => update(item.file, { progress: (p.sent / p.total) * 100 }), abort.signal);
        update(item.file, { status: 'done', progress: 100, jobId: res.job?.id });
      } catch (e: any) {
        update(item.file, { status: e?.name === 'AbortError' ? 'cancelled' : 'error', error: e?.message });
      }
    }
    notify('Uploads finished; processing continues in the background');
  };

  return (
    <>
      <h1>Upload media</h1>
      <p className="muted">Audio and video files are uploaded in resumable 8 MB chunks, then analysed with FFprobe and transcoded by the media worker. Originals are always preserved.</p>
      <div
        className={`drop ${over ? 'over' : ''}`}
        onDragOver={(e) => { e.preventDefault(); setOver(true); }}
        onDragLeave={() => setOver(false)}
        onDrop={(e) => { e.preventDefault(); setOver(false); add(e.dataTransfer.files); }}
      >
        <p>Drop audio or video files here</p>
        <button onClick={() => input.current?.click()}>Choose files</button>
        <input ref={input} type="file" multiple accept={ACCEPT} hidden onChange={(e) => add(e.target.files)} />
      </div>
      <div className="form-grid" style={{ marginTop: 16 }}>
        <label className="field">Rights / authorisation note
          <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="e.g. Label licence #42, own recording" />
        </label>
        <label className="field">Genres (optional, comma separated)
          <input value={genres} onChange={(e) => setGenres(e.target.value)} placeholder="indie, synthwave" />
        </label>
        <label className="field">Duplicates
          <select value={force ? 'force' : 'skip'} onChange={(e) => setForce(e.target.value === 'force')}>
            <option value="skip">Skip files already in the catalog</option>
            <option value="force">Import anyway</option>
          </select>
        </label>
      </div>
      {items.length > 0 && (
        <>
          <div className="row" style={{ margin: '16px 0' }}>
            <button className="primary" onClick={start} disabled={!items.some((i) => i.status === 'pending' || i.status === 'error')}>Start upload</button>
            <button onClick={() => setItems((l) => l.filter((i) => i.status === 'uploading'))}>Clear finished</button>
          </div>
          <div className="table-wrap">
            <table>
              <thead><tr><th>File</th><th>Size</th><th>Progress</th><th>Status</th><th /></tr></thead>
              <tbody>
                {items.map((i) => (
                  <tr key={i.file.name + i.file.size}>
                    <td className="wrap">{i.file.name}</td>
                    <td>{formatBytes(i.file.size)}</td>
                    <td><Progress value={i.progress} /></td>
                    <td>
                      {i.status === 'done' && i.jobId ? <Link to={`/jobs/${i.jobId}`}>processing →</Link> : i.status}
                      {i.error && <div className="error small-text">{i.error}</div>}
                    </td>
                    <td>{i.status === 'uploading' && <button className="small" onClick={() => i.abort?.abort()}>Cancel</button>}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </>
      )}
      <ImportPanel onError={fail} onDone={notify} />
    </>
  );
}

function ImportPanel({ onError, onDone }: { onError: (e: unknown) => void; onDone: (m: string) => void }) {
  const [url, setUrl] = useState('');
  const [path, setPath] = useState('');
  const [note, setNote] = useState('');
  return (
    <>
      <h2>Import from an authorised source</h2>
      <div className="card" style={{ display: 'grid', gap: 12 }}>
        <p className="muted" style={{ margin: 0 }}>
          Only import files you own or are licensed to store. URL imports are limited to hosts in <code>IMPORT_ALLOWED_HOSTS</code>; YouTube and similar
          platforms cannot be downloaded (use YouTube discovery in the app instead). Every import records its provenance.
        </p>
        <label className="field">Authorisation note (required)
          <input value={note} onChange={(e) => setNote(e.target.value)} placeholder="Who owns the rights and why STREAMERO may store this" />
        </label>
        <div className="row">
          <input style={{ flex: 1 }} value={url} onChange={(e) => setUrl(e.target.value)} placeholder="https://storage.example.com/master.flac" aria-label="Direct download URL" />
          <button disabled={!url || note.length < 5} onClick={async () => {
            try { await api.post('/v1/admin/imports/url', { url, authorizationNote: note }); setUrl(''); onDone('Import queued'); } catch (e) { onError(e); }
          }}>Import URL</button>
        </div>
        <div className="row">
          <input style={{ flex: 1 }} value={path} onChange={(e) => setPath(e.target.value)} placeholder="/srv/media/incoming/Album (file or folder in IMPORT_ALLOWED_DIRS)" aria-label="Server path" />
          <button disabled={!path || note.length < 5} onClick={async () => {
            try { await api.post('/v1/admin/imports/path', { path, authorizationNote: note }); setPath(''); onDone('Folder import queued'); } catch (e) { onError(e); }
          }}>Import from server</button>
        </div>
      </div>
    </>
  );
}
