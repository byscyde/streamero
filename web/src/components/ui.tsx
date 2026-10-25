import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import { createPortal } from 'react-dom';
import { Link, useNavigate } from 'react-router-dom';
import { api, media } from '../lib/api';
import { genreGradient } from '../lib/appearance';
import { compactNumber, formatMs } from '../lib/format';
import type { Album, Artist, Mix, Playlist, Track, Video } from '../lib/types';
import { controls, useCurrentTrack, usePlayer } from '../player/player';
import { refreshPlaylists, toggleSaved, useApp, useConfig, useSaved } from '../state/app';
import { errorText, toast } from '../state/store';
import * as I from './Icons';

export function artUrl(url: string | null | undefined, size: 'small' | 'large' = 'small') {
  const u = media(url);
  if (!u) return undefined;
  return u.includes('/v1/artwork/') ? `${u}${u.includes('?') ? '&' : '?'}size=${size}` : u;
}

export function Artwork({ src, alt = '', size = 'small', round, className = '', fallback = 'music' }: { src?: string | null; alt?: string; size?: 'small' | 'large'; round?: boolean; className?: string; fallback?: 'music' | 'user' | 'video' }) {
  const [failed, setFailed] = useState(false);
  const u = artUrl(src, size);
  useEffect(() => setFailed(false), [u]);
  const F = fallback === 'user' ? I.IconUser : fallback === 'video' ? I.IconVideo : I.IconMusic;
  return (
    <div className={`art ${round ? 'art-round' : ''} ${className}`}>
      {u && !failed ? <img src={u} alt={alt} loading="lazy" decoding="async" onError={() => setFailed(true)} draggable={false} /> : <F size={28} />}
    </div>
  );
}

export function Spinner({ label = 'Loading' }: { label?: string }) {
  return (
    <div className="spinner-wrap" role="status" aria-label={label}>
      <div className="spinner" />
    </div>
  );
}

export function ErrorState({ error, onRetry }: { error: unknown; onRetry?: () => void }) {
  return (
    <div className="empty">
      <p>{errorText(error)}</p>
      {onRetry && (
        <button className="pill" onClick={onRetry}>
          Try again
        </button>
      )}
    </div>
  );
}

export function Empty({ title, children, icon }: { title: string; children?: ReactNode; icon?: ReactNode }) {
  return (
    <div className="empty">
      {icon}
      <h3>{title}</h3>
      {children && <div className="muted">{children}</div>}
    </div>
  );
}

export function Section({ title, more, children, className = '' }: { title: ReactNode; more?: string | (() => void); children: ReactNode; className?: string }) {
  return (
    <section className={`section ${className}`}>
      <header className="section-head">
        <h2>{title}</h2>
        {typeof more === 'string' ? (
          <Link to={more} className="pill pill-sm">
            More
          </Link>
        ) : more ? (
          <button className="pill pill-sm" onClick={more}>
            More
          </button>
        ) : null}
      </header>
      {children}
    </section>
  );
}

/** Horizontal scroller with desktop arrow buttons. */
export function Carousel({ children, className = '' }: { children: ReactNode; className?: string }) {
  const ref = useRef<HTMLDivElement>(null);
  const [edges, setEdges] = useState({ start: true, end: true });
  const update = () => {
    const el = ref.current;
    if (!el) return;
    setEdges({ start: el.scrollLeft < 4, end: el.scrollLeft + el.clientWidth >= el.scrollWidth - 4 });
  };
  useLayoutEffect(update);
  const by = (d: number) => ref.current?.scrollBy({ left: d * ref.current.clientWidth * 0.8, behavior: 'smooth' });
  return (
    <div className="carousel-wrap">
      {!edges.start && (
        <button className="carousel-btn left" aria-label="Scroll left" onClick={() => by(-1)}>
          <I.IconChevronLeft />
        </button>
      )}
      <div className={`carousel ${className}`} ref={ref} onScroll={update}>
        {children}
      </div>
      {!edges.end && (
        <button className="carousel-btn right" aria-label="Scroll right" onClick={() => by(1)}>
          <I.IconChevronRight />
        </button>
      )}
    </div>
  );
}

