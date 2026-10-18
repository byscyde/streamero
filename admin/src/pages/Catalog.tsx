import { useState } from 'react';
import { api, formatBytes, formatDuration, type Page, uploadFile } from '../api';
import { useAsync, useDebounced, useToast } from '../hooks';
import { ConfirmButton, Loading, Modal, Pager, StatusBadge } from '../components/ui';

function useListing(path: string, extra: Record<string, string> = {}) {
  const [q, setQ] = useState('');
  const [offset, setOffset] = useState(0);
  const dq = useDebounced(q);
  const key = JSON.stringify(extra);
  const res = useAsync(() => api.get<Page<any>>(path, { q: dq, offset, limit: 50, ...extra }), [dq, offset, key]);
  return { q, setQ: (v: string) => { setQ(v); setOffset(0); }, setOffset, ...res };
}

export function Tracks() {
  const [status, setStatus] = useState('');
  const list = useListing('/v1/admin/tracks', status ? { status } : {});
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [editing, setEditing] = useState<string | null>(null);
  const { notify, fail } = useToast();

  const bulk = async (action: string, value?: unknown) => {
    try {
      await api.post('/v1/admin/tracks/bulk', { ids: [...selected], action, value });
      notify(`Updated ${selected.size} track(s)`);
      setSelected(new Set());
      list.reload();
    } catch (e) { fail(e); }
  };
  const toggle = (id: string) => setSelected((s) => { const n = new Set(s); n.has(id) ? n.delete(id) : n.add(id); return n; });

  return (
    <>
      <h1>Tracks</h1>
      <div className="row">
        <input value={list.q} onChange={(e) => list.setQ(e.target.value)} placeholder="Search title, artist or album" aria-label="Search tracks" style={{ minWidth: 260 }} />
        <select value={status} onChange={(e) => setStatus(e.target.value)} aria-label="Status">
          <option value="">Any status</option><option value="ready">Ready</option><option value="processing">Processing</option><option value="failed">Failed</option>
        </select>
        <span className="spacer" />
        {selected.size > 0 && (
          <>
            <span className="muted">{selected.size} selected</span>
            <button className="small" onClick={() => bulk('set_downloadable', true)}>Allow downloads</button>
            <button className="small" onClick={() => bulk('set_downloadable', false)}>Block downloads</button>
            <button className="small" onClick={() => bulk('set_explicit', true)}>Mark explicit</button>
            <button className="small" onClick={() => { const g = prompt('Genre to add'); if (g) bulk('add_genre', g); }}>Add genre</button>
            <button className="small" onClick={() => bulk('reprocess')}>Reprocess</button>
            <ConfirmButton label="Delete" confirm={`Delete ${selected.size} track(s)? Shared media is kept.`} onConfirm={() => bulk('delete')} />
          </>
        )}
      </div>
      <Loading error={list.error} loading={list.loading && !list.data} retry={list.reload} />
      {list.data && (
        <div className="table-wrap" style={{ marginTop: 12 }}>
          <table>
            <thead><tr><th><span className="sr-only">Select</span></th><th /><th>Title</th><th>Artist</th><th>Album</th><th>Duration</th><th>Quality</th><th>Status</th><th>Plays</th><th /></tr></thead>
            <tbody>
              {list.data.items.map((t) => (
                <tr key={t.id}>
                  <td><input type="checkbox" checked={selected.has(t.id)} onChange={() => toggle(t.id)} aria-label={`Select ${t.title}`} /></td>
                  <td>{t.artworkUrl ? <img className="thumb" src={`${t.artworkUrl}?size=small`} alt="" /> : <span className="thumb" style={{ display: 'inline-block' }} />}</td>
                  <td className="wrap">{t.title} {t.explicit && <span className="badge">E</span>}</td>
                  <td>{t.artist.name}</td>
                  <td className="wrap">{t.album?.title ?? '—'}</td>
                  <td>{formatDuration(t.durationMs)}</td>
                  <td>{t.sourceQuality?.lossless ? <span className="badge teal">Lossless</span> : <span className="badge">{t.sourceQuality?.codec ?? '?'}</span>}</td>
                  <td><StatusBadge status={t.status} /></td>
                  <td>{t.playCount}</td>
                  <td><button className="small" onClick={() => setEditing(t.id)}>Edit</button></td>
                </tr>
              ))}
              {list.data.items.length === 0 && <tr><td colSpan={10} className="muted">No tracks match.</td></tr>}
            </tbody>
          </table>
        </div>
      )}
      <Pager page={list.data} onChange={list.setOffset} />
      {editing && <TrackEditor id={editing} onClose={() => { setEditing(null); list.reload(); }} />}
    </>
  );
}

