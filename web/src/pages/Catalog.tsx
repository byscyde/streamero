import { useMemo, useRef, useState } from 'react';
import { Link, useNavigate, useParams } from 'react-router-dom';
import * as I from '../components/Icons';
import {
  AlbumCard, ArtistCircle, Artwork, Carousel, ConfirmDialog, Empty, ErrorState, Menu, PlayButton, PlaylistPicker, PromptDialog,
  Section, Spinner, TrackRow, VideoCard, artUrl,
} from '../components/ui';
import { api, ApiError } from '../lib/api';
import { genreGradient } from '../lib/appearance';
import { compactNumber, formatDuration, plural } from '../lib/format';
import type { Album, PlaylistItem, Track } from '../lib/types';
import { controls, useCurrentTrack, usePlayer } from '../player/player';
import { refreshPlaylists, toggleSaved, useConfig, useLoad, useSaved } from '../state/app';
import { errorText, toast } from '../state/store';

function usePlayingContext(type: string, id: string | undefined) {
  const ctx = usePlayer((s) => s.queue.context);
  const playing = usePlayer((s) => s.playing);
  return !!id && ctx?.type === type && ctx?.id === id && playing;
}

function PageState({ loading, error, reload }: { loading: boolean; error?: Error; reload: () => void }) {
  if (loading) return <Spinner />;
  if (error) return error instanceof ApiError && error.status === 404 ? <Empty title="Not found">This page doesn’t exist or was removed.</Empty> : <ErrorState error={error} onRetry={reload} />;
  return null;
}

// ---- Artist ---------------------------------------------------------------------------------------
export function ArtistPage() {
  const { id = '' } = useParams();
  const cfg = useConfig();
  const nav = useNavigate();
  const r = useLoad(() => api.artist(id), [id]);
  const following = useSaved('artist', id);
  const [allTop, setAllTop] = useState(false);
  const [slide, setSlide] = useState(0);
  const playingHere = usePlayingContext('artist', id);
  const newest = useMemo(() => {
    if (!r.data) return [];
    const all = [...r.data.releases.albums, ...r.data.releases.singles, ...r.data.releases.compilations];
    return all.sort((a, b) => (b.releaseDate ?? '').localeCompare(a.releaseDate ?? '')).slice(0, 3);
  }, [r.data]);
  if (!r.data) return <PageState {...r} />;
  const { artist, topTracks, releases, videos, related } = r.data;
  const top = allTop ? topTracks : topTracks.slice(0, 5);
  const ctx = { type: 'artist', id, title: artist.name };
  const followers = (artist.followerCount ?? 0) + (following && !artist.isFollowed ? 1 : !following && artist.isFollowed ? -1 : 0);
  const heroArt = artUrl(artist.artworkUrl, 'large');
  return (
    <div className="page artist-page">
      <header className="artist-hero">
        {heroArt ? <div className="artist-hero-img" style={{ backgroundImage: `url("${heroArt}")` }} /> : <div className="artist-hero-img empty" style={{ backgroundImage: genreGradient(artist.name) }} />}
        <div className="artist-hero-fade" />
        <div className="artist-hero-content">
          <h1 className="artist-name title-font">{artist.name}</h1>
          <p className="artist-followers">{compactNumber(Math.max(0, followers))} Followers</p>
        </div>
      </header>
      <div className="artist-actions">
        <button className={following ? 'pill pill-lg' : 'btn-accent pill-lg'} onClick={() => toggleSaved('artist', id, artist.name)} aria-pressed={following}>
          {following ? 'Following' : 'Follow'}
        </button>
        <button className="pill pill-lg" onClick={() => controls.playTracks(topTracks, 0, ctx, { shuffle: true })} disabled={!topTracks.length}>
          <I.IconShuffle size={18} /> Shuffle
        </button>
        {cfg.features.radio && (
          <button className="pill pill-lg" onClick={() => nav(`/mix/${encodeURIComponent(`artist:${id}`)}`)}>
            <I.IconRadio size={18} /> Radio
          </button>
        )}
        <span className="spacer" />
        {topTracks.length > 0 && <PlayButton size={56} variant="accent" playing={playingHere} onClick={() => (playingHere ? controls.pause() : controls.playTracks(topTracks, 0, ctx))} />}
      </div>

      <div className="artist-grid">
        {newest.length > 0 && (
          <Section title="New releases" className="new-releases">
            <div className="release-card">
              <Link to={`/album/${newest[slide].id}`} className="release-link">
                <Artwork src={newest[slide].artworkUrl} />
                <div>
                  <div className="release-title title-font">{newest[slide].title}</div>
                  <div className="muted">
                    {labelType(newest[slide])}
                    {newest[slide].releaseDate ? ` • ${newest[slide].releaseDate!.slice(0, 4)}` : ''} • {plural(newest[slide].trackCount, 'Song')}
                  </div>
                </div>
              </Link>
              <PlayButton size={60} onClick={() => playAlbumById(newest[slide].id)} />
            </div>
            {newest.length > 1 && (
              <div className="dots" role="tablist">
                {newest.map((a, i) => (
                  <button key={a.id} role="tab" aria-label={a.title} aria-selected={i === slide} className={i === slide ? 'active' : ''} onClick={() => setSlide(i)} />
                ))}
              </div>
            )}
          </Section>
        )}

        {topTracks.length > 0 && (
          <Section title="Top songs" more={topTracks.length > 5 ? () => setAllTop((v) => !v) : undefined} className="top-songs">
            <div className="track-list">
              {top.map((t, i) => (
                <TrackRow key={t.id} track={t} onPlay={() => controls.playTracks(topTracks, i, ctx)} meta={t.playCount ? `${compactNumber(t.playCount)} plays` : undefined} />
              ))}
            </div>
          </Section>
        )}
      </div>

      {releases.albums.length > 0 && (
        <Section title="Albums">
          <Carousel>
            {releases.albums.map((a) => (
              <AlbumCard key={a.id} album={a} />
            ))}
          </Carousel>
        </Section>
      )}
      {releases.singles.length > 0 && (
        <Section title="Singles & EPs">
          <Carousel>
            {releases.singles.map((a) => (
              <AlbumCard key={a.id} album={a} />
            ))}
          </Carousel>
        </Section>
      )}
      {releases.compilations.length > 0 && (
        <Section title="Compilations">
          <Carousel>
            {releases.compilations.map((a) => (
              <AlbumCard key={a.id} album={a} />
            ))}
          </Carousel>
        </Section>
      )}
      {cfg.features.videos && videos.length > 0 && (
        <Section title="Videos">
          <Carousel className="videos">
            {videos.map((v) => (
              <VideoCard key={v.id} video={v} />
            ))}
          </Carousel>
        </Section>
      )}
      {artist.bio && (
        <Section title="About">
          <p className="bio">{artist.bio}</p>
        </Section>
      )}
      {related.length > 0 && (
        <Section title="Fans also like">
          <Carousel className="artists">
            {related.map((a) => (
              <ArtistCircle key={a.id} artist={a} />
            ))}
          </Carousel>
        </Section>
      )}
    </div>
  );
}