export function GenreChip({ name, kind = 'genre', plain }: { name: string; kind?: 'genre' | 'mood'; plain?: boolean }) {
  const cfg = useConfig();
  const grad = cfg.theme.genreGradients && !plain;
  return (
    <Link to={`/${kind}/${encodeURIComponent(name)}`} className={`chip genre-chip ${grad ? 'gradient' : ''}`} style={grad ? { backgroundImage: genreGradient(name) } : undefined}>
      {name}
    </Link>
  );
}

export function PlayButton({ onClick, playing, size = 56, label = 'Play', variant = 'white' }: { onClick: () => void; playing?: boolean; size?: number; label?: string; variant?: 'white' | 'accent' }) {
  return (
    <button
      className={`play-btn ${variant}`}
      style={{ width: size, height: size }}
      aria-label={playing ? 'Pause' : label}
      onClick={(e) => {
        e.preventDefault();
        e.stopPropagation();
        onClick();
      }}
    >
      {playing ? <I.IconPause size={size * 0.42} /> : <I.IconPlay size={size * 0.42} style={{ marginLeft: size * 0.05 }} />}
    </button>
  );
}

export function AlbumCard({ album, onPlay }: { album: Album; onPlay?: () => void }) {
  const year = album.releaseDate?.slice(0, 4);
  const type = album.albumType ? album.albumType[0].toUpperCase() + album.albumType.slice(1) : 'Album';
  return (
    <Link to={`/album/${album.id}`} className="card">
      <div className="card-art">
        <Artwork src={album.artworkUrl} alt="" size="large" />
        <div className="card-play">
          <PlayButton size={44} variant="accent" onClick={onPlay ?? (() => playAlbum(album.id))} />
        </div>
      </div>
      <div className="card-title">{album.title}</div>
      <div className="card-sub">
        {type}
        {year ? ` • ${year}` : ''} • {album.artist.name}
      </div>
    </Link>
  );
}

export function PlaylistCard({ playlist }: { playlist: Playlist }) {
  return (
    <Link to={`/playlist/${playlist.id}`} className="card">
      <div className="card-art">
        <Artwork src={playlist.artworkUrl ?? playlist.mosaicUrls?.[0]} size="large" />
        <div className="card-play">
          <PlayButton size={44} variant="accent" onClick={() => playPlaylist(playlist.id)} />
        </div>
      </div>
      <div className="card-title">{playlist.title}</div>
      <div className="card-sub">{playlist.isEditorial ? 'STREAMERO' : playlist.owner?.displayName ?? 'Playlist'} • {playlist.itemCount} songs</div>
    </Link>
  );
}

export function MixCard({ mix }: { mix: Mix }) {
  const urls = mix.artworkUrls ?? [];
  return (
    <Link to={`/mix/${encodeURIComponent(mix.id)}`} className="card">
      <div className="card-art mosaic">
        {urls.length >= 4 ? urls.slice(0, 4).map((u, i) => <Artwork key={i} src={u} />) : <Artwork src={urls[0]} size="large" />}
        <span className="mix-badge">{mix.kind === 'radio' ? 'Radio' : 'Mix'}</span>
        <div className="card-play">
          <PlayButton size={44} variant="accent" onClick={() => playMix(mix.id)} />
        </div>
      </div>
      <div className="card-title">{mix.title}</div>
      <div className="card-sub clamp2">{mix.description}</div>
    </Link>
  );
}

export function ArtistCircle({ artist }: { artist: Artist }) {
  return (
    <Link to={`/artist/${artist.id}`} className="artist-circle">
      <Artwork src={artist.artworkUrl} round size="large" fallback="user" />
      <div className="ac-name">{artist.name}</div>
      {artist.followerCount != null && <div className="ac-sub">{compactNumber(artist.followerCount)} followers</div>}
    </Link>
  );
}

