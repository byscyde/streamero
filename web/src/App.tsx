import { lazy, Suspense, useEffect, useRef, useState, type ReactNode } from 'react';
import { Link, Navigate, NavLink, Outlet, Route, Routes, useLocation, useNavigate } from 'react-router-dom';
import * as I from './components/Icons';
import { Artwork, Empty, Spinner } from './components/ui';
import { ArtistPage, AlbumPage, GenrePage, MixPage, PlaylistPage } from './pages/Catalog';
import { ForgotPassword, GoogleCallback, Login, ResetPassword, Signup, VerifyEmail, Welcome } from './pages/Auth';
import { Explore, Search } from './pages/Discover';
import Home from './pages/Home';
import Library, { CreatePlaylistButton } from './pages/Library';
import Settings from './pages/Settings';
import { FullPlayer, MiniPlayer, NowPlayingBar, SidePanel, useKeyboardShortcuts } from './player/PlayerUI';
import { installMediaSession, useCurrentTrack, usePlayer } from './player/player';
import { startSyncPolling, useApp, useConfig, useUser } from './state/app';
import { toasts, useStore } from './state/store';

const VideoPage = lazy(() => import('./pages/Video'));

function Logo() {
  const cfg = useConfig();
  return (
    <Link to="/" className="logo" aria-label={`${cfg.brand.appName} home`}>
      <img src="/logo-mark.svg" alt="" width={34} height={34} />
      <span className="logo-text">{cfg.brand.appName}</span>
    </Link>
  );
}

function Sidebar() {
  const playlists = useApp((s) => s.playlists);
  const cfg = useConfig();
  const user = useUser();
  return (
    <aside className="sidebar" aria-label="Main navigation">
      <Logo />
      <nav className="side-nav">
        <NavLink to="/" end>
          <I.IconHome /> Home
        </NavLink>
        <NavLink to="/search">
          <I.IconSearch /> Search
        </NavLink>
        <NavLink to="/explore">
          <I.IconExplore /> Explore
        </NavLink>
        <NavLink to="/library">
          <I.IconLibrary /> Your Library
        </NavLink>
      </nav>
      <div className="side-section">
        <div className="side-section-head">
          <span>Playlists</span>
          <CreatePlaylistButton className="icon-btn small-plus" />
        </div>
        <div className="side-playlists">
          <NavLink to="/library/liked" className="side-pl">
            <span className="art liked-art sm">
              <I.IconHeartFilled size={14} />
            </span>
            <span className="side-pl-title">Liked Songs</span>
          </NavLink>
          {playlists.map((p) => (
            <NavLink key={p.id} to={`/playlist/${p.id}`} className="side-pl">
              <Artwork src={p.artworkUrl ?? p.mosaicUrls?.[0]} className="sm" />
              <span className="side-pl-title">{p.title}</span>
            </NavLink>
          ))}
        </div>
      </div>
      <div className="side-foot">
        <NavLink to="/settings" className="side-user">
          <Artwork src={user?.avatarUrl} round fallback="user" className="sm" />
          <span>{user?.displayName}</span>
          <I.IconSettings size={18} />
        </NavLink>
        <a className="by" href={cfg.brand.developerUrl} target="_blank" rel="noopener noreferrer">
          {cfg.brand.appName} by {cfg.brand.developer}
        </a>
      </div>
    </aside>
  );
}

function MobileTabs() {
  const loc = useLocation();
  const home = loc.pathname === '/';
  return (
    <nav className="mobile-tabs" aria-label="Main navigation">
      <NavLink to="/" end>
        {home ? <I.IconHomeFilled /> : <I.IconHome />}
        <span>Home</span>
      </NavLink>
      <NavLink to="/search">
        <I.IconSearch />
        <span>Search</span>
      </NavLink>
      <NavLink to="/explore">
        <I.IconExplore />
        <span>Explore</span>
      </NavLink>
      <NavLink to="/library">
        <I.IconLibrary />
        <span>Library</span>
      </NavLink>
    </nav>
  );
}

function TopBar() {
  const nav = useNavigate();
  const loc = useLocation();
  const user = useUser();
  return (
    <div className="topbar">
      <div className="row">
        <button className="icon-btn round" aria-label="Back" onClick={() => nav(-1)} disabled={loc.key === 'default'}>
          <I.IconChevronLeft />
        </button>
        <button className="icon-btn round" aria-label="Forward" onClick={() => nav(1)}>
          <I.IconChevronRight />
        </button>
      </div>
      <Link to="/settings" className="topbar-user" aria-label="Settings">
        <Artwork src={user?.avatarUrl} round fallback="user" className="sm" />
      </Link>
    </div>
  );
}

