import { useEffect, useState, type ReactNode } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { IconArrowRight } from '../components/Icons';
import { api, ApiError } from '../lib/api';
import { signedIn, useApp, useConfig } from '../state/app';
import { errorText, toast } from '../state/store';

export const passwordProblem = (p: string) =>
  p.length < 10 ? 'Use at least 10 characters.' : !/[A-Za-z]/.test(p) || !/\d/.test(p) ? 'Use both letters and digits.' : null;

function AuthShell({ children }: { children: ReactNode }) {
  const cfg = useConfig();
  return (
    <div className="auth">
      <div className="auth-bg" aria-hidden />
      <div className="auth-card">
        <Link to="/welcome" className="auth-logo" aria-label={cfg.brand.appName}>
          <img src="/logo-mark.svg" alt="" width={64} height={64} />
        </Link>
        {children}
      </div>
      <footer className="auth-foot">
        <a href={cfg.brand.developerUrl} target="_blank" rel="noopener noreferrer">
          {cfg.brand.appName} by {cfg.brand.developer}
        </a>
      </footer>
    </div>
  );
}

function FormError({ error }: { error: string | null }) {
  return error ? (
    <p className="form-error" role="alert">
      {error}
    </p>
  ) : null;
}

export function Welcome() {
  const cfg = useConfig();
  const nav = useNavigate();
  const [email, setEmail] = useState('');
  return (
    <AuthShell>
      <h1 className="auth-title title-font">{cfg.texts.welcomeTitle}</h1>
      <p className="auth-sub">{cfg.texts.welcomeSubtitle}</p>
      <p className="auth-legal">
        By signing up, I agree to {cfg.brand.appName}’s Terms and Privacy Policy.
      </p>
      {cfg.features.signup ? (
        <form
          className="form"
          onSubmit={(e) => {
            e.preventDefault();
            nav(`/signup?email=${encodeURIComponent(email)}`);
          }}
        >
          <div className="divider">
            <span>Sign up with email</span>
          </div>
          <label className="field">
            <span>Email Address:</span>
            <input type="email" autoComplete="email" placeholder="Enter your email address" value={email} onChange={(e) => setEmail(e.target.value)} required />
          </label>
          <button className="btn-accent big">
            Next <IconArrowRight size={18} />
          </button>
        </form>
      ) : (
        <Link className="btn-accent big" to="/login">
          Log in <IconArrowRight size={18} />
        </Link>
      )}
      <p className="auth-alt">
        Already have an account? <Link to="/login">Log in</Link>
      </p>
    </AuthShell>
  );
}

export function Login() {
  const nav = useNavigate();
  const [params] = useSearchParams();
  const cfg = useConfig();
  const [email, setEmail] = useState(params.get('email') ?? '');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <AuthShell>
      <h1 className="auth-title title-font">Log in</h1>
      <p className="auth-sub">Welcome back to {cfg.brand.appName}.</p>
      <form
        className="form"
        onSubmit={async (e) => {
          e.preventDefault();
          setBusy(true);
          setError(null);
          try {
            const user = await api.login(email.trim(), password);
            await signedIn(user);
            nav(params.get('next') ?? '/', { replace: true });
          } catch (err) {
            setError(err instanceof ApiError && err.status === 401 ? 'Wrong email or password.' : errorText(err));
          } finally {
            setBusy(false);
          }
        }}
      >
        <label className="field">
          <span>Email Address:</span>
          <input type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} required autoFocus={!email} />
        </label>
        <label className="field">
          <span>Password:</span>
          <input type="password" autoComplete="current-password" value={password} onChange={(e) => setPassword(e.target.value)} required autoFocus={!!email} />
        </label>
        <FormError error={error} />
        <button className="btn-accent big" disabled={busy}>
          {busy ? 'Signing in…' : 'Log in'}
        </button>
      </form>
      <p className="auth-alt">
        <Link to={`/forgot-password${email ? `?email=${encodeURIComponent(email)}` : ''}`}>Forgot password?</Link>
      </p>
      {cfg.features.signup && (
        <p className="auth-alt">
          New to {cfg.brand.appName}? <Link to="/signup">Sign up</Link>
        </p>
      )}
    </AuthShell>
  );
}

export function Signup() {
  const nav = useNavigate();
  const [params] = useSearchParams();
  const cfg = useConfig();
  const [email, setEmail] = useState(params.get('email') ?? '');
  const [name, setName] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  if (!cfg.features.signup)
    return (
      <AuthShell>
        <h1 className="auth-title title-font">Sign up is closed</h1>
        <p className="auth-sub">New accounts are created by an administrator.</p>
        <Link className="btn-accent big" to="/login">
          Log in
        </Link>
      </AuthShell>
    );
  return (
    <AuthShell>
      <h1 className="auth-title title-font">Create your account</h1>
      <form
        className="form"
        onSubmit={async (e) => {
          e.preventDefault();
          const p = passwordProblem(password);
          if (p) return setError(p);
          setBusy(true);
          setError(null);
          try {
            const user = await api.register(email.trim(), password, name.trim());
            await signedIn(user);
            toast('Welcome! Check your inbox to verify your email.', 'success');
            nav('/', { replace: true });
          } catch (err) {
            setError(err instanceof ApiError && err.status === 409 ? 'An account with this email already exists.' : errorText(err));
          } finally {
            setBusy(false);
          }
        }}
      >
        <label className="field">
          <span>Email Address:</span>
          <input type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} required />
        </label>
        <label className="field">
          <span>Display name:</span>
          <input autoComplete="nickname" value={name} maxLength={80} onChange={(e) => setName(e.target.value)} required autoFocus={!!email} />
        </label>
        <label className="field">
          <span>Password:</span>
          <input type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} required minLength={10} />
          <small className="muted">At least 10 characters with letters and digits.</small>
        </label>
        <FormError error={error} />
        <button className="btn-accent big" disabled={busy}>
          {busy ? 'Creating account…' : 'Sign up'}
        </button>
      </form>
      <p className="auth-alt">
        Already have an account? <Link to="/login">Log in</Link>
      </p>
    </AuthShell>
  );
}