export function VideoCard({ video }: { video: Video }) {
  const pct = video.progress && !video.progress.completed && video.durationMs ? (video.progress.positionMs / video.durationMs) * 100 : 0;
  return (
    <Link to={`/video/${video.id}`} className="card video-card">
      <div className="card-art wide">
        <Artwork src={video.thumbnailUrl} size="large" fallback="video" />
        <span className="duration-badge">{formatMs(video.durationMs)}</span>
        {pct > 0 && <span className="vprogress" style={{ width: `${pct}%` }} />}
      </div>
      <div className="card-title">{video.title}</div>
      <div className="card-sub">{video.artist?.name ?? 'Video'}</div>
    </Link>
  );
}

/** Track list row (Top songs / Up Next style): artwork, mono title, artist, meta, play/menu. */
export function TrackRow({
  track,
  index,
  onPlay,
  meta,
  showArt = true,
  number,
  extraMenu,
  dragHandle,
}: {
  track: Track;
  index?: number;
  onPlay: () => void;
  meta?: ReactNode;
  showArt?: boolean;
  number?: number;
  extraMenu?: MenuItem[];
  dragHandle?: ReactNode;
}) {
  const cur = useCurrentTrack();
  const playing = usePlayer((s) => s.playing);
  const isCurrent = cur?.id === track.id;
  const liked = useSaved('track', track.id);
  return (
    <div className={`track-row ${isCurrent ? 'current' : ''}`} onDoubleClick={onPlay} data-index={index}>
      {dragHandle}
      {number !== undefined && (
        <div className="tr-num">
          {isCurrent && playing ? <span className="eq-bars"><i /><i /><i /></span> : <span>{number}</span>}
          <button className="tr-num-play" aria-label={`Play ${track.title}`} onClick={onPlay}>
            <I.IconPlay size={16} />
          </button>
        </div>
      )}
      {showArt && (
        <button className="tr-art" onClick={onPlay} aria-label={`Play ${track.title}`}>
          <Artwork src={track.artworkUrl ?? track.album?.artworkUrl} />
          <span className="tr-art-play">{isCurrent && playing ? <I.IconPause size={18} /> : <I.IconPlay size={18} />}</span>
        </button>
      )}
      <div className="tr-main">
        <div className="tr-title title-font">
          {track.title}
          {track.explicit && <span className="explicit" title="Explicit">E</span>}
        </div>
        <div className="tr-sub">
          <Link to={`/artist/${track.artist.id}`} onClick={(e) => e.stopPropagation()}>
            {track.artist.name}
          </Link>
          {track.album && (
            <span className="hide-sm">
              {' • '}
              <Link to={`/album/${track.album.id}`}>{track.album.title}</Link>
            </span>
          )}
        </div>
      </div>
      {meta && <div className="tr-meta">{meta}</div>}
      <button className={`icon-btn tr-like ${liked ? 'on' : ''}`} aria-label={liked ? 'Remove from Liked Songs' : 'Add to Liked Songs'} onClick={() => toggleSaved('track', track.id)}>
        {liked ? <I.IconHeartFilled size={18} /> : <I.IconHeart size={18} />}
      </button>
      <div className="tr-dur">{formatMs(track.durationMs)}</div>
      <TrackMenu track={track} extra={extraMenu} />
    </div>
  );
}

// ---- Menus ----------------------------------------------------------------------------------------
export interface MenuItem {
  label: string;
  onClick: () => void;
  danger?: boolean;
}