const labelType = (a: Album) => (a.albumType === 'ep' ? 'EP' : a.albumType ? a.albumType[0].toUpperCase() + a.albumType.slice(1) : 'Album');

async function playAlbumById(id: string) {
  try {
    const a = await api.album(id);
    controls.playTracks(a.tracks, 0, { type: 'album', id, title: a.album.title });
  } catch (e) {
    toast(errorText(e), 'error');
  }
}

// ---- Collection header (album / playlist / mix / genre) -------------------------------------------
function CollectionHeader({ art, mosaic, kicker, title, children, gradient }: { art?: string | null; mosaic?: string[]; kicker: string; title: string; children?: React.ReactNode; gradient?: string }) {
  const bg = artUrl(art ?? mosaic?.[0], 'large');
  return (
    <header className="collection-head">
      <div className="ch-bg" style={bg ? { backgroundImage: `url("${bg}")` } : gradient ? { backgroundImage: gradient } : undefined} />
      <div className="ch-inner">
        <div className="ch-art">
          {mosaic && mosaic.length >= 4 && !art ? (
            <div className="mosaic">
              {mosaic.slice(0, 4).map((m, i) => (
                <Artwork key={i} src={m} />
              ))}
            </div>
          ) : gradient && !art ? (
            <div className="art gradient-art" style={{ backgroundImage: gradient }} />
          ) : (
            <Artwork src={art ?? mosaic?.[0]} size="large" />
          )}
        </div>
        <div className="ch-text">
          <span className="ch-kicker">{kicker}</span>
          <h1 className="ch-title title-font">{title}</h1>
          <div className="ch-meta">{children}</div>
        </div>
      </div>
    </header>
  );
}

