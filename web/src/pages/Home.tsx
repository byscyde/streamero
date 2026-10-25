import { useState } from 'react';
import { Link } from 'react-router-dom';
import { IconBell } from '../components/Icons';
import { AlbumCard, ArtistCircle, Artwork, Carousel, Empty, ErrorState, GenreChip, MixCard, PlaylistCard, Section, Spinner, TrackRow, VideoCard } from '../components/ui';
import { api } from '../lib/api';
import { arrangeHomeSections } from '../lib/appearance';
import { greetingFor } from '../lib/format';
import type { HomeItem, HomeSection, Track } from '../lib/types';
import { controls } from '../player/player';
import { useConfig, useLoad, useUser } from '../state/app';

const MORE: Record<string, string> = {
  genres: '/explore#genres',
  moods: '/explore#genres',
  favorite_artists: '/explore#artists',
  recently_added: '/explore#albums',
  album_recommendations: '/explore#albums',
  music_videos: '/explore#videos',
  continue_watching: '/library/videos',
  recently_played: '/library/history',
  continue_listening: '/library/history',
};

export function HomeItemView({ item, siblings, section }: { item: HomeItem; siblings: HomeItem[]; section: HomeSection }) {
  switch (item.type) {
    case 'album':
      return <AlbumCard album={item} />;
    case 'playlist':
      return <PlaylistCard playlist={item} />;
    case 'artist':
      return <ArtistCircle artist={item} />;
    case 'video':
      return <VideoCard video={item} />;
    case 'mix':
      return <MixCard mix={item} />;
    case 'genre':
    case 'mood':
      return <GenreChip name={item.name} kind={item.type} />;
    case 'track': {
      const tracks = siblings.filter((s): s is Extract<HomeItem, { type: 'track' }> => s.type === 'track');
      const i = tracks.findIndex((t) => t.id === item.id);
      return (
        <button className="card track-card" onClick={() => controls.playTracks(tracks as Track[], i, { type: 'home', title: section.title })}>
          <div className="card-art">
            <Artwork src={item.artworkUrl ?? item.album?.artworkUrl} size="large" />
          </div>
          <div className="card-title title-font">{item.title}</div>
          <div className="card-sub">Song • {item.artist.name}</div>
        </button>
      );
    }
    default:
      return null;
  }
}

export function HomeSectionView({ section }: { section: HomeSection }) {
  const items = section.items;
  const more = MORE[section.kind];
  const allTracks = items.every((i) => i.type === 'track');
  if (section.layout === 'chips' || items.every((i) => i.type === 'genre' || i.type === 'mood')) {
    return (
      <Section title={section.title} more={more}>
        <div className="chip-row scroll">
          {items.map((it, i) => (
            <HomeItemView key={i} item={it} siblings={items} section={section} />
          ))}
        </div>
      </Section>
    );
  }
  if (section.layout === 'list' && allTracks) {
    const tracks = items as Track[];
    return (
      <Section title={section.title} more={more}>
        <div className="track-grid">
          {tracks.slice(0, 12).map((t, i) => (
            <TrackRow key={t.id} track={t} onPlay={() => controls.playTracks(tracks, i, { type: 'home', title: section.title })} />
          ))}
        </div>
      </Section>
    );
  }
  const artists = items.every((i) => i.type === 'artist');
  const videos = items.every((i) => i.type === 'video');
  return (
    <Section title={section.title} more={more}>
      {section.subtitle && <p className="section-sub">{section.subtitle}</p>}
      <Carousel className={artists ? 'artists' : videos ? 'videos' : section.layout === 'hero' ? 'hero' : ''}>
        {items.map((it, i) => (
          <HomeItemView key={`${it.type}:${'id' in it ? it.id : i}`} item={it} siblings={items} section={section} />
        ))}
      </Carousel>
    </Section>
  );
}

export default function Home() {
  const cfg = useConfig();
  const user = useUser();
  const chips = cfg.home.chips.filter((c) => c !== 'Videos' || cfg.features.videos);
  const [chip, setChip] = useState(chips[0] ?? 'All');
  const home = useLoad(() => api.home(), []);
  const sections = home.data ? arrangeHomeSections(home.data.sections, cfg, chip) : [];
  return (
    <div className="page home">
      {cfg.texts.homeGreeting && (
        <header className="greeting">
          <Link to="/settings" className="greeting-avatar" aria-label="Profile">
            <Artwork src={user?.avatarUrl} round fallback="user" />
          </Link>
          <div>
            <div className="greeting-hello">{greetingFor(new Date().getHours()).replace(/, .*/, '')}</div>
            <div className="greeting-name">{user?.displayName}</div>
          </div>
          <span className="spacer" />
          <Link to="/library/history" className="icon-btn" aria-label="Recently played">
            <IconBell />
          </Link>
        </header>
      )}
      {chips.length > 1 && (
        <div className="seg-chips" role="tablist">
          {chips.map((c) => (
            <button key={c} role="tab" aria-selected={chip === c} className={chip === c ? 'active' : ''} onClick={() => setChip(c)}>
              {c}
            </button>
          ))}
        </div>
      )}
      {home.loading && !home.data ? (
        <Spinner />
      ) : home.error && !home.data ? (
        <ErrorState error={home.error} onRetry={home.reload} />
      ) : home.data?.isCatalogEmpty ? (
        <Empty title="Nothing here yet">The catalog is empty. Once an administrator uploads music, it shows up here.</Empty>
      ) : sections.length === 0 ? (
        <Empty title="Nothing to show">Try another filter.</Empty>
      ) : (
        sections.map((s) => <HomeSectionView key={s.id} section={s} />)
      )}
    </div>
  );
}
