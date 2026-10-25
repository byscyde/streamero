import { useRef, useState, type ReactNode } from 'react';
import { useNavigate } from 'react-router-dom';
import { Artwork, ConfirmDialog, Modal, Spinner } from '../components/ui';
import { api } from '../lib/api';
import { PROFILES, settings } from '../lib/settings';
import type { StreamProfile, User } from '../lib/types';
import { controls } from '../player/player';
import { setUser, signOut, useConfig, useLoad, useUser } from '../state/app';
import { errorText, toast } from '../state/store';
import { passwordProblem } from './Auth';

function Card({ title, children, danger }: { title: string; children: ReactNode; danger?: boolean }) {
  return (
    <section className={`settings-card ${danger ? 'danger' : ''}`}>
      <h2>{title}</h2>
      {children}
    </section>
  );
}

function Toggle({ label, detail, checked, onChange }: { label: string; detail?: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <label className="setting-row">
      <span>
        <span className="setting-label">{label}</span>
        {detail && <span className="setting-detail">{detail}</span>}
      </span>
      <span className="switch">
        <input type="checkbox" checked={checked} onChange={(e) => onChange(e.target.checked)} />
        <span className="switch-track" />
      </span>
    </label>
  );
}

export default function Settings() {
  const user = useUser();
  const cfg = useConfig();
  if (!user) return <Spinner />;
  return (
    <div className="page settings">
      <h1 className="page-title">Settings</h1>
      <ProfileCard user={user} />
      <PlaybackCard />
      <PrivacyCard user={user} />
      {user.hasPassword !== false && <PasswordCard />}
      <SessionsCard />
      <DataCard user={user} />
      <Card title="About">
        <p>
          <strong>{cfg.brand.appName}</strong> — {cfg.brand.tagline}
        </p>
        <p className="muted">
          {cfg.brand.appName} by{' '}
          <a href={cfg.brand.developerUrl} target="_blank" rel="noopener noreferrer">
            {cfg.brand.developer}
          </a>{' '}
          · Web player {__APP_VERSION__}
        </p>
        <p className="muted small">
          Keyboard: Space play/pause · ←/→ seek 5 s · Shift+←/→ previous/next · ↑/↓ volume · M mute · S shuffle · R repeat · L lyrics · Q queue
        </p>
      </Card>
    </div>
  );
}

function ProfileCard({ user }: { user: User }) {
  const [name, setName] = useState(user.displayName);
  const [busy, setBusy] = useState(false);
  const file = useRef<HTMLInputElement>(null);
  const save = async () => {
    setBusy(true);
    try {
      setUser(await api.updateProfile({ displayName: name.trim() }));
      toast('Profile updated', 'success');
    } catch (e) {
      toast(errorText(e), 'error');
    } finally {
      setBusy(false);
    }
  };
  return (
    <Card title="Profile">
      <div className="profile-row">
        <Artwork src={user.avatarUrl} round fallback="user" className="avatar-lg" />
        <div className="col">
          <div className="row">
            <button className="pill" onClick={() => file.current?.click()}>
              Change photo
            </button>
            {user.avatarUrl && (
              <button
                className="pill"
                onClick={async () => {
                  try {
                    await api.removeAvatar();
                    setUser({ ...user, avatarUrl: null });
                  } catch (e) {
                    toast(errorText(e), 'error');
                  }
                }}
              >
                Remove
              </button>
            )}
          </div>
          <small className="muted">JPEG, PNG or WebP, up to 5 MB.</small>
          <input
            ref={file}
            type="file"
            accept="image/jpeg,image/png,image/webp"
            hidden
            onChange={async (e) => {
              const f = e.target.files?.[0];
              e.target.value = '';
              if (!f) return;
              if (f.size > 5 * 1024 * 1024) return toast('The image must be at most 5 MB.', 'error');
              try {
                setUser(await api.uploadAvatar(f));
                toast('Photo updated', 'success');
              } catch (err) {
                toast(errorText(err), 'error');
              }
            }}
          />
        </div>
      </div>
      <form
        className="form inline-form"
        onSubmit={(e) => {
          e.preventDefault();
          void save();
        }}
      >
        <label className="field">
          <span>Display name</span>
          <input value={name} maxLength={80} onChange={(e) => setName(e.target.value)} />
        </label>
        <button className="btn-accent" disabled={busy || !name.trim() || name.trim() === user.displayName}>
          Save
        </button>
      </form>
      <div className="setting-row static">
        <span>
          <span className="setting-label">Email</span>
          <span className="setting-detail">
            {user.email} · {user.emailVerified ? 'verified' : 'not verified'}
          </span>
        </span>
        {!user.emailVerified && (
          <button
            className="pill"
            onClick={() =>
              api
                .resendVerification()
                .then(() => toast('Verification email sent', 'success'))
                .catch((e) => toast(errorText(e), 'error'))
            }
          >
            Resend link
          </button>
        )}
      </div>
    </Card>
  );
}