function ActionBar({ playing, onPlay, onShuffle, children }: { playing: boolean; onPlay: () => void; onShuffle?: () => void; children?: React.ReactNode }) {
  return (
    <div className="action-bar">
      <PlayButton size={60} playing={playing} onClick={() => (playing ? controls.pause() : onPlay())} />
      {onShuffle && (
        <button className="icon-btn big" aria-label="Shuffle play" onClick={onShuffle}>
          <I.IconShuffle size={26} />
        </button>
      )}
      {children}
    </div>
  );
}

// ---- Album ----------------------------------------------------------------------------------------
export function AlbumPage() {
  const { id = '' } = useParams();
  const r = useLoad(() => api.album(id), [id]);
  const saved = useSaved('album', id);
  const playing = usePlayingContext('album', id);
  const [picking, setPicking] = useState(false);
  if (!r.data) return <PageState {...r} />;
  const { album, tracks, moreByArtist, related } = r.data;
  const ctx = { type: 'album', id, title: album.title };
  const multiDisc = new Set(tracks.map((t) => t.discNumber ?? 1)).size > 1;
  return (
    <div className="page">
      <CollectionHeader art={album.artworkUrl} kicker={labelType(album)} title={album.title}>
        <Link to={`/artist/${album.artist.id}`} className="strong">
          {album.artist.name}
        </Link>
        {album.releaseDate && <span> • {album.releaseDate.slice(0, 4)}</span>}
        <span> • {plural(album.trackCount || tracks.length, 'song')}</span>
        <span> • {formatDuration(album.durationMs)}</span>
      </CollectionHeader>
      <ActionBar playing={playing} onPlay={() => controls.playTracks(tracks, 0, ctx)} onShuffle={() => controls.playTracks(tracks, 0, ctx, { shuffle: true })}>
        <button className={`icon-btn big ${saved ? 'on' : ''}`} aria-label={saved ? 'Remove album from library' : 'Save album'} onClick={() => toggleSaved('album', id)}>
          {saved ? <I.IconHeartFilled size={28} /> : <I.IconHeart size={28} />}
        </button>
        <Menu
          icon={<I.IconMoreH size={26} />}
          items={[
            { label: 'Add to queue', onClick: () => controls.addToQueue(tracks) },
            { label: 'Play next', onClick: () => controls.playNext(tracks) },
            { label: 'Add to playlist…', onClick: () => setPicking(true) },
          ]}
        />
      </ActionBar>
      {picking && <PlaylistPicker trackIds={tracks.map((t) => t.id)} onClose={() => setPicking(false)} />}
      <div className="track-list numbered">
        {tracks.map((t, i) => (
          <div key={t.id}>
            {multiDisc && (i === 0 || (tracks[i - 1].discNumber ?? 1) !== (t.discNumber ?? 1)) && <h4 className="disc">Disc {t.discNumber ?? 1}</h4>}
            <TrackRow track={t} number={t.trackNumber ?? i + 1} showArt={false} onPlay={() => controls.playTracks(tracks, i, ctx)} />
          </div>
        ))}
      </div>
      {album.label && <p className="muted small label-line">{album.releaseDate ?? ''} {album.label ? `℗ ${album.label}` : ''}</p>}
      {moreByArtist.length > 0 && (
        <Section title={`More by ${album.artist.name}`} more={`/artist/${album.artist.id}`}>
          <Carousel>
            {moreByArtist.map((a) => (
              <AlbumCard key={a.id} album={a} />
            ))}
          </Carousel>
        </Section>
      )}
      {related.length > 0 && (
        <Section title="You might also like">
          <Carousel>
            {related.map((a) => (
              <AlbumCard key={a.id} album={a} />
            ))}
          </Carousel>
        </Section>
      )}
    </div>
  );
}

