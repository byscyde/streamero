import { useState } from 'react';
import { Link, NavLink, useNavigate, useParams } from 'react-router-dom';
import * as I from '../components/Icons';
import { AlbumCard, ArtistCircle, Artwork, ConfirmDialog, Empty, ErrorState, PromptDialog, Spinner, TrackRow, VideoCard } from '../components/ui';
import { api } from '../lib/api';
import { plural } from '../lib/format';
import { controls } from '../player/player';
import { refreshPlaylists, useApp, useConfig, useLoad } from '../state/app';
import { toast } from '../state/store';

const TABS = [
  ['', 'Playlists'],
  ['liked', 'Liked Songs'],
  ['albums', 'Albums'],
  ['artists', 'Artists'],
  ['videos', 'Liked Videos'],
  ['history', 'History'],
] as const;

export default function Library() {
  const { tab = '' } = useParams();
  const cfg = useConfig();
  const tabs = TABS.filter(([id]) => id !== 'videos' || cfg.features.videos);
  return (
    <div className="page library">
      <h1 className="page-title">Your Library</h1>
      <nav className="chip-row scroll lib-tabs">
        {tabs.map(([id, label]) => (
          <NavLink key={id} to={`/library${id ? `/${id}` : ''}`} end className={({ isActive }) => `chip ${isActive ? 'active' : ''}`}>
            {label}
          </NavLink>
        ))}
      </nav>
      {tab === '' && <PlaylistsTab />}
      {tab === 'liked' && <LikedTab />}
      {tab === 'albums' && <AlbumsTab />}
      {tab === 'artists' && <ArtistsTab />}
      {tab === 'videos' && <VideosTab />}
      {tab === 'history' && <HistoryTab />}
    </div>
  );
}

export function CreatePlaylistButton({ className = 'pill' }: { className?: string }) {
  const [open, setOpen] = useState(false);
  const nav = useNavigate();
  return (
    <>
      <button className={className} onClick={() => setOpen(true)}>
        <I.IconPlus size={18} /> New playlist
      </button>
      {open && (
        <PromptDialog
          title="New playlist"
          label="Name"
          confirm="Create"
          onClose={() => setOpen(false)}
          onSubmit={async (title) => {
            const p = await api.createPlaylist(title);
            await refreshPlaylists();
            toast('Playlist created', 'success');
            nav(`/playlist/${p.playlist.id}`);
          }}
        />
      )}
    </>
  );
}

function PlaylistsTab() {
  const playlists = useApp((s) => s.playlists);
  const liked = useApp((s) => s.library.track.size);
  const [renaming, setRenaming] = useState<{ id: string; title: string; version: number } | null>(null);
  const [deleting, setDeleting] = useState<{ id: string; title: string } | null>(null);
  return (
    <>
      <div className="row-between">
        <span className="muted">{plural(playlists.length, 'playlist')}</span>
        <CreatePlaylistButton />
      </div>
      <div className="lib-list">
        <Link to="/library/liked" className="lib-row">
          <div className="art liked-art">
            <I.IconHeartFilled size={26} />
          </div>
          <div className="tr-main">
            <div className="tr-title title-font">Liked Songs</div>
            <div className="tr-sub">Playlist • {plural(liked, 'song')}</div>
          </div>
        </Link>
        {playlists.map((p) => (
          <div key={p.id} className="lib-row">
            <Link to={`/playlist/${p.id}`} className="lib-row-link">
              <Artwork src={p.artworkUrl ?? p.mosaicUrls?.[0]} />
              <div className="tr-main">
                <div className="tr-title title-font">{p.title}</div>
                <div className="tr-sub">
                  {p.isOwner ? 'Playlist' : `By ${p.isEditorial ? 'STREAMERO' : p.owner?.displayName ?? '—'}`} • {plural(p.itemCount, 'song')}
                </div>
              </div>
            </Link>
            {p.isOwner && (
              <>
                <button className="icon-btn" aria-label={`Rename ${p.title}`} onClick={() => setRenaming({ id: p.id, title: p.title, version: p.version })}>
                  <I.IconEdit size={18} />
                </button>
                <button className="icon-btn" aria-label={`Delete ${p.title}`} onClick={() => setDeleting({ id: p.id, title: p.title })}>
                  <I.IconTrash size={18} />
                </button>
              </>
            )}
          </div>
        ))}
      </div>
      {renaming && (
        <PromptDialog
          title="Rename playlist"
          label="Name"
          initial={renaming.title}
          onClose={() => setRenaming(null)}
          onSubmit={async (title) => {
            await api.updatePlaylist(renaming.id, { title, expectedVersion: renaming.version });
            await refreshPlaylists();
          }}
        />
      )}
      {deleting && (
        <ConfirmDialog
          title="Delete playlist?"
          body={`“${deleting.title}” will be deleted. This can’t be undone.`}
          confirm="Delete"
          danger
          onClose={() => setDeleting(null)}
          onConfirm={async () => {
            await api.deletePlaylist(deleting.id);
            await refreshPlaylists();
            toast('Playlist deleted', 'success');
          }}
        />
      )}
    </>
  );
}