export function ForgotPassword() {
  const [params] = useSearchParams();
  const [email, setEmail] = useState(params.get('email') ?? '');
  const [sent, setSent] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <AuthShell>
      <h1 className="auth-title title-font">Reset password</h1>
      {sent ? (
        <>
          <p className="auth-sub">If an account exists for {email}, we’ve sent a link to reset the password. The link is valid for a limited time.</p>
          <Link className="btn-accent big" to="/login">
            Back to log in
          </Link>
        </>
      ) : (
        <form
          className="form"
          onSubmit={async (e) => {
            e.preventDefault();
            setBusy(true);
            setError(null);
            try {
              await api.forgotPassword(email.trim());
              setSent(true);
            } catch (err) {
              setError(errorText(err));
            } finally {
              setBusy(false);
            }
          }}
        >
          <p className="auth-sub">Enter your email and we’ll send you a reset link.</p>
          <label className="field">
            <span>Email Address:</span>
            <input type="email" autoComplete="email" value={email} onChange={(e) => setEmail(e.target.value)} required autoFocus />
          </label>
          <FormError error={error} />
          <button className="btn-accent big" disabled={busy}>
            Send link
          </button>
          <p className="auth-alt">
            <Link to="/login">Back to log in</Link>
          </p>
        </form>
      )}
    </AuthShell>
  );
}

export function ResetPassword() {
  const [params] = useSearchParams();
  const token = params.get('token') ?? '';
  const [password, setPassword] = useState('');
  const [confirm, setConfirm] = useState('');
  const [done, setDone] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  return (
    <AuthShell>
      <h1 className="auth-title title-font">Choose a new password</h1>
      {!token ? (
        <p className="auth-sub">This link is incomplete. Open the link from the email again, or request a new one.</p>
      ) : done ? (
        <>
          <p className="auth-sub">Your password has been changed. All other sessions were signed out.</p>
          <Link className="btn-accent big" to="/login">
            Log in
          </Link>
        </>
      ) : (
        <form
          className="form"
          onSubmit={async (e) => {
            e.preventDefault();
            const p = passwordProblem(password);
            if (p) return setError(p);
            if (password !== confirm) return setError('The passwords don’t match.');
            setBusy(true);
            setError(null);
            try {
              await api.resetPassword(token, password);
              setDone(true);
            } catch (err) {
              setError(err instanceof ApiError && err.status === 400 ? 'This reset link is invalid or has expired. Request a new one.' : errorText(err));
            } finally {
              setBusy(false);
            }
          }}
        >
          <label className="field">
            <span>New password:</span>
            <input type="password" autoComplete="new-password" value={password} onChange={(e) => setPassword(e.target.value)} required autoFocus />
          </label>
          <label className="field">
            <span>Repeat password:</span>
            <input type="password" autoComplete="new-password" value={confirm} onChange={(e) => setConfirm(e.target.value)} required />
          </label>
          <FormError error={error} />
          <button className="btn-accent big" disabled={busy}>
            Set password
          </button>
        </form>
      )}
      <p className="auth-alt">
        <Link to="/forgot-password">Request a new link</Link>
      </p>
    </AuthShell>
  );
}

export function VerifyEmail() {
  const [params] = useSearchParams();
  const token = params.get('token') ?? '';
  const auth = useApp((s) => s.auth);
  const [state, setState] = useState<'working' | 'ok' | 'error'>(token ? 'working' : 'error');
  const [message, setMessage] = useState('');
  useEffect(() => {
    if (!token) return;
    let alive = true;
    api
      .verifyEmail(token)
      .then(() => alive && setState('ok'))
      .catch((e) => {
        if (!alive) return;
        setState('error');
        setMessage(errorText(e));
      });
    return () => {
      alive = false;
    };
  }, [token]);
  return (
    <AuthShell>
      <h1 className="auth-title title-font">Email verification</h1>
      {state === 'working' && <p className="auth-sub">Verifying…</p>}
      {state === 'ok' && <p className="auth-sub">Thanks! Your email address is verified.</p>}
      {state === 'error' && <p className="auth-sub">{message || 'This verification link is invalid or has expired.'}</p>}
      <Link className="btn-accent big" to={auth === 'signedIn' ? '/' : '/login'}>
        {auth === 'signedIn' ? 'Continue listening' : 'Log in'}
      </Link>
    </AuthShell>
  );
}