// ---- Playlist -------------------------------------------------------------------------------------
export function PlaylistPage() {
  const { id = '' } = useParams();
  const nav = useNavigate();
  const r = useLoad(() => api.playlist(id, 100), [id]);
  const saved = useSaved('playlist', id);
  const playing = usePlayingContext('playlist', id);
  const [dialog, setDialog] = useState<'rename' | 'describe' | 'delete' | null>(null);
  const [dragFrom, setDragFrom] = useState<number | null>(null);
  const busy = useRef(false);
  if (!r.data) return <PageState {...r} />;
  const { playlist, items } = r.data;
  const rows = items.items.filter((i) => i.track) as (PlaylistItem & { track: Track })[];
  const tracks = rows.map((i) => i.track);
  const ctx = { type: 'playlist', id, title: playlist.title };

  const mutate = async (fn: () => Promise<typeof r.data>, optimistic?: PlaylistItem[]) => {
    if (busy.current) return;
    busy.current = true;
    const prev = r.data;
    if (optimistic) r.setData((d) => (d ? { ...d, items: { ...d.items, items: optimistic } } : d));
    try {
      const next = await fn();
      if (next) r.setData(() => next);
      void refreshPlaylists();
    } catch (e) {
      r.setData(() => prev);
      if (e instanceof ApiError && e.code === 'version_conflict') {
        toast('This playlist changed on another device. Reloaded.', 'error');
        r.reload();
      } else toast(errorText(e), 'error');
    } finally {
      busy.current = false;
    }
  };
  const reorder = (from: number, to: number) => {
    if (from === to || to < 0 || to >= items.items.length) return;
    const list = items.items.slice();
    const [m] = list.splice(from, 1);
    list.splice(to, 0, m);
    void mutate(() => api.reorderPlaylist(id, list.map((i) => i.itemId), playlist.version), list);
  };
  const removeItem = (itemId: string) =>
    mutate(() => api.removeFromPlaylist(id, [itemId], playlist.version), items.items.filter((i) => i.itemId !== itemId));

  const menu = [
    { label: 'Add to queue', onClick: () => controls.addToQueue(tracks) },
    ...(playlist.shareUrl
      ? [{ label: 'Copy share link', onClick: () => navigator.clipboard?.writeText(playlist.shareUrl!).then(() => toast('Link copied', 'success')) }]
      : []),
    ...(playlist.isOwner || playlist.canEdit
      ? [
          { label: 'Rename', onClick: () => setDialog('rename') },
          { label: 'Edit description', onClick: () => setDialog('describe') },
          {
            label: playlist.visibility === 'public' ? 'Make private' : 'Make public',
            onClick: () => mutate(() => api.updatePlaylist(id, { visibility: playlist.visibility === 'public' ? 'private' : 'public', expectedVersion: playlist.version })),
          },
        ]
      : []),
    ...(playlist.isOwner ? [{ label: 'Delete playlist', danger: true, onClick: () => setDialog('delete') }] : []),
  ];

  return (
    <div className="page">
      <CollectionHeader art={playlist.artworkUrl} mosaic={playlist.mosaicUrls} kicker={playlist.isEditorial ? 'Featured playlist' : playlist.visibility === 'public' ? 'Public playlist' : 'Playlist'} title={playlist.title}>
        {playlist.description && <p className="ch-desc">{playlist.description}</p>}
        <span className="strong">{playlist.isEditorial ? 'STREAMERO' : playlist.owner?.displayName}</span>
        <span> • {plural(playlist.itemCount, 'song')}</span>
        {playlist.durationMs > 0 && <span> • {formatDuration(playlist.durationMs)}</span>}
      </CollectionHeader>
      <ActionBar playing={playing} onPlay={() => controls.playTracks(tracks, 0, ctx)} onShuffle={tracks.length ? () => controls.playTracks(tracks, 0, ctx, { shuffle: true }) : undefined}>
        {!playlist.isOwner && (
          <button className={`icon-btn big ${saved ? 'on' : ''}`} aria-label={saved ? 'Remove from library' : 'Save playlist'} onClick={() => toggleSaved('playlist', id)}>
            {saved ? <I.IconHeartFilled size={28} /> : <I.IconHeart size={28} />}
          </button>
        )}
        <Menu icon={<I.IconMoreH size={26} />} items={menu} />
      </ActionBar>
      {rows.length === 0 ? (
        <Empty title="This playlist is empty">{playlist.canEdit ? 'Add songs from any track’s menu → “Add to playlist…”.' : null}</Empty>
      ) : (
        <div className="track-list">
          {rows.map((it, i) => {
            const idx = items.items.indexOf(it);
            return (
              <div
                key={it.itemId}
                className={`pl-row ${dragFrom === idx ? 'dragging' : ''}`}
                draggable={playlist.canEdit}
                onDragStart={() => setDragFrom(idx)}
                onDragOver={(e) => playlist.canEdit && e.preventDefault()}
                onDrop={(e) => {
                  e.preventDefault();
                  if (dragFrom !== null) reorder(dragFrom, idx);
                  setDragFrom(null);
                }}
                onDragEnd={() => setDragFrom(null)}
              >
                <TrackRow
                  track={it.track}
                  onPlay={() => controls.playTracks(tracks, i, ctx)}
                  dragHandle={playlist.canEdit ? <span className="drag-handle" aria-hidden><I.IconDrag size={14} /></span> : undefined}
                  extraMenu={
                    playlist.canEdit
                      ? [
                          ...(idx > 0 ? [{ label: 'Move up', onClick: () => reorder(idx, idx - 1) }] : []),
                          ...(idx < items.items.length - 1 ? [{ label: 'Move down', onClick: () => reorder(idx, idx + 1) }] : []),
                          { label: 'Remove from this playlist', danger: true, onClick: () => void removeItem(it.itemId) },
                        ]
                      : undefined
                  }
                />
              </div>
            );
          })}
        </div>
      )}
      {dialog === 'rename' && (
        <PromptDialog title="Rename playlist" label="Name" initial={playlist.title} onClose={() => setDialog(null)} onSubmit={(title) => mutate(() => api.updatePlaylist(id, { title, expectedVersion: playlist.version }))} />
      )}
      {dialog === 'describe' && (
        <PromptDialog title="Edit description" label="Description" initial={playlist.description ?? ''} onClose={() => setDialog(null)} onSubmit={(description) => mutate(() => api.updatePlaylist(id, { description, expectedVersion: playlist.version }))} />
      )}
      {dialog === 'delete' && (
        <ConfirmDialog
          title="Delete playlist?"
          body={`“${playlist.title}” will be deleted for everyone. This can’t be undone.`}
          confirm="Delete"
          danger
          onClose={() => setDialog(null)}
          onConfirm={async () => {
            await api.deletePlaylist(id);
            await refreshPlaylists();
            toast('Playlist deleted', 'success');
            nav('/library');
          }}
        />
      )}
    </div>
  );
}

