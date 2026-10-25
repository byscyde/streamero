import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, useSearchParams } from 'react-router-dom';
import * as I from '../components/Icons';
import { AlbumCard, ArtistCircle, Artwork, Carousel, Empty, ErrorState, GenreChip, Modal, PlaylistCard, Section, Spinner, TrackRow, useDebounced, VideoCard } from '../components/ui';
import { api, media } from '../lib/api';
import { genreGradient } from '../lib/appearance';
import type { GenreInfo, SearchResults, YouTubeResult } from '../lib/types';
import { controls } from '../player/player';
import { useConfig, useLoad } from '../state/app';

const FILTERS = [
  ['all', 'All'],
  ['tracks', 'Songs'],
  ['artists', 'Artists'],
  ['albums', 'Albums'],
  ['playlists', 'Playlists'],
  ['videos', 'Videos'],
  ['youtube', 'YouTube'],
] as const;
type Filter = (typeof FILTERS)[number][0];

function GenreTiles({ genres, kind = 'genre' }: { genres: GenreInfo[]; kind?: 'genre' | 'mood' }) {
  return (
    <div className="genre-tiles">
      {genres.map((g) => (
        <Link key={g.name} to={`/${kind}/${encodeURIComponent(g.name)}`} className="genre-tile" style={{ backgroundImage: genreGradient(g.name) }}>
          <span>{g.name}</span>
          {g.artworkUrl && <img src={media(g.artworkUrl)} alt="" loading="lazy" />}
        </Link>
      ))}
    </div>
  );
}

