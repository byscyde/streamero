import { useState } from 'react';
import { adminApi, passwordProblem, userPatch, type AdminUser, type Role } from '../api';
import { useAsync, useDebounced, useToast } from '../hooks';
import { ErrorBox, fmtDate, Loading, Modal, Pager, StatusBadge } from '../components/ui';

const ROLES: Role[] = ['user', 'editor', 'admin'];
const PAGE = 25;
const fmtDay = (d?: string | null) => (d ? new Date(d).toLocaleDateString() : '—');

export function Users({ me }: { me: { id: string } }) {
  const [q, setQ] = useState('');
  const [role, setRole] = useState('');
  const [offset, setOffset] = useState(0);
  const dq = useDebounced(q);
  const { data, error, loading, reload } = useAsync(() => adminApi.users.list({ q: dq, role, offset, limit: PAGE }), [dq, role, offset]);
  const [creating, setCreating] = useState(false);
  const [editing, setEditing] = useState<AdminUser | null>(null);
  const [pwFor, setPwFor] = useState<AdminUser | null>(null);
  const [deleting, setDeleting] = useState<AdminUser | null>(null);
  const { notify, fail } = useToast();

  const sendReset = async (u: AdminUser) => {
    if (!window.confirm(`Email a password-reset link to ${u.email}?`)) return;
    try {
      await adminApi.users.sendReset(u.id);
      notify(`Reset link sent to ${u.email}`);
    } catch (e) {
      fail(e);
    }
  };

  return (
    <>
      <div className="page-head">
        <h1>Users &amp; roles</h1>
        <span className="spacer" />
        <button className="primary" onClick={() => setCreating(true)}>New user</button>
      </div>
      <p className="muted">
        Roles: <b>admin</b> (everything), <b>editor</b> (catalog &amp; ingestion), <b>user</b> (listening). Permissions are enforced by the API, not by this page.
      </p>
      <div className="row">
        <input value={q} onChange={(e) => { setQ(e.target.value); setOffset(0); }} placeholder="Search email or name" aria-label="Search users" style={{ minWidth: 260 }} />
        <select value={role} onChange={(e) => { setRole(e.target.value); setOffset(0); }} aria-label="Filter by role">
          <option value="">All roles</option>
          {ROLES.map((r) => <option key={r} value={r}>{r}</option>)}
        </select>
      </div>
      <Loading error={error} loading={loading && !data} retry={reload} />
      {data && (
        <div className="table-wrap" style={{ marginTop: 12 }}>
          <table>
            <thead><tr><th>User</th><th>Role</th><th>Verified</th><th>Joined</th><th>Last active</th><th>Status</th><th><span className="sr-only">Actions</span></th></tr></thead>
            <tbody>
              {data.items.map((u) => (
                <tr key={u.id}>
                  <td className="wrap"><span className="strong">{u.displayName}</span>{u.id === me.id && <span className="badge" style={{ marginLeft: 6 }}>you</span>}<div className="small-text">{u.email}</div></td>
                  <td><StatusBadge status={u.role} /></td>
                  <td>{u.emailVerified ? <span className="badge ok">verified</span> : <span className="badge">unverified</span>}</td>
                  <td>{fmtDay(u.createdAt)}</td>
                  <td title={fmtDate(u.lastActiveAt ?? u.lastPlayedAt)}>{fmtDay(u.lastActiveAt ?? u.lastPlayedAt)}</td>
                  <td><StatusBadge status={u.disabled ? 'disabled' : 'active'} /></td>
                  <td>
                    <div className="row nowrap">
                      <button className="small" onClick={() => setEditing(u)}>Edit</button>
                      <button className="small" onClick={() => setPwFor(u)}>Password…</button>
                      <button className="small" onClick={() => sendReset(u)}>Reset email</button>
                      {u.id !== me.id && <button className="small danger" onClick={() => setDeleting(u)}>Delete</button>}
                    </div>
                  </td>
                </tr>
              ))}
              {data.items.length === 0 && <tr><td colSpan={7} className="muted">No users match.</td></tr>}
            </tbody>
          </table>
        </div>
      )}
      <Pager page={data} onChange={setOffset} />
      {creating && <CreateUserDialog onClose={() => setCreating(false)} onDone={() => { setCreating(false); reload(); }} />}
      {editing && <EditUserDialog user={editing} isSelf={editing.id === me.id} onClose={() => setEditing(null)} onDone={() => { setEditing(null); reload(); }} />}
      {pwFor && <SetPasswordDialog user={pwFor} onClose={() => setPwFor(null)} />}
      {deleting && <DeleteUserDialog user={deleting} onClose={() => setDeleting(null)} onDone={() => { setDeleting(null); reload(); }} />}
    </>
  );
}