export function Menu({ items, label = 'More options', icon }: { items: MenuItem[]; label?: string; icon?: ReactNode }) {
  const [open, setOpen] = useState<{ x: number; y: number } | null>(null);
  const btn = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (!open) return;
    const close = () => setOpen(null);
    const key = (e: KeyboardEvent) => e.key === 'Escape' && close();
    window.addEventListener('click', close);
    window.addEventListener('resize', close);
    window.addEventListener('keydown', key);
    document.addEventListener('scroll', close, true);
    return () => {
      window.removeEventListener('click', close);
      window.removeEventListener('resize', close);
      window.removeEventListener('keydown', key);
      document.removeEventListener('scroll', close, true);
    };
  }, [open]);
  return (
    <>
      <button
        ref={btn}
        className="icon-btn"
        aria-label={label}
        aria-haspopup="menu"
        onClick={(e) => {
          e.stopPropagation();
          e.preventDefault();
          const r = btn.current!.getBoundingClientRect();
          const h = items.length * 40 + 12;
          setOpen({ x: Math.min(r.right, window.innerWidth - 8), y: r.bottom + h > window.innerHeight - 8 ? Math.max(8, r.top - h) : r.bottom + 4 });
        }}
      >
        {icon ?? <I.IconMore size={18} />}
      </button>
      {open &&
        createPortal(
          <div className="menu" role="menu" style={{ left: open.x, top: open.y }} onClick={(e) => e.stopPropagation()}>
            {items.map((it) => (
              <button
                key={it.label}
                role="menuitem"
                className={it.danger ? 'danger' : ''}
                onClick={() => {
                  setOpen(null);
                  it.onClick();
                }}
              >
                {it.label}
              </button>
            ))}
          </div>,
          document.body,
        )}
    </>
  );
}

export function TrackMenu({ track, extra = [] }: { track: Track; extra?: MenuItem[] }) {
  const nav = useNavigate();
  const [picking, setPicking] = useState(false);
  const liked = useSaved('track', track.id);
  const cfg = useConfig();
  const items: MenuItem[] = [
    { label: 'Play next', onClick: () => controls.playNext([track]) },
    { label: 'Add to queue', onClick: () => controls.addToQueue([track]) },
    { label: 'Add to playlist…', onClick: () => setPicking(true) },
    { label: liked ? 'Remove from Liked Songs' : 'Add to Liked Songs', onClick: () => toggleSaved('track', track.id) },
    ...(cfg.features.radio ? [{ label: 'Go to artist radio', onClick: () => nav(`/mix/${encodeURIComponent(`artist:${track.artist.id}`)}`) }] : []),
    { label: 'Go to artist', onClick: () => nav(`/artist/${track.artist.id}`) },
    ...(track.album ? [{ label: 'Go to album', onClick: () => nav(`/album/${track.album!.id}`) }] : []),
    ...(track.videoId && cfg.features.videos ? [{ label: 'Watch video', onClick: () => nav(`/video/${track.videoId}`) }] : []),
    ...extra,
  ];
  return (
    <>
      <Menu items={items} />
      {picking && <PlaylistPicker trackIds={[track.id]} onClose={() => setPicking(false)} />}
    </>
  );
}