function TrackEditor({ id, onClose }: { id: string; onClose: () => void }) {
  const { data } = useAsync(() => api.get<any>(`/v1/admin/tracks/${id}`), [id]);
  const [form, setForm] = useState<any>(null);
  const [lyrics, setLyrics] = useState<string | null>(null);
  const { notify, fail } = useToast();
  if (data && !form) {
    setForm({ title: data.title, artistName: data.artist.name, trackNumber: data.trackNumber ?? '', discNumber: data.discNumber ?? 1, explicit: data.explicit, downloadable: data.downloadable, genres: data.genres.join(', '), moods: data.moods.join(', '), isrc: data.isrc ?? '' });
    setLyrics(data.lyrics?.content ?? '');
  }
  const save = async () => {
    try {
      await api.patch(`/v1/admin/tracks/${id}`, {
        title: form.title, artistName: form.artistName !== data.artist.name ? form.artistName : undefined,
        trackNumber: form.trackNumber === '' ? null : Number(form.trackNumber), discNumber: Number(form.discNumber) || 1,
        explicit: form.explicit, downloadable: form.downloadable, isrc: form.isrc || null,
        genres: form.genres.split(',').map((s: string) => s.trim()).filter(Boolean), moods: form.moods.split(',').map((s: string) => s.trim()).filter(Boolean),
      });
      if (lyrics !== (data.lyrics?.content ?? '')) {
        if (lyrics) await api.put(`/v1/admin/tracks/${id}/lyrics`, { content: lyrics, source: 'manual' });
        else await api.del(`/v1/admin/tracks/${id}/lyrics`);
      }
      notify('Saved');
      onClose();
    } catch (e) { fail(e); }
  };
  return (
    <Modal title="Edit track" onClose={onClose}>
      {!form ? <p className="muted">Loading…</p> : (
        <div style={{ display: 'grid', gap: 12 }}>
          <div className="form-grid">
            <label className="field">Title<input value={form.title} onChange={(e) => setForm({ ...form, title: e.target.value })} /></label>
            <label className="field">Artist<input value={form.artistName} onChange={(e) => setForm({ ...form, artistName: e.target.value })} /></label>
            <label className="field">Track #<input type="number" min={1} value={form.trackNumber} onChange={(e) => setForm({ ...form, trackNumber: e.target.value })} /></label>
            <label className="field">Disc #<input type="number" min={1} value={form.discNumber} onChange={(e) => setForm({ ...form, discNumber: e.target.value })} /></label>
            <label className="field">Genres<input value={form.genres} onChange={(e) => setForm({ ...form, genres: e.target.value })} /></label>
            <label className="field">Moods<input value={form.moods} onChange={(e) => setForm({ ...form, moods: e.target.value })} /></label>
            <label className="field">ISRC<input value={form.isrc} onChange={(e) => setForm({ ...form, isrc: e.target.value })} /></label>
          </div>
          <div className="row">
            <label><input type="checkbox" checked={form.explicit} onChange={(e) => setForm({ ...form, explicit: e.target.checked })} /> Explicit</label>
            <label><input type="checkbox" checked={form.downloadable} onChange={(e) => setForm({ ...form, downloadable: e.target.checked })} /> Offline downloads allowed</label>
          </div>
          <h2>Renditions</h2>
          <div className="table-wrap"><table><thead><tr><th>Profile</th><th>Codec</th><th>Bitrate</th><th>Format</th><th>Size</th></tr></thead><tbody>
            {data.renditions.map((r: any) => (
              <tr key={r.profile}><td>{r.profile}{r.is_original && <span className="badge" style={{ marginLeft: 6 }}>original</span>}</td><td>{r.codec}</td><td>{r.bitrate ? `${Math.round(r.bitrate / 1000)} kbps` : '—'}</td>
                <td>{r.is_lossless ? <span className="badge teal">lossless {r.bit_depth}-bit/{r.sample_rate / 1000} kHz</span> : 'lossy'}</td><td>{formatBytes(Number(r.size_bytes))}</td></tr>
            ))}
          </tbody></table></div>
          <label className="field">Lyrics (LRC for synced, or plain text) — only add lyrics you are licensed to display
            <textarea rows={8} value={lyrics ?? ''} onChange={(e) => setLyrics(e.target.value)} placeholder="[00:12.00]First line" />
          </label>
          <div className="row"><span className="spacer" /><button onClick={onClose}>Cancel</button><button className="primary" onClick={save}>Save</button></div>
        </div>
      )}
    </Modal>
  );
}