function CreateUserDialog({ onClose, onDone }: { onClose: () => void; onDone: () => void }) {
  const [f, setF] = useState({ email: '', displayName: '', role: 'user' as Role, password: '', sendInvite: true });
  const [err, setErr] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const { notify } = useToast();
  const pwIssue = f.password ? passwordProblem(f.password) : null;
  return (
    <Modal title="New user" onClose={onClose}>
      <form className="stack" onSubmit={async (e) => {
        e.preventDefault();
        if (pwIssue) return;
        setBusy(true);
        setErr(null);
        try {
          await adminApi.users.create({
            email: f.email.trim(), displayName: f.displayName.trim(), role: f.role,
            ...(f.password ? { password: f.password } : {}),
            sendInvite: f.password ? f.sendInvite : true,
          });
          notify(f.password ? `Created ${f.email}` : `Created ${f.email}; a set-password email was sent`);
          onDone();
        } catch (e) {
          setErr(e);
        } finally {
          setBusy(false);
        }
      }}>
        <div className="form-grid">
          <label className="field">Email<input type="email" required value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} autoComplete="off" /></label>
          <label className="field">Display name<input required maxLength={80} value={f.displayName} onChange={(e) => setF({ ...f, displayName: e.target.value })} /></label>
          <label className="field">Role<select value={f.role} onChange={(e) => setF({ ...f, role: e.target.value as Role })}>{ROLES.map((r) => <option key={r}>{r}</option>)}</select></label>
          <label className="field">Password (optional)
            <input type="password" autoComplete="new-password" value={f.password} onChange={(e) => setF({ ...f, password: e.target.value })} aria-invalid={!!pwIssue} />
            {pwIssue && <span className="field-error">{pwIssue}</span>}
          </label>
        </div>
        {f.password ? (
          <label className="check"><input type="checkbox" checked={f.sendInvite} onChange={(e) => setF({ ...f, sendInvite: e.target.checked })} /> Also send an email so they can set their own password</label>
        ) : (
          <p className="small-text">No password given: the user receives an email with a link to set their password.</p>
        )}
        <p className="small-text">Accounts created here are marked as email-verified. Passwords need at least 10 characters with letters and digits.</p>
        <ErrorBox error={err} />
        <div className="row"><span className="spacer" /><button type="button" onClick={onClose}>Cancel</button><button className="primary" disabled={busy || !!pwIssue}>{busy ? 'Creating…' : 'Create user'}</button></div>
      </form>
    </Modal>
  );
}

function EditUserDialog({ user, isSelf, onClose, onDone }: { user: AdminUser; isSelf: boolean; onClose: () => void; onDone: () => void }) {
  const [f, setF] = useState({ email: user.email, displayName: user.displayName, role: user.role, disabled: user.disabled, emailVerified: user.emailVerified });
  const [err, setErr] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const { notify } = useToast();
  // Send only what changed so the audit log stays meaningful.
  const patch = userPatch(user, f);
  const changed = Object.keys(patch).length > 0;
  return (
    <Modal title={`Edit ${user.email}`} onClose={onClose}>
      <form className="stack" onSubmit={async (e) => {
        e.preventDefault();
        if (!changed) return onClose();
        if (patch.disabled === true && !window.confirm(`Disable ${user.email}? They are signed out everywhere.`)) return;
        setBusy(true);
        setErr(null);
        try {
          await adminApi.users.update(user.id, patch);
          notify('User updated');
          onDone();
        } catch (e) {
          setErr(e);
        } finally {
          setBusy(false);
        }
      }}>
        <div className="form-grid">
          <label className="field">Email<input type="email" required value={f.email} onChange={(e) => setF({ ...f, email: e.target.value })} /></label>
          <label className="field">Display name<input required maxLength={80} value={f.displayName} onChange={(e) => setF({ ...f, displayName: e.target.value })} /></label>
          <label className="field">Role
            <select value={f.role} disabled={isSelf} onChange={(e) => setF({ ...f, role: e.target.value as Role })}>{ROLES.map((r) => <option key={r}>{r}</option>)}</select>
          </label>
        </div>
        <label className="check"><input type="checkbox" checked={f.emailVerified} onChange={(e) => setF({ ...f, emailVerified: e.target.checked })} /> Email verified</label>
        <label className="check"><input type="checkbox" checked={f.disabled} disabled={isSelf} onChange={(e) => setF({ ...f, disabled: e.target.checked })} /> Disabled (signed out everywhere, cannot sign in)</label>
        {isSelf && <p className="small-text">You cannot change your own role or disable yourself.</p>}
        <ErrorBox error={err} />
        <div className="row"><span className="spacer" /><button type="button" onClick={onClose}>Cancel</button><button className="primary" disabled={busy || !changed}>{busy ? 'Saving…' : 'Save changes'}</button></div>
      </form>
    </Modal>
  );
}