function PlaybackCard() {
  const [q, setQ] = useState<StreamProfile>(settings.quality);
  return (
    <Card title="Streaming quality">
      <div className="radio-list" role="radiogroup">
        {PROFILES.map((p) => (
          <label key={p.id} className={`radio-row ${q === p.id ? 'active' : ''}`}>
            <input
              type="radio"
              name="quality"
              checked={q === p.id}
              onChange={() => {
                settings.quality = p.id;
                setQ(p.id);
                controls.invalidateStreams();
                toast(`Quality: ${p.title} (applies from the next song)`);
              }}
            />
            <span>
              <span className="setting-label">{p.title}</span>
              <span className="setting-detail">{p.detail}</span>
            </span>
          </label>
        ))}
      </div>
    </Card>
  );
}

function PrivacyCard({ user }: { user: User }) {
  const patch = async (p: Partial<User>) => {
    const prev = user;
    setUser({ ...user, ...p });
    try {
      setUser(await api.updateProfile(p));
    } catch (e) {
      setUser(prev);
      toast(errorText(e), 'error');
    }
  };
  return (
    <Card title="Content & privacy">
      <Toggle label="Allow explicit content" detail="Show songs and videos marked explicit." checked={user.allowExplicit ?? true} onChange={(v) => patch({ allowExplicit: v })} />
      <Toggle label="Listening history" detail="Remember what you play for Recently played and resume." checked={user.historyEnabled ?? true} onChange={(v) => patch({ historyEnabled: v })} />
      <Toggle label="Personalised recommendations" detail="Use your listening to build mixes and suggestions." checked={user.personalizationEnabled ?? true} onChange={(v) => patch({ personalizationEnabled: v })} />
    </Card>
  );
}

function PasswordCard() {
  const [cur, setCur] = useState('');
  const [next, setNext] = useState('');
  const [busy, setBusy] = useState(false);
  return (
    <Card title="Change password">
      <form
        className="form"
        onSubmit={async (e) => {
          e.preventDefault();
          const p = passwordProblem(next);
          if (p) return toast(p, 'error');
          setBusy(true);
          try {
            await api.changePassword(cur, next);
            setCur('');
            setNext('');
            toast('Password changed. Other sessions were signed out.', 'success');
          } catch (err) {
            toast(errorText(err), 'error');
          } finally {
            setBusy(false);
          }
        }}
      >
        <label className="field">
          <span>Current password</span>
          <input type="password" autoComplete="current-password" value={cur} onChange={(e) => setCur(e.target.value)} required />
        </label>
        <label className="field">
          <span>New password</span>
          <input type="password" autoComplete="new-password" value={next} onChange={(e) => setNext(e.target.value)} required minLength={10} />
          <small className="muted">At least 10 characters with letters and digits.</small>
        </label>
        <div>
          <button className="btn-accent" disabled={busy || !cur || !next}>
            Change password
          </button>
        </div>
      </form>
    </Card>
  );
}

