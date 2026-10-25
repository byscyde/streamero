import { useEffect, useMemo, useState, type CSSProperties, type ReactNode } from 'react';
import { adminApi } from '../api';
import {
  ALL_CHIPS, COLOR_FIELDS, contrastRatio, DEFAULT_APPEARANCE, diffAppearance, FEATURE_LABELS, FONT_STACKS, isHexColor, mergeAppearance,
  moveItem, normalizeHex, SECTION_LABELS, TEXT_LIMITS, toggleChip, toSaveBody, validateAppearance, type Appearance,
} from '../appearance';
import { useAsync, useToast } from '../hooks';
import { ErrorBox, Loading } from '../components/ui';

type Updater = (fn: (a: Appearance) => void) => void;

export function AppearancePage() {
  const res = useAsync(() => adminApi.appearance.get(), []);
  const [saved, setSaved] = useState<Appearance | null>(null);
  const [defaults, setDefaults] = useState<Appearance>(DEFAULT_APPEARANCE);
  const [draft, setDraft] = useState<Appearance | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<unknown>(null);
  const { notify } = useToast();

  useEffect(() => {
    if (!res.data) return;
    const d = res.data.defaults ? mergeAppearance(res.data.defaults) : DEFAULT_APPEARANCE;
    const doc = mergeAppearance(res.data, d);
    setDefaults(d);
    setSaved(doc);
    setDraft(structuredClone(doc));
  }, [res.data]);

  const changes = useMemo(() => (saved && draft ? diffAppearance(saved, draft) : []), [saved, draft]);
  const errors = useMemo(() => (draft ? validateAppearance(draft) : {}), [draft]);
  const invalid = Object.keys(errors).length > 0;

  // Warn before leaving with unsaved edits.
  useEffect(() => {
    if (!changes.length) return;
    const h = (e: BeforeUnloadEvent) => e.preventDefault();
    window.addEventListener('beforeunload', h);
    return () => window.removeEventListener('beforeunload', h);
  }, [changes.length]);

  const update: Updater = (fn) => setDraft((d) => {
    const n = structuredClone(d!);
    fn(n);
    return n;
  });

  const accept = (r: unknown) => {
    const doc = mergeAppearance(r, defaults);
    setSaved(doc);
    setDraft(structuredClone(doc));
  };

  const save = async () => {
    setBusy(true);
    setErr(null);
    try {
      accept(await adminApi.appearance.save(toSaveBody(draft!)));
      notify('Appearance saved — open apps update within ~30 s');
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  };
  const reset = async () => {
    if (!window.confirm('Reset every appearance setting to the STREAMERO defaults? This is applied to all apps.')) return;
    setBusy(true);
    setErr(null);
    try {
      accept(await adminApi.appearance.reset());
      notify('Appearance reset to defaults');
    } catch (e) {
      setErr(e);
    } finally {
      setBusy(false);
    }
  };

  if (!draft || !saved) return <><h1>Appearance</h1><Loading error={res.error} loading={res.loading || !draft} retry={res.reload} /></>;
  const e = (p: string) => errors[p];

  return (
    <>
      <div className="page-head">
        <h1>Appearance</h1>
        <span className="spacer" />
        <span className="small-text">{changes.length ? `${changes.length} unsaved change${changes.length === 1 ? '' : 's'}` : 'All changes saved'}{saved.version ? ` · v ${saved.version.slice(0, 8)}` : ''}</span>
      </div>
      <p className="callout info">
        Everything here is remote configuration for the web player and the iOS app. Saved changes are picked up by open apps within <b>~30 seconds</b> (the web player also refreshes on focus) — no app update needed.
      </p>
      <div className="appearance">
        <div className="appearance-form">
          <Section title="Brand">
            <div className="form-grid">
              <Text label="App name" path="brand.appName" value={draft.brand.appName} max={TEXT_LIMITS.appName} error={e('brand.appName')} onChange={(v) => update((a) => { a.brand.appName = v; })} />
              <Text label="Tagline" path="brand.tagline" value={draft.brand.tagline} max={TEXT_LIMITS.tagline} error={e('brand.tagline')} onChange={(v) => update((a) => { a.brand.tagline = v; })} />
              <Text label="Developer" path="brand.developer" value={draft.brand.developer} max={TEXT_LIMITS.developer} error={e('brand.developer')} onChange={(v) => update((a) => { a.brand.developer = v; })} />
              <Text label="Developer URL" path="brand.developerUrl" type="url" value={draft.brand.developerUrl} max={TEXT_LIMITS.developerUrl} error={e('brand.developerUrl')} onChange={(v) => update((a) => { a.brand.developerUrl = v; })} />
              <Text label="Support email" path="brand.supportEmail" type="email" value={draft.brand.supportEmail} max={TEXT_LIMITS.supportEmail} error={e('brand.supportEmail')} onChange={(v) => update((a) => { a.brand.supportEmail = v; })} />
            </div>
          </Section>

          <Section title="Colours">
            <div className="color-grid">
              {COLOR_FIELDS.map((c) => (
                <ColorField key={c.key} label={c.label} hint={c.hint} value={draft.theme[c.key] as string} fallback={defaults.theme[c.key] as string} error={e(`theme.${c.key}`)}
                  onChange={(v) => update((a) => { (a.theme as any)[c.key] = v; })} />
              ))}
            </div>
            <Contrast theme={draft.theme} />
          </Section>

          <Section title="Style">
            <div className="form-grid">
              <label className="field">Title font
                <select value={draft.theme.titleFont} onChange={(ev) => update((a) => { a.theme.titleFont = ev.target.value as any; })}>
                  <option value="mono">Monospace (JetBrains Mono / SF Mono)</option>
                  <option value="default">System default</option>
                  <option value="rounded">Rounded</option>
                </select>
              </label>
              <label className="field">Player style
                <select value={draft.theme.playerStyle} onChange={(ev) => update((a) => { a.theme.playerStyle = ev.target.value as any; })}>
                  <option value="artwork">Artwork — tint from cover art</option>
                  <option value="solid">Solid — surface colour</option>
                </select>
              </label>
              <label className="field">Corner radius: <b>{draft.theme.cornerRadius}px</b>
                <input type="range" min={0} max={28} step={1} value={draft.theme.cornerRadius} onChange={(ev) => update((a) => { a.theme.cornerRadius = Number(ev.target.value); })} aria-label="Corner radius" />
                {e('theme.cornerRadius') && <span className="field-error">{e('theme.cornerRadius')}</span>}
              </label>
            </div>
            <Toggle label="Colourful genre gradients" hint="Gradient genre chips instead of plain chips" checked={draft.theme.genreGradients} onChange={(v) => update((a) => { a.theme.genreGradients = v; })} />
          </Section>

          <Section title="Welcome & home texts">
            <label className="field">Welcome title (line breaks allowed)
              <textarea rows={2} maxLength={TEXT_LIMITS.welcomeTitle} value={draft.texts.welcomeTitle} onChange={(ev) => update((a) => { a.texts.welcomeTitle = ev.target.value; })} aria-invalid={!!e('texts.welcomeTitle')} />
              {e('texts.welcomeTitle') && <span className="field-error">{e('texts.welcomeTitle')}</span>}
            </label>
            <label className="field">Welcome subtitle
              <textarea rows={2} maxLength={TEXT_LIMITS.welcomeSubtitle} value={draft.texts.welcomeSubtitle} onChange={(ev) => update((a) => { a.texts.welcomeSubtitle = ev.target.value; })} />
            </label>
            <Toggle label="Home greeting" hint="“Good morning, <name>” header on Home" checked={draft.texts.homeGreeting} onChange={(v) => update((a) => { a.texts.homeGreeting = v; })} />
          </Section>

          <Section title="Home chips">
            <p className="small-text">Filter chips at the top of Home. Tick to show, arrows to reorder.</p>
            <ul className="order-list">
              {[...draft.home.chips, ...ALL_CHIPS.filter((c) => !draft.home.chips.includes(c))].map((c) => {
                const on = draft.home.chips.includes(c);
                const i = draft.home.chips.indexOf(c);
                return (
                  <li key={c} className={on ? '' : 'off'}>
                    <label className="check grow"><input type="checkbox" checked={on} onChange={(ev) => update((a) => { a.home.chips = toggleChip(a.home.chips, c, ev.target.checked); })} /> {c}</label>
                    <button className="small icon" disabled={!on || i === 0} aria-label={`Move ${c} up`} onClick={() => update((a) => { a.home.chips = moveItem(a.home.chips, i, -1); })}>↑</button>
                    <button className="small icon" disabled={!on || i === draft.home.chips.length - 1} aria-label={`Move ${c} down`} onClick={() => update((a) => { a.home.chips = moveItem(a.home.chips, i, 1); })}>↓</button>
                  </li>
                );
              })}
            </ul>
            {e('home.chips') && <span className="field-error">{e('home.chips')}</span>}
          </Section>

          <Section title="Home sections order">
            <ol className="order-list">
              {draft.home.sectionsOrder.map((s, i) => (
                <li key={s}>
                  <span className="order-n">{i + 1}</span>
                  <span className="grow">{SECTION_LABELS[s] ?? s}{s === 'music_videos' && !draft.features.videos && <span className="small-text"> — hidden (videos off)</span>}</span>
                  <button className="small icon" disabled={i === 0} aria-label={`Move ${SECTION_LABELS[s] ?? s} up`} onClick={() => update((a) => { a.home.sectionsOrder = moveItem(a.home.sectionsOrder, i, -1); })}>↑</button>
                  <button className="small icon" disabled={i === draft.home.sectionsOrder.length - 1} aria-label={`Move ${SECTION_LABELS[s] ?? s} down`} onClick={() => update((a) => { a.home.sectionsOrder = moveItem(a.home.sectionsOrder, i, 1); })}>↓</button>
                </li>
              ))}
            </ol>
          </Section>

          <Section title="Features">
            <div className="toggle-grid">
              {(Object.keys(FEATURE_LABELS) as (keyof Appearance['features'])[]).map((k) => (
                <Toggle key={k} label={FEATURE_LABELS[k].label} hint={FEATURE_LABELS[k].hint} checked={draft.features[k]} onChange={(v) => update((a) => { a.features[k] = v; })} />
              ))}
            </div>
          </Section>

          <Section title="Announcement">
            <Toggle label="Show announcement banner" hint="Shown at the top of Home in every app" checked={draft.announcement.enabled} onChange={(v) => update((a) => { a.announcement.enabled = v; })} />
            <div className="form-grid">
              <label className="field">Style
                <select value={draft.announcement.style} onChange={(ev) => update((a) => { a.announcement.style = ev.target.value as any; })}>
                  <option value="info">Info</option><option value="warning">Warning</option><option value="success">Success</option>
                </select>
              </label>
            </div>
            <label className="field">Text ({draft.announcement.text.length}/{TEXT_LIMITS.announcement})
              <textarea rows={2} maxLength={TEXT_LIMITS.announcement} value={draft.announcement.text} onChange={(ev) => update((a) => { a.announcement.text = ev.target.value; })} aria-invalid={!!e('announcement.text')} />
              {e('announcement.text') && <span className="field-error">{e('announcement.text')}</span>}
            </label>
          </Section>
        </div>

        <aside className="appearance-preview" aria-label="Live preview">
          <PhonePreview a={draft} />
          <p className="small-text center">Live preview of unsaved values</p>
        </aside>
      </div>

      <div className="savebar">
        <ErrorBox error={err} />
        {invalid && <span className="field-error">Fix {Object.keys(errors).length} field{Object.keys(errors).length === 1 ? '' : 's'} before saving.</span>}
        <span className="spacer" />
        <button className="danger" disabled={busy} onClick={reset}>Reset to defaults</button>
        <button disabled={busy || !changes.length} onClick={() => { setDraft(structuredClone(saved)); setErr(null); }}>Discard</button>
        <button className="primary" disabled={busy || !changes.length || invalid} onClick={save}>{busy ? 'Saving…' : 'Save'}</button>
      </div>
    </>
  );
}

function Section({ title, children }: { title: string; children: ReactNode }) {
  return <section className="card form-section"><h2>{title}</h2><div className="stack">{children}</div></section>;
}

function Text({ label, path, value, onChange, max, error, type = 'text' }: { label: string; path: string; value: string; onChange: (v: string) => void; max: number; error?: string; type?: string }) {
  return (
    <label className="field">{label}
      <input type={type} name={path} value={value} maxLength={max} onChange={(e) => onChange(e.target.value)} aria-invalid={!!error} />
      {error && <span className="field-error">{error}</span>}
    </label>
  );
}

function Toggle({ label, hint, checked, onChange }: { label: string; hint?: string; checked: boolean; onChange: (v: boolean) => void }) {
  return (
    <label className="toggle">
      <input type="checkbox" role="switch" checked={checked} onChange={(e) => onChange(e.target.checked)} />
      <span className="switch" aria-hidden="true" />
      <span><span className="strong">{label}</span>{hint && <span className="small-text block">{hint}</span>}</span>
    </label>
  );
}

/** Colour picker + hex text input. The text is kept locally while typing and committed once it is valid. */
function ColorField({ label, hint, value, fallback, onChange, error }: { label: string; hint: string; value: string; fallback: string; onChange: (v: string) => void; error?: string }) {
  const [text, setText] = useState(value);
  useEffect(() => setText(value), [value]);
  const typedInvalid = normalizeHex(text) === null;
  return (
    <div className="color-field">
      <input type="color" value={isHexColor(value) ? value.toLowerCase() : '#000000'} onChange={(e) => onChange(e.target.value.toUpperCase())} aria-label={`${label} colour picker`} />
      <div className="grow">
        <div className="row tight">
          <span className="strong">{label}</span>
          <span className="spacer" />
          {value.toUpperCase() !== fallback.toUpperCase() && <button className="link small-text" type="button" onClick={() => onChange(fallback)} title={`Default ${fallback}`}>default</button>}
        </div>
        <input className="mono" value={text} maxLength={7} aria-label={`${label} hex`} aria-invalid={typedInvalid || !!error}
          onChange={(e) => { setText(e.target.value); const n = normalizeHex(e.target.value); if (n && e.target.value.replace('#', '').length === 6) onChange(n); }}
          onBlur={() => { const n = normalizeHex(text); if (n) onChange(n); else setText(value); }} />
        <span className="small-text">{error ?? hint}</span>
      </div>
    </div>
  );
}

function Contrast({ theme }: { theme: Appearance['theme'] }) {
  const pairs: [string, string, string, number][] = [
    ['Primary text on background', theme.textPrimary, theme.background, 4.5],
    ['Secondary text on surface', theme.textSecondary, theme.surface, 4.5],
    ['On-accent text on accent', theme.onAccent, theme.accent, 3],
  ];
  const low = pairs.filter(([, f, b, min]) => isHexColor(f) && isHexColor(b) && contrastRatio(f, b) < min);
  if (!low.length) return <p className="small-text">Contrast looks good (WCAG AA).</p>;
  return (
    <div className="callout warn">
      Low contrast: {low.map(([n, f, b]) => `${n} (${contrastRatio(f, b).toFixed(1)}:1)`).join(', ')}. Text may be hard to read.
    </div>
  );
}

// ---------------------------------------------------------------------------------------------------------------
// Phone preview. Pure presentational mock driven only by the draft document.

const GENRES: [string, string, string][] = [['Pop', '#7C3AED', '#EC4899'], ['Turkish Rock', '#7F1D1D', '#DC2626'], ['Rock and Metal', '#1D4ED8', '#0F766E'], ['Hip-Hop', '#EA580C', '#FACC15'], ['Jazz', '#0E7490', '#22D3EE']];
const ART = ['linear-gradient(135deg,#3B0A0F,#E31E2D)', 'linear-gradient(135deg,#1E3A8A,#60A5FA)', 'linear-gradient(135deg,#14532D,#4ADE80)', 'linear-gradient(135deg,#581C87,#F0ABFC)', 'linear-gradient(135deg,#78350F,#FBBF24)'];
const ANNOUNCE = { info: '#3B82F6', warning: '#F59E0B', success: '#22C55E' };

function PhonePreview({ a }: { a: Appearance }) {
  const [screen, setScreen] = useState<'home' | 'welcome'>('home');
  const t = a.theme;
  const r = t.cornerRadius;
  const vars = {
    '--p-accent': t.accent, '--p-on-accent': t.onAccent, '--p-bg': t.background, '--p-surface': t.surface, '--p-raised': t.surfaceRaised,
    '--p-border': t.border, '--p-text': t.textPrimary, '--p-text2': t.textSecondary, '--p-title': FONT_STACKS[t.titleFont] ?? FONT_STACKS.mono, '--p-r': `${r}px`,
  } as CSSProperties;
  return (
    <div className="stack center-items">
      <div className="seg" role="tablist" aria-label="Preview screen">
        <button role="tab" aria-selected={screen === 'home'} className={screen === 'home' ? 'on' : ''} onClick={() => setScreen('home')}>Home</button>
        <button role="tab" aria-selected={screen === 'welcome'} className={screen === 'welcome' ? 'on' : ''} onClick={() => setScreen('welcome')}>Welcome</button>
      </div>
      <div className="phone" style={vars} data-testid="phone-preview">
        <div className="p-status"><span>9:41</span><span className="p-island" /><span>▮▮▮</span></div>
        {screen === 'home' ? <PreviewHome a={a} /> : <PreviewWelcome a={a} />}
      </div>
    </div>
  );
}

function SectionHead({ title }: { title: string }) {
  return <div className="p-head"><span>{title}</span><span className="p-more">More</span></div>;
}

function PreviewHome({ a }: { a: Appearance }) {
  const t = a.theme;
  const sections = a.home.sectionsOrder.filter((s) => s !== 'music_videos' || a.features.videos);
  const chips = a.home.chips.filter((c) => c !== 'Videos' || a.features.videos);
  return (
    <>
      <div className="p-scroll">
        {a.announcement.enabled && a.announcement.text && (
          <div className="p-announce" style={{ borderColor: ANNOUNCE[a.announcement.style], background: `color-mix(in srgb, ${ANNOUNCE[a.announcement.style]} 18%, ${t.surface})` }}>{a.announcement.text}</div>
        )}
        {a.texts.homeGreeting && <div className="p-greet">Good morning, Alex</div>}
        {!a.texts.homeGreeting && <div className="p-greet small">{a.brand.appName}</div>}
        <div className="p-chips">
          {chips.map((c, i) => <span key={c} className={`p-chip${i === 0 ? ' on' : ''}`}>{c}</span>)}
        </div>
        {sections.map((s) => <PreviewSection key={s} id={s} a={a} />)}
      </div>
      <div className={`p-mini ${t.playerStyle}`}>
        <span className="p-art" style={{ background: ART[0], width: 34, height: 34 }} />
        <span className="grow"><span className="p-title-text">Rag Doll</span><span className="p-sub">Aerosmith · Permanent Vacation</span></span>
        <span className="p-icon">♡</span><span className="p-icon">❚❚</span>
        <span className="p-progress"><span style={{ width: '38%' }} /></span>
      </div>
      <nav className="p-tabs">
        {[['Home', 'M3 11 12 4l9 7v9h-6v-6H9v6H3z'], ['Search', 'M10 3a7 7 0 1 1 0 14 7 7 0 0 1 0-14Zm0 2a5 5 0 1 0 0 10 5 5 0 0 0 0-10Zm5.3 9.9 5.4 5.4-1.4 1.4-5.4-5.4z'], ['Explore', 'M12 2a10 10 0 1 1 0 20 10 10 0 0 1 0-20Zm4 6-6 2-2 6 6-2z'], ['Library', 'M4 4h4v16H4zm6 0h4v16h-4zm6.5.5 3.9 1-3.9 15-3.9-1z']].map(([n, d], i) => (
          <span key={n} className={i === 0 ? 'on' : ''}><svg viewBox="0 0 24 24" width="16" height="16"><path fill="currentColor" d={d} /></svg>{n}</span>
        ))}
      </nav>
    </>
  );
}

function PreviewSection({ id, a }: { id: string; a: Appearance }) {
  const label = SECTION_LABELS[id] ?? id;
  switch (id) {
    case 'genres':
      return (
        <div className="p-sec"><SectionHead title={label} />
          <div className="p-row">
            {GENRES.map(([g, c1, c2]) => (
              <span key={g} className="p-genre" style={a.theme.genreGradients ? { background: `linear-gradient(135deg, ${c1}, ${c2})`, color: '#fff', borderColor: 'transparent' } : undefined}>{g}</span>
            ))}
          </div>
        </div>
      );
    case 'top_artists':
      return (
        <div className="p-sec"><SectionHead title={label} />
          <div className="p-row">{['Dua Lipa', 'Rammstein', 'Barbara Pravi'].map((n, i) => (
            <span key={n} className="p-artist"><span className="p-avatar" style={{ background: ART[i + 1] }} /><span className="p-sub center">{n}</span></span>
          ))}</div>
        </div>
      );
    case 'popular_singles':
    case 'recently_played':
      return (
        <div className="p-sec"><SectionHead title={label} />
          {[['New Rules', 'Dua Lipa'], ['Thunderstruck', 'AC/DC']].map(([n, ar], i) => (
            <div key={n} className="p-track"><span className="p-art" style={{ background: ART[(i + (id === 'recently_played' ? 2 : 3)) % 5], width: 30, height: 30 }} />
              <span className="grow"><span className="p-title-text">{n}</span><span className="p-sub">{ar}</span></span><span className="p-sub">⋮</span></div>
          ))}
        </div>
      );
    case 'music_videos':
      return (
        <div className="p-sec"><SectionHead title={label} />
          <div className="p-row">{[0, 1].map((i) => <span key={i} className="p-card"><span className="p-art video" style={{ background: ART[(i + 3) % 5] }}><span className="p-play">▶</span></span><span className="p-title-text">Video {i + 1}</span></span>)}</div>
        </div>
      );
    default: {
      const names = id === 'new_albums' ? ['The Highlights', 'Superrock 84', 'Karma'] : id === 'made_for_you' ? ['Daily Mix 1', 'Discover', 'Release Radar'] : ['Chill Hits', 'Rock Classics', 'Focus'];
      return (
        <div className="p-sec"><SectionHead title={label} />
          <div className="p-row">{names.map((n, i) => (
            <span key={n} className="p-card"><span className="p-art" style={{ background: ART[(i + (id === 'new_albums' ? 1 : id === 'made_for_you' ? 2 : 0)) % 5] }} /><span className="p-title-text">{n}</span><span className="p-sub">{id === 'new_albums' ? 'Album' : 'Playlist'}</span></span>
          ))}</div>
        </div>
      );
    }
  }
}

function PreviewWelcome({ a }: { a: Appearance }) {
  return (
    <div className="p-scroll p-welcome">
      <svg viewBox="0 0 1024 1024" width="44" height="44" aria-hidden="true"><rect width="1024" height="1024" rx="232" fill={a.theme.surfaceRaised} /><g transform="translate(-46 0)" fill="none" strokeLinecap="round" strokeLinejoin="round"><path d="M300 322 L300 702 L560 512 Z" fill={a.theme.accent} stroke={a.theme.accent} strokeWidth="72" /><path d="M660 402 A150 150 0 0 1 660 622" stroke={a.theme.textPrimary} strokeWidth="64" /><path d="M752 318 A262 262 0 0 1 752 706" stroke={a.theme.accent} strokeWidth="64" /></g></svg>
      <div className="p-wtitle">{a.texts.welcomeTitle}</div>
      <div className="p-sub" style={{ fontSize: 11 }}>{a.texts.welcomeSubtitle}</div>
      <div className="p-sub" style={{ fontSize: 10 }}>{a.brand.appName} — {a.brand.tagline}</div>
      {a.features.appleSignIn && <span className="p-outline"> Continue with Apple</span>}
      <span className="p-label">Email address</span>
      <span className="p-input">Enter your email address</span>
      <span className="p-btn">Next →</span>
      {a.features.signup ? <span className="p-sub center">Already have an account? <b style={{ color: 'var(--p-accent)' }}>Log in</b></span> : <span className="p-sub center">Sign-up is invitation only</span>}
      <span className="p-sub center" style={{ marginTop: 'auto', fontSize: 9 }}>by {a.brand.developer}</span>
    </div>
  );
}