// ---- Mix ------------------------------------------------------------------------------------------
export function MixPage() {
  const { id = '' } = useParams();
  const r = useLoad(() => api.mix(id), [id]);
  const playing = usePlayingContext('mix', id);
  if (!r.data) return <PageState {...r} />;
  const { mix, items } = r.data;
  const tracks = items.map((i) => i.track);
  const ctx = { type: mix.kind === 'artist' ? 'radio' : 'mix', id, title: mix.title };
  return (
    <div className="page">
      <CollectionHeader mosaic={mix.artworkUrls ?? []} kicker={mix.kind === 'artist' ? 'Radio' : 'Mix'} title={mix.title} gradient={genreGradient(mix.title)}>
        <p className="ch-desc">{mix.description}</p>
        <span>{plural(tracks.length, 'song')}</span>
      </CollectionHeader>
      <ActionBar playing={playing} onPlay={() => controls.playTracks(tracks, 0, ctx)} onShuffle={() => controls.playTracks(tracks, 0, ctx, { shuffle: true })} />
      {tracks.length === 0 ? (
        <Empty title="Nothing in this mix yet">Listen to more music and check back.</Empty>
      ) : (
        <div className="track-list">
          {tracks.map((t, i) => (
            <TrackRow key={`${t.id}-${i}`} track={t} onPlay={() => controls.playTracks(tracks, i, ctx)} />
          ))}
        </div>
      )}
    </div>
  );
}

// ---- Genre / mood ---------------------------------------------------------------------------------
export function GenrePage({ kind }: { kind: 'genre' | 'mood' }) {
  const { name = '' } = useParams();
  const r = useLoad(() => api.tagTracks(kind, name, 100), [kind, name]);
  const cur = useCurrentTrack();
  const playing = usePlayingContext(kind, name) && !!cur;
  if (!r.data) return <PageState {...r} />;
  const tracks = r.data.items;
  const ctx = { type: kind, id: name, title: name };
  return (
    <div className="page">
      <CollectionHeader kicker={kind === 'mood' ? 'Mood' : 'Genre'} title={name} gradient={genreGradient(name)}>
        <span>{plural(r.data.total ?? tracks.length, 'song')}</span>
      </CollectionHeader>
      <ActionBar playing={playing} onPlay={() => controls.playTracks(tracks, 0, ctx)} onShuffle={() => controls.playTracks(tracks, 0, ctx, { shuffle: true })} />
      {tracks.length === 0 ? (
        <Empty title="No songs yet" />
      ) : (
        <div className="track-list">
          {tracks.map((t, i) => (
            <TrackRow key={t.id} track={t} onPlay={() => controls.playTracks(tracks, i, ctx)} />
          ))}
        </div>
      )}
    </div>
  );
}
