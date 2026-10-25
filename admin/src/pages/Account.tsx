import { useState } from 'react';
import { adminApi, passwordProblem } from '../api';
import { useToast } from '../hooks';
import { ErrorBox } from '../components/ui';

export function Account({ me }: { me: { email: string; displayName?: string; role: string } }) {
  const [current, setCurrent] = useState('');
  const [pw, setPw] = useState('');
  const [pw2, setPw2] = useState('');
  const [err, setErr] = useState<unknown>(null);
  const [busy, setBusy] = useState(false);
  const { notify } = useToast();
  const issue = pw ? passwordProblem(pw) : null;
  const mismatch = pw2 && pw !== pw2 ? 'Passwords do not match.' : null;
  const same = pw && pw === current ? 'Choose a different password.' : null;
  return (
    <>
      <h1>My account</h1>
      <div className="card narrow stack">
        <div><span className="strong">{me.displayName ?? me.email}</span><div className="small-text">{me.email} · {me.role}</div></div>
      </div>
      <h2>Change password</h2>
      <form className="card narrow stack" onSubmit={async (e) => {
        e.preventDefault();
        if (issue || mismatch || same) return;
        setBusy(true);
        setErr(null);
        try {
          await adminApi.auth.changePassword(current, pw);
          setCurrent(''); setPw(''); setPw2('');
          notify('Password changed');
        } catch (e) {
          setErr(e);
        } finally {
          setBusy(false);
        }
      }}>
        <label className="field">Current password<input type="password" autoComplete="current-password" required value={current} onChange={(e) => setCurrent(e.target.value)} /></label>
        <label className="field">New password<input type="password" autoComplete="new-password" required value={pw} onChange={(e) => setPw(e.target.value)} aria-invalid={!!(issue || same)} />{(issue || same) && <span className="field-error">{issue ?? same}</span>}</label>
        <label className="field">Repeat new password<input type="password" autoComplete="new-password" required value={pw2} onChange={(e) => setPw2(e.target.value)} aria-invalid={!!mismatch} />{mismatch && <span className="field-error">{mismatch}</span>}</label>
        <p className="small-text">At least 10 characters with letters and digits. Other devices may be signed out.</p>
        <ErrorBox error={err} />
        <div className="row"><span className="spacer" /><button className="primary" disabled={busy || !current || !pw || pw !== pw2 || !!issue || !!same}>{busy ? 'Saving…' : 'Change password'}</button></div>
      </form>
    </>
  );
}