// ---- Dialogs --------------------------------------------------------------------------------------
export function Modal({ title, children, onClose, wide }: { title: string; children: ReactNode; onClose: () => void; wide?: boolean }) {
  useEffect(() => {
    const k = (e: KeyboardEvent) => e.key === 'Escape' && onClose();
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [onClose]);
  return createPortal(
    <div className="modal-backdrop" onMouseDown={onClose}>
      <div className={`modal ${wide ? 'wide' : ''}`} role="dialog" aria-modal="true" aria-label={title} onMouseDown={(e) => e.stopPropagation()}>
        <header>
          <h3>{title}</h3>
          <button className="icon-btn" aria-label="Close" onClick={onClose}>
            <I.IconClose />
          </button>
        </header>
        {children}
      </div>
    </div>,
    document.body,
  );
}

export function PromptDialog({ title, label, initial = '', confirm = 'Save', onSubmit, onClose }: { title: string; label: string; initial?: string; confirm?: string; onSubmit: (v: string) => Promise<void> | void; onClose: () => void }) {
  const [v, setV] = useState(initial);
  const [busy, setBusy] = useState(false);
  return (
    <Modal title={title} onClose={onClose}>
      <form
        className="form"
        onSubmit={async (e) => {
          e.preventDefault();
          if (!v.trim()) return;
          setBusy(true);
          try {
            await onSubmit(v.trim());
            onClose();
          } catch (err) {
            toast(errorText(err), 'error');
          } finally {
            setBusy(false);
          }
        }}
      >
        <label className="field">
          <span>{label}</span>
          <input autoFocus value={v} maxLength={200} onChange={(e) => setV(e.target.value)} />
        </label>
        <div className="row-end">
          <button type="button" className="pill" onClick={onClose}>
            Cancel
          </button>
          <button className="btn-accent" disabled={busy || !v.trim()}>
            {confirm}
          </button>
        </div>
      </form>
    </Modal>
  );
}

export function ConfirmDialog({ title, body, confirm, danger, onConfirm, onClose }: { title: string; body: ReactNode; confirm: string; danger?: boolean; onConfirm: () => Promise<void> | void; onClose: () => void }) {
  const [busy, setBusy] = useState(false);
  return (
    <Modal title={title} onClose={onClose}>
      <div className="muted" style={{ marginBottom: 20 }}>
        {body}
      </div>
      <div className="row-end">
        <button className="pill" onClick={onClose}>
          Cancel
        </button>
        <button
          className={danger ? 'btn-danger' : 'btn-accent'}
          disabled={busy}
          onClick={async () => {
            setBusy(true);
            try {
              await onConfirm();
              onClose();
            } catch (e) {
              toast(errorText(e), 'error');
            } finally {
              setBusy(false);
            }
          }}
        >
          {confirm}
        </button>
      </div>
    </Modal>
  );
}

export function PlaylistPicker({ trackIds, onClose }: { trackIds: string[]; onClose: () => void }) {
  const playlists = useApp((s) => s.playlists.filter((p) => p.canEdit));
  const [creating, setCreating] = useState(false);
  const add = async (id: string, title: string) => {
    try {
      await api.addToPlaylist(id, trackIds);
      toast(`Added to ${title}`, 'success');
      void refreshPlaylists();
      onClose();
    } catch (e) {
      toast(errorText(e), 'error');
    }
  };
  if (creating)
    return (
      <PromptDialog
        title="New playlist"
        label="Name"
        confirm="Create"
        onClose={onClose}
        onSubmit={async (title) => {
          const p = await api.createPlaylist(title);
          await api.addToPlaylist(p.playlist.id, trackIds);
          toast(`Added to ${title}`, 'success');
          void refreshPlaylists();
        }}
      />
    );
  return (
    <Modal title="Add to playlist" onClose={onClose}>
      <div className="picker">
        <button className="picker-row" onClick={() => setCreating(true)}>
          <span className="picker-icon">
            <I.IconPlus />
          </span>
          New playlist
        </button>
        {playlists.map((p) => (
          <button key={p.id} className="picker-row" onClick={() => add(p.id, p.title)}>
            <Artwork src={p.artworkUrl ?? p.mosaicUrls?.[0]} />
            <span>
              {p.title}
              <small className="muted"> · {p.itemCount} songs</small>
            </span>
          </button>
        ))}
      </div>
    </Modal>
  );
}

// ---- Play helpers ---------------------------------------------------------------------------------
export async function playAlbum(id: string, startIndex = 0, shuffle?: boolean) {
  try {
    const a = await api.album(id);
    controls.playTracks(a.tracks, startIndex, { type: 'album', id, title: a.album.title }, { shuffle });
  } catch (e) {
    toast(errorText(e), 'error');
  }
}

export async function playPlaylist(id: string, shuffle?: boolean) {
  try {
    const p = await api.playlist(id, 100);
    const tracks = p.items.items.map((i) => i.track).filter((t): t is Track => !!t);
    controls.playTracks(tracks, 0, { type: 'playlist', id, title: p.playlist.title }, { shuffle });
  } catch (e) {
    toast(errorText(e), 'error');
  }
}

export async function playMix(id: string) {
  try {
    const m = await api.mix(id);
    controls.playTracks(m.items.map((i) => i.track), 0, { type: 'mix', id, title: m.mix.title });
  } catch (e) {
    toast(errorText(e), 'error');
  }
}

export function useDebounced<T>(value: T, ms: number): T {
  const [v, setV] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setV(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return v;
}