function SetPasswordDialog({ user, onClose }: { user: AdminUser; onClose: () => void }) {
  const [pw, setPw] = useState('');
  const [pw2, setPw2] = useState('');
  const [err, setErr] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const { notify } = useToast();
  const issue = pw ? passwordProblem(pw) : null;
  const mismatch = pw2 && pw !== pw2 ? 'Passwords do not match.' : null;
  return (
    <Modal title={`Set password — ${user.email}`} onClose={onClose}>
      <form className="stack" onSubmit={async (e) => {
        e.preventDefault();
        if (issue || mismatch || !pw) return;
        setBusy(true);
        setErr(null);
        try {
          await adminApi.users.setPassword(user.id, pw);
          notify('Password set; the user was signed out of all devices');
          onClose();
        } catch (e) {
          setErr(e);
        } finally {
          setBusy(false);
        }
      }}>
        <label className="field">New password<input type="password" autoComplete="new-password" required value={pw} onChange={(e) => setPw(e.target.value)} aria-invalid={!!issue} />{issue && <span className="field-error">{issue}</span>}</label>
        <label className="field">Repeat password<input type="password" autoComplete="new-password" required value={pw2} onChange={(e) => setPw2(e.target.value)} aria-invalid={!!mismatch} />{mismatch && <span className="field-error">{mismatch}</span>}</label>
        <p className="small-text">At least 10 characters with letters and digits. All of this user's sessions are revoked. Prefer “Send reset email” so you never handle their password.</p>
        <ErrorBox error={err} />
        <div className="row"><span className="spacer" /><button type="button" onClick={onClose}>Cancel</button><button className="primary" disabled={busy || !!issue || !!mismatch || !pw || pw !== pw2}>{busy ? 'Saving…' : 'Set password'}</button></div>
      </form>
    </Modal>
  );
}

function DeleteUserDialog({ user, onClose, onDone }: { user: AdminUser; onClose: () => void; onDone: () => void }) {
  const [typed, setTyped] = useState('');
  const [err, setErr] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const { notify } = useToast();
  const ok = typed.trim().toLowerCase() === user.email.toLowerCase();
  return (
    <Modal title="Delete user" onClose={onClose}>
      <form className="stack" onSubmit={async (e) => {
        e.preventDefault();
        if (!ok) return;
        setBusy(true);
        setErr(null);
        try {
          await adminApi.users.remove(user.id);
          notify(`Deleted ${user.email}`);
          onDone();
        } catch (e) {
          setErr(e);
        } finally {
          setBusy(false);
        }
      }}>
        <div className="callout danger">
          This permanently deletes <b>{user.displayName}</b> ({user.email}) and their personal data: library, playlists, history and sessions. This cannot be undone.
        </div>
        <label className="field">Type <code>{user.email}</code> to confirm<input value={typed} onChange={(e) => setTyped(e.target.value)} autoComplete="off" aria-label="Type the email to confirm" /></label>
        <ErrorBox error={err} />
        <div className="row"><span className="spacer" /><button type="button" onClick={onClose}>Cancel</button><button className="danger solid" disabled={!ok || busy}>{busy ? 'Deleting…' : 'Delete permanently'}</button></div>
      </form>
    </Modal>
  );
}

