import { useEffect, useState } from 'react';
import { BrowserRouter, NavLink, Navigate, Route, Routes } from 'react-router-dom';
import { api, hasSession, login, logout, setLogoutHandler } from './api';
import { ToastProvider } from './hooks';
import { Albums, Artists, Tracks, Videos } from './pages/Catalog';
import { JobDetail, Jobs } from './pages/Jobs';
import { Overview } from './pages/Overview';
import { AuditLogs, HomeSections, Storage, SystemHealth, Users } from './pages/System';
import { Uploads } from './pages/Uploads';

export default function App() {
  const [me, setMe] = useState<any>(null);
  const [checking, setChecking] = useState(hasSession());
  const [menuOpen, setMenuOpen] = useState(false);

  useEffect(() => {
    setLogoutHandler(() => setMe(null));
    if (hasSession()) api.get<any>('/v1/me').then(setMe).catch(() => setMe(null)).finally(() => setChecking(false));
  }, []);

  if (checking) return <div className="login"><p className="muted">Loading…</p></div>;
  if (!me) return <ToastProvider><Login onLogin={setMe} /></ToastProvider>;
  const isAdmin = me.role === 'admin';

  return (
    <ToastProvider>
      <BrowserRouter>
        <div className="topbar">
          <button className="small" onClick={() => setMenuOpen(!menuOpen)} aria-label="Menu">☰</button>
          <span className="brand" style={{ padding: 0 }}>STREAMERO</span>
        </div>
        <div className="layout">
          <aside className={`sidebar ${menuOpen ? 'open' : ''}`} onClick={() => setMenuOpen(false)}>
            <div className="brand">STREAMERO</div>
            <nav className="nav" aria-label="Main">
              <NavLink to="/" end>Overview</NavLink>
              <div className="group">Media</div>
              <NavLink to="/uploads">Upload & import</NavLink>
              <NavLink to="/jobs">Processing queue</NavLink>
              <NavLink to="/jobs?status=failed">Failed jobs</NavLink>
              <div className="group">Catalog</div>
              <NavLink to="/tracks">Tracks</NavLink>
              <NavLink to="/albums">Albums</NavLink>
              <NavLink to="/artists">Artists</NavLink>
              <NavLink to="/videos">Videos</NavLink>
              <NavLink to="/home-feed">Home feed</NavLink>
              <div className="group">Operations</div>
              <NavLink to="/storage">Storage</NavLink>
              {isAdmin && <NavLink to="/users">Users & roles</NavLink>}
              {isAdmin && <NavLink to="/audit">Audit log</NavLink>}
              {isAdmin && <NavLink to="/system">System health</NavLink>}
            </nav>
            <div style={{ marginTop: 24, padding: '0 10px' }} className="small-text">
              {me.email} · {me.role}
              <div><button className="small" style={{ marginTop: 8 }} onClick={async () => { await logout(); setMe(null); }}>Sign out</button></div>
            </div>
          </aside>
          <main>
            <Routes>
              <Route path="/" element={<Overview />} />
              <Route path="/uploads" element={<Uploads />} />
              <Route path="/jobs" element={<Jobs />} />
              <Route path="/jobs/:id" element={<JobDetail />} />
              <Route path="/tracks" element={<Tracks />} />
              <Route path="/albums" element={<Albums />} />
              <Route path="/artists" element={<Artists />} />
              <Route path="/videos" element={<Videos />} />
              <Route path="/home-feed" element={<HomeSections />} />
              <Route path="/storage" element={<Storage />} />
              {isAdmin && <Route path="/users" element={<Users me={me} />} />}
              {isAdmin && <Route path="/audit" element={<AuditLogs />} />}
              {isAdmin && <Route path="/system" element={<SystemHealth />} />}
              <Route path="*" element={<Navigate to="/" />} />
            </Routes>
          </main>
        </div>
      </BrowserRouter>
    </ToastProvider>
  );
}

function Login({ onLogin }: { onLogin: (u: any) => void }) {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  return (
    <div className="login">
      <form className="card" onSubmit={async (e) => {
        e.preventDefault();
        setBusy(true);
        setError(null);
        try { onLogin(await login(email, password)); } catch (err: any) { setError(err.message); } finally { setBusy(false); }
      }}>
        <div className="brand" style={{ padding: 0, fontSize: 20 }}>STREAMERO</div>
        <h1 style={{ margin: 0 }}>Admin sign in</h1>
        <label className="field">Email<input type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required /></label>
        <label className="field">Password<input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required /></label>
        {error && <p className="error" role="alert">{error}</p>}
        <button className="primary" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
        <p className="small-text">Only editor and administrator accounts can sign in.</p>
      </form>
    </div>
  );
}
