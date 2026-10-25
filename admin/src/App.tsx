import { useEffect, useState } from 'react';
import { BrowserRouter, NavLink, Navigate, Route, Routes } from 'react-router-dom';
import { adminApi, api, hasSession, login, logout, setLogoutHandler } from './api';
import { ToastProvider } from './hooks';
import { ErrorBox } from './components/ui';
import { Account } from './pages/Account';
import { AppearancePage } from './pages/Appearance';
import { Albums, Artists, Tracks, Videos } from './pages/Catalog';
import { JobDetail, Jobs } from './pages/Jobs';
import { MetadataPage } from './pages/Metadata';
import { Overview } from './pages/Overview';
import { AuditLogs, HomeSections, Storage, SystemHealth } from './pages/System';
import { Uploads } from './pages/Uploads';
import { Users } from './pages/Users';

const ASSET = import.meta.env.BASE_URL;

function Logo({ size = 28 }: { size?: number }) {
  return (
    <span className="logo">
      <img src={`${ASSET}logo-mark.svg`} width={size} height={size} alt="" />
      <span className="logo-text">STREAMERO</span>
    </span>
  );
}

function Credit() {
  return (
    <a className="credit" href="https://scyde.dev" target="_blank" rel="noopener noreferrer">
      STREAMERO · by <b>SCYDE</b>
    </a>
  );
}

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
      <BrowserRouter basename={import.meta.env.BASE_URL.replace(/\/$/, '')}>
        <div className="topbar">
          <button className="small icon" onClick={() => setMenuOpen(!menuOpen)} aria-label="Menu" aria-expanded={menuOpen}>☰</button>
          <Logo size={24} />
        </div>
        <div className="layout">
          <aside className={`sidebar ${menuOpen ? 'open' : ''}`} onClick={() => setMenuOpen(false)}>
            <div className="brand"><Logo /><span className="brand-sub">Admin</span></div>
            <nav className="nav" aria-label="Main">
              <NavLink to="/" end>Overview</NavLink>
              <div className="group">Media</div>
              <NavLink to="/uploads">Upload &amp; import</NavLink>
              <NavLink to="/jobs" end>Processing queue</NavLink>
              <NavLink to="/jobs?status=failed">Failed jobs</NavLink>
              <div className="group">Catalog</div>
              <NavLink to="/tracks">Tracks</NavLink>
              <NavLink to="/albums">Albums</NavLink>
              <NavLink to="/artists">Artists</NavLink>
              <NavLink to="/videos">Videos</NavLink>
              <NavLink to="/metadata">Metadata lookup</NavLink>
              <NavLink to="/home-feed">Home feed</NavLink>
              {isAdmin && <div className="group">App</div>}
              {isAdmin && <NavLink to="/appearance">Appearance</NavLink>}
              <div className="group">Operations</div>
              <NavLink to="/storage">Storage</NavLink>
              {isAdmin && <NavLink to="/users">Users &amp; roles</NavLink>}
              {isAdmin && <NavLink to="/audit">Audit log</NavLink>}
              {isAdmin && <NavLink to="/system">System health</NavLink>}
            </nav>
            <div className="sidebar-foot">
              <div className="small-text me">{me.email}<br /><span className="badge">{me.role}</span></div>
              <div className="row tight">
                <NavLink to="/account" className="button small">My account</NavLink>
                <button className="small" onClick={async () => { await logout(); setMe(null); }}>Sign out</button>
              </div>
              <Credit />
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
              <Route path="/metadata" element={<MetadataPage />} />
              <Route path="/home-feed" element={<HomeSections />} />
              <Route path="/storage" element={<Storage />} />
              <Route path="/account" element={<Account me={me} />} />
              {isAdmin && <Route path="/appearance" element={<AppearancePage />} />}
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
  const [mode, setMode] = useState<'login' | 'forgot'>('login');
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState<unknown>(null);
  const [sent, setSent] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  return (
    <div className="login">
      {mode === 'login' ? (
        <form className="card" onSubmit={async (e) => {
          e.preventDefault();
          setBusy(true);
          setError(null);
          try { onLogin(await login(email, password)); } catch (err) { setError(err); } finally { setBusy(false); }
        }}>
          <Logo size={36} />
          <h1>Admin sign in</h1>
          <label className="field">Email<input type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required /></label>
          <label className="field">Password<input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required /></label>
          <ErrorBox error={error} />
          <button className="primary" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
          <button type="button" className="link" onClick={() => { setMode('forgot'); setError(null); setSent(null); }}>Forgot password?</button>
          <p className="small-text">Only editor and administrator accounts can sign in.</p>
          <Credit />
        </form>
      ) : (
        <form className="card" onSubmit={async (e) => {
          e.preventDefault();
          setBusy(true);
          setError(null);
          try {
            const r = await adminApi.auth.forgotPassword(email.trim());
            setSent(r?.status ?? 'If an account exists for this email, a reset link has been sent.');
          } catch (err) { setError(err); } finally { setBusy(false); }
        }}>
          <Logo size={36} />
          <h1>Reset password</h1>
          <p className="small-text">We email you a link that opens the STREAMERO web player, where you choose a new password.</p>
          <label className="field">Email<input type="email" autoComplete="username" value={email} onChange={(e) => setEmail(e.target.value)} required /></label>
          <ErrorBox error={error} />
          {sent && <p className="callout ok" role="status">{sent}</p>}
          <button className="primary" disabled={busy}>{busy ? 'Sending…' : 'Send reset link'}</button>
          <button type="button" className="link" onClick={() => { setMode('login'); setError(null); }}>← Back to sign in</button>
          <Credit />
        </form>
      )}
    </div>
  );
}