export function Search() {
  const cfg = useConfig();
  const [params, setParams] = useSearchParams();
  const [q, setQ] = useState(params.get('q') ?? '');
  const [filter, setFilter] = useState<Filter>((params.get('type') as Filter) ?? 'all');
  const dq = useDebounced(q.trim(), 300);
  const [res, setRes] = useState<{ q: string; r?: SearchResults; yt?: YouTubeResult[]; error?: Error; loading: boolean }>({ q: '', loading: false });
  const recent = useLoad(() => api.recentSearches(), [], 'none');
  const genres = useLoad(() => api.genres(), [], 'catalog');
  const yt = useLoad(() => (cfg.features.youtube ? api.youtubeStatus() : Promise.resolve({ enabled: false })), [cfg.features.youtube], 'none');
  const [embed, setEmbed] = useState<YouTubeResult | null>(null);
  const input = useRef<HTMLInputElement>(null);
  const filters = FILTERS.filter(([id]) => (id !== 'videos' || cfg.features.videos) && (id !== 'youtube' || (cfg.features.youtube && yt.data?.enabled)));

  useEffect(() => {
    setParams(dq ? { q: dq, ...(filter !== 'all' ? { type: filter } : {}) } : {}, { replace: true });
    if (!dq) return setRes({ q: '', loading: false });
    const ctl = new AbortController();
    setRes((s) => ({ ...s, loading: true }));
    const run = async () => {
      if (filter === 'youtube') {
        const r = await api.youtubeSearch(dq);
        return { yt: r.items };
      }
      const types = filter === 'all' ? ['tracks', 'artists', 'albums', 'playlists', ...(cfg.features.videos ? ['videos'] : []), 'genres'] : [filter];
      const r = await api.search(dq, types, filter === 'all' ? 10 : 40, ctl.signal);
      return { r: r.results };
    };
    run()
      .then((x) => !ctl.signal.aborted && setRes({ q: dq, loading: false, ...x }))
      .catch((error) => !ctl.signal.aborted && setRes({ q: dq, loading: false, error }));
    return () => ctl.abort();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [dq, filter]);

  const remember = () => {
    if (!dq) return;
    api.addRecentSearch(dq).then(() => recent.reload()).catch(() => undefined);
  };
  const r = res.r;
  const empty = r && !r.tracks?.items.length && !r.artists?.items.length && !r.albums?.items.length && !r.playlists?.items.length && !r.videos?.items.length && !r.genres?.items.length;

  return (
    <div className="page search-page">
      <form
        className="search-box"
        role="search"
        onSubmit={(e) => {
          e.preventDefault();
          remember();
          input.current?.blur();
        }}
      >
        <I.IconSearch size={20} />
        <input ref={input} type="search" placeholder="Artists, songs, albums, videos" aria-label="Search" value={q} onChange={(e) => setQ(e.target.value)} autoFocus />
        {q && (
          <button type="button" className="icon-btn" aria-label="Clear search" onClick={() => setQ('')}>
            <I.IconClose size={18} />
          </button>
        )}
      </form>
      {dq && (
        <div className="chip-row filter-chips" role="tablist">
          {filters.map(([id, label]) => (
            <button key={id} role="tab" aria-selected={filter === id} className={`chip ${filter === id ? 'active' : ''}`} onClick={() => setFilter(id)}>
              {label}
            </button>
          ))}
        </div>
      )}

      {!dq ? (
        <>
          {!!recent.data?.items.length && (
            <Section title="Recent searches" more={() => api.clearRecentSearches().then(() => recent.reload())}>
              <div className="chip-row">
                {recent.data.items.slice(0, 12).map((s) => (
                  <button key={s.query} className="chip" onClick={() => setQ(s.query)}>
                    <I.IconClock size={14} /> {s.query}
                  </button>
                ))}
              </div>
            </Section>
          )}
          <Section title="Browse genres">{genres.data ? <GenreTiles genres={genres.data.genres} /> : genres.loading ? <Spinner /> : null}</Section>
          {!!genres.data?.moods.length && (
            <Section title="Moods">
              <GenreTiles genres={genres.data.moods} kind="mood" />
            </Section>
          )}
        </>
      ) : res.loading && res.q !== dq ? (
        <Spinner />
      ) : res.error ? (
        <ErrorState error={res.error} />
      ) : filter === 'youtube' ? (
        <div onClick={remember}>
          <p className="muted small">Results from YouTube. Videos play in YouTube’s embedded player.</p>
          <div className="grid videos">
            {(res.yt ?? []).map((v) => (
              <button key={v.videoId} className="card video-card" onClick={() => setEmbed(v)}>
                <div className="card-art wide">
                  <Artwork src={v.thumbnailUrl} fallback="video" />
                </div>
                <div className="card-title">{v.title}</div>
                <div className="card-sub">{v.channelTitle}</div>
              </button>
            ))}
          </div>
          {embed && <YouTubeEmbed v={embed} onClose={() => setEmbed(null)} />}
        </div>
      ) : empty ? (
        <Empty title={`No results for “${dq}”`}>Check the spelling or try different words.</Empty>
      ) : r ? (
        <div onClick={remember}>
          {!!r.tracks?.items.length && (
            <Section title="Songs">
              <div className={filter === 'all' ? 'track-grid' : 'track-list'}>
                {r.tracks.items.map((t, i) => (
                  <TrackRow key={t.id} track={t} onPlay={() => controls.playTracks(r.tracks!.items, i, { type: 'search', title: dq })} />
                ))}
              </div>
            </Section>
          )}
          {!!r.artists?.items.length && (
            <Section title="Artists">
              <div className={filter === 'all' ? '' : 'grid artists'}>
                {filter === 'all' ? (
                  <Carousel className="artists">
                    {r.artists.items.map((a) => (
                      <ArtistCircle key={a.id} artist={a} />
                    ))}
                  </Carousel>
                ) : (
                  r.artists.items.map((a) => <ArtistCircle key={a.id} artist={a} />)
                )}
              </div>
            </Section>
          )}
          {!!r.albums?.items.length && (
            <Section title="Albums">
              {filter === 'all' ? (
                <Carousel>
                  {r.albums.items.map((a) => (
                    <AlbumCard key={a.id} album={a} />
                  ))}
                </Carousel>
              ) : (
                <div className="grid">
                  {r.albums.items.map((a) => (
                    <AlbumCard key={a.id} album={a} />
                  ))}
                </div>
              )}
            </Section>
          )}
          {!!r.playlists?.items.length && (
            <Section title="Playlists">
              <div className={filter === 'all' ? '' : 'grid'}>
                {filter === 'all' ? (
                  <Carousel>
                    {r.playlists.items.map((p) => (
                      <PlaylistCard key={p.id} playlist={p} />
                    ))}
                  </Carousel>
                ) : (
                  r.playlists.items.map((p) => <PlaylistCard key={p.id} playlist={p} />)
                )}
              </div>
            </Section>
          )}
          {!!r.videos?.items.length && (
            <Section title="Videos">
              <div className="grid videos">
                {r.videos.items.map((v) => (
                  <VideoCard key={v.id} video={v} />
                ))}
              </div>
            </Section>
          )}
          {!!r.genres?.items.length && (
            <Section title="Genres">
              <div className="chip-row">
                {r.genres.items.map((g) => (
                  <GenreChip key={g.name} name={g.name} kind={g.kind === 'mood' ? 'mood' : 'genre'} />
                ))}
              </div>
            </Section>
          )}
        </div>
      ) : null}
    </div>
  );
}

function YouTubeEmbed({ v, onClose }: { v: YouTubeResult; onClose: () => void }) {
  const src = useMemo(() => {
    try {
      const u = new URL(v.embedUrl);
      if (['www.youtube-nocookie.com', 'www.youtube.com'].includes(u.hostname)) return u.toString();
    } catch {
      /* fall through */
    }
    return `https://www.youtube-nocookie.com/embed/${encodeURIComponent(v.videoId)}`;
  }, [v]);
  return (
    <Modal title={v.title} onClose={onClose} wide>
      <div className="yt-frame">
        <iframe src={src} title={v.title} allow="accelerometer; autoplay; encrypted-media; picture-in-picture" allowFullScreen referrerPolicy="strict-origin-when-cross-origin" />
      </div>
      <p className="muted small">
        <a href={v.watchUrl} target="_blank" rel="noopener noreferrer">
          Watch on YouTube
        </a>
      </p>
    </Modal>
  );
}

export function Explore() {
  const cfg = useConfig();
  const genres = useLoad(() => api.genres(), [], 'catalog');
  const artists = useLoad(() => api.artists(50).then((p) => ({ ...p, items: [...p.items].sort((a, b) => (b.followerCount ?? 0) - (a.followerCount ?? 0)).slice(0, 20) })), [], 'catalog');
  const albums = useLoad(() => api.albums(20, 0, 'recent'), [], 'catalog');
  const videos = useLoad(() => (cfg.features.videos ? api.videos(20) : Promise.resolve(null)), [cfg.features.videos], 'catalog');
  const trending = useLoad(() => api.trending(), [], 'catalog');
  useEffect(() => {
    const h = location.hash.slice(1);
    if (h) setTimeout(() => document.getElementById(h)?.scrollIntoView({ behavior: 'smooth' }), 300);
  }, []);
  return (
    <div className="page explore">
      <h1 className="page-title">Explore</h1>
      <div id="genres">
        <Section title="Genres">
          {genres.data ? (
            <div className="chip-row scroll">
              {genres.data.genres.map((g) => (
                <GenreChip key={g.name} name={g.name} />
              ))}
            </div>
          ) : genres.loading ? (
            <Spinner />
          ) : null}
        </Section>
      </div>
      <div id="artists">
        {!!artists.data?.items.length && (
          <Section title="Top artist">
            <Carousel className="artists">
              {artists.data.items.map((a) => (
                <ArtistCircle key={a.id} artist={a} />
              ))}
            </Carousel>
          </Section>
        )}
      </div>
      <div id="albums">
        {!!albums.data?.items.length && (
          <Section title="New albums">
            <Carousel>
              {albums.data.items.map((a) => (
                <AlbumCard key={a.id} album={a} />
              ))}
            </Carousel>
          </Section>
        )}
      </div>
      {!!trending.data?.items.length && (
        <Section title="Popular singles">
          <div className="track-grid">
            {trending.data.items.slice(0, 12).map((t, i) => (
              <TrackRow key={t.id} track={t} onPlay={() => controls.playTracks(trending.data!.items, i, { type: 'trending', title: 'Popular singles' })} />
            ))}
          </div>
        </Section>
      )}
      <div id="videos">
        {cfg.features.videos && !!videos.data?.items.length && (
          <Section title="Music videos">
            <Carousel className="videos">
              {videos.data.items.map((v) => (
                <VideoCard key={v.id} video={v} />
              ))}
            </Carousel>
          </Section>
        )}
      </div>
      {!!genres.data?.moods.length && (
        <Section title="Moods">
          <GenreTiles genres={genres.data.moods} kind="mood" />
        </Section>
      )}
    </div>
  );
}