function SessionsCard() {
  const r = useLoad(() => api.sessions(), [], 'none');
  const [confirm, setConfirm] = useState(false);
  const nav = useNavigate();
  return (
    <Card title="Devices & sessions">
      {r.loading && <Spinner />}
      <ul className="session-list">
        {r.data?.items.map((s) => (
          <li key={s.id}>
            <span>
              <span className="setting-label">{s.device || 'Unknown device'}</span>
              <span className="setting-detail">Last active {new Date(s.lastActiveAt).toLocaleString()}</span>
            </span>
            <button
              className="pill pill-sm"
              onClick={() =>
                api
                  .revokeSession(s.id)
                  .then(() => {
                    toast('Session signed out', 'success');
                    r.reload();
                  })
                  .catch((e) => toast(errorText(e), 'error'))
              }
            >
              Sign out
            </button>
          </li>
        ))}
      </ul>
      <div className="row">
        <button className="pill" onClick={() => signOut(false).then(() => nav('/welcome'))}>
          Sign out
        </button>
        <button className="pill danger" onClick={() => setConfirm(true)}>
          Sign out everywhere
        </button>
      </div>
      {confirm && (
        <ConfirmDialog
          title="Sign out everywhere?"
          body="All devices, including this browser, will be signed out."
          confirm="Sign out everywhere"
          danger
          onClose={() => setConfirm(false)}
          onConfirm={async () => {
            await signOut(true);
            nav('/welcome');
          }}
        />
      )}
    </Card>
  );
}

function DataCard({ user }: { user: User }) {
  const [deleting, setDeleting] = useState(false);
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const nav = useNavigate();
  return (
    <Card title="Your data" danger>
      <div className="setting-row static">
        <span>
          <span className="setting-label">Export data</span>
          <span className="setting-detail">Download everything stored about you as JSON.</span>
        </span>
        <button
          className="pill"
          onClick={async () => {
            try {
              const data = await api.exportData();
              const blob = new Blob([JSON.stringify(data, null, 2)], { type: 'application/json' });
              const a = document.createElement('a');
              a.href = URL.createObjectURL(blob);
              a.download = `streamero-export-${new Date().toISOString().slice(0, 10)}.json`;
              a.click();
              setTimeout(() => URL.revokeObjectURL(a.href), 5000);
            } catch (e) {
              toast(errorText(e), 'error');
            }
          }}
        >
          Export
        </button>
      </div>
      <div className="setting-row static">
        <span>
          <span className="setting-label">Delete account</span>
          <span className="setting-detail">Permanently deletes your account, library, playlists and history.</span>
        </span>
        <button className="btn-danger" onClick={() => setDeleting(true)}>
          Delete account
        </button>
      </div>
      {deleting && (
        <Modal title="Delete account?" onClose={() => setDeleting(false)}>
          <form
            className="form"
            onSubmit={async (e) => {
              e.preventDefault();
              setBusy(true);
              try {
                await api.deleteAccount(user.hasPassword === false ? undefined : password);
                await signOut(false).catch(() => undefined);
                toast('Your account was deleted.');
                nav('/welcome');
              } catch (err) {
                toast(errorText(err), 'error');
              } finally {
                setBusy(false);
              }
            }}
          >
            <p className="muted">This can’t be undone. Your playlists, likes and history will be deleted.</p>
            {user.hasPassword !== false && (
              <label className="field">
                <span>Confirm with your password</span>
                <input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required autoFocus />
              </label>
            )}
            <div className="row-end">
              <button type="button" className="pill" onClick={() => setDeleting(false)}>
                Cancel
              </button>
              <button className="btn-danger" disabled={busy}>
                Delete forever
              </button>
            </div>
          </form>
        </Modal>
      )}
    </Card>
  );
}