export function Albums() {
  const list = useListing('/v1/admin/albums');
  const [editing, setEditing] = useState<any>(null);
  const { notify, fail } = useToast();
  return (
    <>
      <h1>Albums</h1>
      <input value={list.q} onChange={(e) => list.setQ(e.target.value)} placeholder="Search albums" aria-label="Search albums" />
      <Loading error={list.error} loading={list.loading && !list.data} retry={list.reload} />
      {list.data && (
        <div className="table-wrap" style={{ marginTop: 12 }}>
          <table>
            <thead><tr><th /><th>Title</th><th>Artist</th><th>Type</th><th>Released</th><th>Tracks</th><th /></tr></thead>
            <tbody>
              {list.data.items.map((a) => (
                <tr key={a.id}>
                  <td>{a.artworkUrl ? <img className="thumb" src={`${a.artworkUrl}?size=small`} alt="" /> : null}</td>
                  <td className="wrap">{a.title}</td><td>{a.artist.name}</td><td>{a.albumType}</td><td>{a.releaseDate ?? '—'}</td><td>{a.trackCount}</td>
                  <td className="row">
                    <button className="small" onClick={() => setEditing({ ...a, genres: a.genres.join(', ') })}>Edit</button>
                    <ArtworkUpload targetType="album" targetId={a.id} onDone={list.reload} />
                    <ConfirmButton label="Delete" confirm={`Delete “${a.title}” and its ${a.trackCount} track(s)? Media shared with other items is kept.`}
                      onConfirm={() => api.del(`/v1/admin/albums/${a.id}?withTracks=true`).then(() => { notify('Album deleted'); list.reload(); }).catch(fail)} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <Pager page={list.data} onChange={list.setOffset} />
      {editing && (
        <Modal title="Edit album" onClose={() => setEditing(null)}>
          <div className="form-grid">
            <label className="field">Title<input value={editing.title} onChange={(e) => setEditing({ ...editing, title: e.target.value })} /></label>
            <label className="field">Type<select value={editing.albumType} onChange={(e) => setEditing({ ...editing, albumType: e.target.value })}>{['album', 'single', 'ep', 'compilation'].map((t) => <option key={t}>{t}</option>)}</select></label>
            <label className="field">Release date<input type="date" value={editing.releaseDate ?? ''} onChange={(e) => setEditing({ ...editing, releaseDate: e.target.value })} /></label>
            <label className="field">Label<input value={editing.label ?? ''} onChange={(e) => setEditing({ ...editing, label: e.target.value })} /></label>
            <label className="field">Genres<input value={editing.genres} onChange={(e) => setEditing({ ...editing, genres: e.target.value })} /></label>
          </div>
          <div className="row" style={{ marginTop: 14 }}><span className="spacer" />
            <button className="primary" onClick={() => api.patch(`/v1/admin/albums/${editing.id}`, {
              title: editing.title, albumType: editing.albumType, releaseDate: editing.releaseDate || null, label: editing.label || null,
              genres: editing.genres.split(',').map((s: string) => s.trim()).filter(Boolean),
            }).then(() => { setEditing(null); list.reload(); notify('Saved'); }).catch(fail)}>Save</button>
          </div>
        </Modal>
      )}
    </>
  );
}

export function Artists() {
  const list = useListing('/v1/admin/artists');
  const [editing, setEditing] = useState<any>(null);
  const { notify, fail } = useToast();
  return (
    <>
      <h1>Artists</h1>
      <input value={list.q} onChange={(e) => list.setQ(e.target.value)} placeholder="Search artists" aria-label="Search artists" />
      <Loading error={list.error} loading={list.loading && !list.data} retry={list.reload} />
      {list.data && (
        <div className="table-wrap" style={{ marginTop: 12 }}>
          <table>
            <thead><tr><th /><th>Name</th><th>Albums</th><th>Tracks</th><th>Genres</th><th /></tr></thead>
            <tbody>
              {list.data.items.map((a) => (
                <tr key={a.id}>
                  <td>{a.artworkUrl ? <img className="thumb" style={{ borderRadius: '50%' }} src={`${a.artworkUrl}?size=small`} alt="" /> : null}</td>
                  <td>{a.name}</td><td>{a.albumCount}</td><td>{a.trackCount}</td><td className="wrap">{a.genres.join(', ')}</td>
                  <td className="row">
                    <button className="small" onClick={() => setEditing({ ...a, genres: a.genres.join(', ') })}>Edit</button>
                    <ArtworkUpload targetType="artist" targetId={a.id} onDone={list.reload} />
                    {a.trackCount === 0 && a.albumCount === 0 && (
                      <ConfirmButton label="Delete" confirm={`Delete artist “${a.name}”?`} onConfirm={() => api.del(`/v1/admin/artists/${a.id}`).then(list.reload).catch(fail)} />
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <Pager page={list.data} onChange={list.setOffset} />
      {editing && (
        <Modal title="Edit artist" onClose={() => setEditing(null)}>
          <div style={{ display: 'grid', gap: 12 }}>
            <label className="field">Name<input value={editing.name} onChange={(e) => setEditing({ ...editing, name: e.target.value })} /></label>
            <label className="field">Genres<input value={editing.genres} onChange={(e) => setEditing({ ...editing, genres: e.target.value })} /></label>
            <label className="field">Biography<textarea rows={6} value={editing.bio ?? ''} onChange={(e) => setEditing({ ...editing, bio: e.target.value })} /></label>
            <div className="row"><span className="spacer" />
              <button className="primary" onClick={() => api.patch(`/v1/admin/artists/${editing.id}`, { name: editing.name, bio: editing.bio || null, genres: editing.genres.split(',').map((s: string) => s.trim()).filter(Boolean) })
                .then(() => { setEditing(null); list.reload(); notify('Saved'); }).catch(fail)}>Save</button>
            </div>
          </div>
        </Modal>
      )}
    </>
  );
}

function ArtworkUpload({ targetType, targetId, onDone }: { targetType: string; targetId: string; onDone: () => void }) {
  const { notify, fail } = useToast();
  return (
    <label className="small" style={{ cursor: 'pointer' }}>
      <span className="badge">Artwork…</span>
      <input type="file" accept=".jpg,.jpeg,.png,.webp" hidden onChange={async (e) => {
        const f = e.target.files?.[0];
        if (!f) return;
        try { await uploadFile(f, 'artwork', { targetType, targetId }, () => {}); notify('Artwork uploaded; processing'); setTimeout(onDone, 3000); } catch (err) { fail(err); }
      }} />
    </label>
  );
}

export function Videos() {
  const list = useListing('/v1/admin/videos');
  const [subsFor, setSubsFor] = useState<any>(null);
  const { notify, fail } = useToast();
  return (
    <>
      <h1>Videos</h1>
      <input value={list.q} onChange={(e) => list.setQ(e.target.value)} placeholder="Search videos" aria-label="Search videos" />
      <Loading error={list.error} loading={list.loading && !list.data} retry={list.reload} />
      {list.data && (
        <div className="table-wrap" style={{ marginTop: 12 }}>
          <table>
            <thead><tr><th /><th>Title</th><th>Artist</th><th>Duration</th><th>Qualities</th><th>Subtitles</th><th>Offline</th><th>Status</th><th /></tr></thead>
            <tbody>
              {list.data.items.map((v) => (
                <tr key={v.id}>
                  <td>{v.thumbnailUrl ? <img className="thumb" style={{ width: 64 }} src={`${v.thumbnailUrl}?size=small`} alt="" /> : null}</td>
                  <td className="wrap">{v.title}</td><td>{v.artist?.name ?? '—'}</td><td>{formatDuration(v.durationMs)}</td>
                  <td>{v.qualities.map((q: number) => `${q}p`).join(' ')}</td>
                  <td>{v.subtitles.map((s: any) => s.language).join(', ') || '—'}</td>
                  <td><input type="checkbox" checked={v.downloadable} aria-label="Allow offline download" onChange={(e) => api.patch(`/v1/admin/videos/${v.id}`, { downloadable: e.target.checked }).then(list.reload).catch(fail)} /></td>
                  <td><StatusBadge status={v.status} /></td>
                  <td className="row">
                    <button className="small" onClick={() => setSubsFor(v)}>Subtitles</button>
                    <button className="small" onClick={() => api.post('/v1/admin/reprocess', { videoId: v.id }).then(() => notify('Reprocessing queued')).catch(fail)}>Reprocess</button>
                    <ConfirmButton label="Delete" confirm={`Delete “${v.title}”?`} onConfirm={() => api.del(`/v1/admin/videos/${v.id}`).then(list.reload).catch(fail)} />
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <Pager page={list.data} onChange={list.setOffset} />
      {subsFor && <SubtitleManager video={subsFor} onClose={() => { setSubsFor(null); list.reload(); }} />}
    </>
  );
}

function SubtitleManager({ video, onClose }: { video: any; onClose: () => void }) {
  const [file, setFile] = useState<File | null>(null);
  const [language, setLanguage] = useState('en');
  const [label, setLabel] = useState('');
  const [kind, setKind] = useState('subtitles');
  const [isDefault, setDefault] = useState(false);
  const [offset, setOffset] = useState(0);
  const { notify, fail } = useToast();
  return (
    <Modal title={`Subtitles — ${video.title}`} onClose={onClose}>
      <div className="table-wrap"><table><thead><tr><th>Language</th><th>Label</th><th>Kind</th><th>Default</th><th /></tr></thead><tbody>
        {video.subtitles.map((s: any) => (
          <tr key={s.id}><td>{s.language}</td><td>{s.label}</td><td>{s.kind}</td><td>{s.isDefault ? 'yes' : ''}</td>
            <td className="row">
              {!s.isDefault && <button className="small" onClick={() => api.patch(`/v1/admin/subtitles/${s.id}`, { isDefault: true }).then(onClose).catch(fail)}>Make default</button>}
              <ConfirmButton label="Remove" confirm="Remove this subtitle track?" onConfirm={() => api.del(`/v1/admin/subtitles/${s.id}`).then(onClose).catch(fail)} />
            </td></tr>
        ))}
        {video.subtitles.length === 0 && <tr><td colSpan={5} className="muted">No subtitle tracks.</td></tr>}
      </tbody></table></div>
      <h2>Add SRT or WebVTT</h2>
      <div className="form-grid">
        <label className="field">File<input type="file" accept=".srt,.vtt" onChange={(e) => setFile(e.target.files?.[0] ?? null)} /></label>
        <label className="field">Language (BCP 47)<input value={language} onChange={(e) => setLanguage(e.target.value)} placeholder="en, hr, pt-BR" /></label>
        <label className="field">Label<input value={label} onChange={(e) => setLabel(e.target.value)} placeholder="English" /></label>
        <label className="field">Kind<select value={kind} onChange={(e) => setKind(e.target.value)}><option value="subtitles">Subtitles</option><option value="captions">Closed captions (SDH)</option><option value="descriptions">Audio descriptions</option></select></label>
        <label className="field">Sync offset (ms)<input type="number" value={offset} onChange={(e) => setOffset(Number(e.target.value))} /></label>
        <label className="field">&nbsp;<span><input type="checkbox" checked={isDefault} onChange={(e) => setDefault(e.target.checked)} /> Default track</span></label>
      </div>
      <div className="row" style={{ marginTop: 12 }}><span className="spacer" />
        <button className="primary" disabled={!file || !language} onClick={async () => {
          try {
            await uploadFile(file!, 'subtitle', { videoId: video.id, language, label: label || undefined, kind, isDefault, offsetMs: offset }, () => {});
            notify('Subtitle uploaded; it will be converted to WebVTT');
            onClose();
          } catch (e) { fail(e); }
        }}>Upload</button>
      </div>
      <p className="small-text">Originals are preserved; a normalised WebVTT copy is served to players and added to the HLS stream.</p>
    </Modal>
  );
}