function Announcement() {
  const a = useConfig().announcement;
  const [hidden, setHidden] = useState<string | null>(() => {
    try {
      return sessionStorage.getItem('streamero.web.ann');
    } catch {
      return null;
    }
  });
  if (!a.enabled || !a.text || hidden === a.text) return null;
  return (
    <div className={`announcement ${a.style}`} role="status">
      <span>{a.text}</span>
      <button
        className="icon-btn"
        aria-label="Dismiss"
        onClick={() => {
          setHidden(a.text);
          try {
            sessionStorage.setItem('streamero.web.ann', a.text);
          } catch {
            /* ignore */
          }
        }}
      >
        <I.IconClose size={16} />
      </button>
    </div>
  );
}

function Toasts() {
  const items = useStore(toasts, (s) => s.items);
  return (
    <div className="toasts" aria-live="polite">
      {items.map((t) => (
        <div key={t.id} className={`toast ${t.kind}`}>
          {t.text}
        </div>
      ))}
    </div>
  );
}

function Shell() {
  const track = useCurrentTrack();
  const panel = usePlayer((s) => s.panel);
  const loc = useLocation();
  const main = useRef<HTMLElement>(null);
  useKeyboardShortcuts();
  useEffect(() => {
    installMediaSession();
    return startSyncPolling();
  }, []);
  useEffect(() => {
    main.current?.scrollTo({ top: 0 });
  }, [loc.pathname]);
  return (
    <div className={`shell ${track ? 'has-player' : ''} ${panel !== 'none' && track ? 'has-panel' : ''}`}>
      <Sidebar />
      <main className="main" ref={main} id="main">
        <Announcement />
        <TopBar />
        <Suspense fallback={<Spinner />}>
          <Outlet />
        </Suspense>
        <footer className="site-foot">
          <a href="https://scyde.dev" target="_blank" rel="noopener noreferrer">
            STREAMERO by SCYDE
          </a>
        </footer>
      </main>
      <SidePanel />
      <NowPlayingBar />
      <MiniPlayer />
      <MobileTabs />
      <FullPlayer />
    </div>
  );
}

function RequireAuth({ children }: { children: ReactNode }) {
  const auth = useApp((s) => s.auth);
  const loc = useLocation();
  if (auth === 'loading')
    return (
      <div className="boot">
        <img src="/logo-mark.svg" alt="" width={72} height={72} />
      </div>
    );
  if (auth === 'signedOut') return <Navigate to={loc.pathname === '/' ? '/welcome' : `/login?next=${encodeURIComponent(loc.pathname + loc.search)}`} replace />;
  return <>{children}</>;
}

function GuestOnly({ children }: { children: ReactNode }) {
  const auth = useApp((s) => s.auth);
  if (auth === 'loading') return null;
  if (auth === 'signedIn') return <Navigate to="/" replace />;
  return <>{children}</>;
}

export default function App() {
  return (
    <>
      <Routes>
        <Route path="/welcome" element={<GuestOnly><Welcome /></GuestOnly>} />
        <Route path="/login" element={<GuestOnly><Login /></GuestOnly>} />
        <Route path="/signup" element={<GuestOnly><Signup /></GuestOnly>} />
        <Route path="/auth/google" element={<GoogleCallback />} />
        <Route path="/forgot-password" element={<ForgotPassword />} />
        <Route path="/reset-password" element={<ResetPassword />} />
        <Route path="/verify-email" element={<VerifyEmail />} />
        <Route element={<RequireAuth><Shell /></RequireAuth>}>
          <Route index element={<Home />} />
          <Route path="search" element={<Search />} />
          <Route path="explore" element={<Explore />} />
          <Route path="library" element={<Library />} />
          <Route path="library/:tab" element={<Library />} />
          <Route path="album/:id" element={<AlbumPage />} />
          <Route path="artist/:id" element={<ArtistPage />} />
          <Route path="playlist/:id" element={<PlaylistPage />} />
          <Route path="mix/:id" element={<MixPage />} />
          <Route path="genre/:name" element={<GenrePage kind="genre" />} />
          <Route path="mood/:name" element={<GenrePage kind="mood" />} />
          <Route path="video/:id" element={<VideoPage />} />
          <Route path="settings" element={<Settings />} />
          <Route path="*" element={<Empty title="Page not found">The page you’re looking for doesn’t exist.</Empty>} />
        </Route>
      </Routes>
      <Toasts />
    </>
  );
}