function LikedTab() {
  const r = useLoad(() => api.likedTracks(100), [], 'library');
  const [filter, setFilter] = useState('');
  if (r.loading && !r.data) return <Spinner />;
  if (r.error && !r.data) return <ErrorState error={r.error} onRetry={r.reload} />;
  const all = r.data?.items ?? [];
  const f = filter.trim().toLowerCase();
  const tracks = f ? all.filter((t) => `${t.title} ${t.artist.name} ${t.album?.title ?? ''}`.toLowerCase().includes(f)) : all;
  const ctx = { type: 'liked', title: 'Liked Songs' };
  if (!all.length) return <Empty title="Songs you like appear here" icon={<I.IconHeart size={36} />}>Tap the heart on any song to save it.</Empty>;
  return (
    <>
      <div className="row-between">
        <div className="action-bar inline">
          <button className="btn-accent" onClick={() => controls.playTracks(tracks, 0, ctx)}>
            <I.IconPlay size={16} /> Play
          </button>
          <button className="pill" onClick={() => controls.playTracks(tracks, 0, ctx, { shuffle: true })}>
            <I.IconShuffle size={16} /> Shuffle
          </button>
        </div>
        <input className="filter-input" placeholder="Filter" aria-label="Filter liked songs" value={filter} onChange={(e) => setFilter(e.target.value)} />
      </div>
      <p className="muted small">{plural(r.data?.total ?? all.length, 'song')}</p>
      <div className="track-list">
        {tracks.map((t, i) => (
          <TrackRow key={t.id} track={t} onPlay={() => controls.playTracks(tracks, i, ctx)} />
        ))}
      </div>
    </>
  );
}

function AlbumsTab() {
  const r = useLoad(() => api.savedAlbums(100), [], 'library');
  if (!r.data) return r.error ? <ErrorState error={r.error} onRetry={r.reload} /> : <Spinner />;
  if (!r.data.items.length) return <Empty title="Save albums to find them here" />;
  return (
    <div className="grid">
      {r.data.items.map((a) => (
        <AlbumCard key={a.id} album={a} />
      ))}
    </div>
  );
}

function ArtistsTab() {
  const r = useLoad(() => api.followedArtists(100), [], 'library');
  if (!r.data) return r.error ? <ErrorState error={r.error} onRetry={r.reload} /> : <Spinner />;
  if (!r.data.items.length) return <Empty title="Follow artists to see them here" />;
  return (
    <div className="grid artists">
      {r.data.items.map((a) => (
        <ArtistCircle key={a.id} artist={a} />
      ))}
    </div>
  );
}

function VideosTab() {
  const r = useLoad(() => api.likedVideos(100), [], 'library');
  if (!r.data) return r.error ? <ErrorState error={r.error} onRetry={r.reload} /> : <Spinner />;
  if (!r.data.items.length) return <Empty title="Videos you like appear here" />;
  return (
    <div className="grid videos">
      {r.data.items.map((v) => (
        <VideoCard key={v.id} video={v} />
      ))}
    </div>
  );
}

function HistoryTab() {
  const r = useLoad(() => api.history(100), [], 'library');
  const [confirm, setConfirm] = useState(false);
  if (!r.data) return r.error ? <ErrorState error={r.error} onRetry={r.reload} /> : <Spinner />;
  const items = r.data.items;
  const tracks = items.map((h) => h.track);
  let lastDay = '';
  return (
    <>
      <div className="row-between">
        <span className="muted">Every play, newest first</span>
        {items.length > 0 && (
          <button className="pill" onClick={() => setConfirm(true)}>
            Clear history
          </button>
        )}
      </div>
      {!items.length ? (
        <Empty title="Nothing played yet" icon={<I.IconClock size={36} />} />
      ) : (
        <div className="track-list">
          {items.map((h, i) => {
            const day = new Date(h.playedAt).toLocaleDateString(undefined, { weekday: 'long', month: 'short', day: 'numeric' });
            const head = day !== lastDay;
            lastDay = day;
            return (
              <div key={h.id}>
                {head && <h4 className="disc">{day}</h4>}
                <TrackRow track={h.track} onPlay={() => controls.playTracks(tracks, i, { type: 'history', title: 'History' })} meta={new Date(h.playedAt).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })} />
              </div>
            );
          })}
        </div>
      )}
      {confirm && (
        <ConfirmDialog
          title="Clear listening history?"
          body="This removes your play history and resume positions. Recommendations will start fresh."
          confirm="Clear"
          danger
          onClose={() => setConfirm(false)}
          onConfirm={async () => {
            await api.clearHistory();
            r.reload();
            toast('History cleared', 'success');
          }}
        />
      )}
    </>
  );
}
