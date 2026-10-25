import { useEffect, useMemo, useRef, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import * as I from '../components/Icons';
import { artUrl, Artwork, Empty, GenreChip, Spinner } from '../components/ui';
import { api } from '../lib/api';
import { applyPreset, bandConfigs, EQ_FREQUENCIES, EQ_MAX_DB, EQ_MIN_DB, EQ_PRESET_NAMES, formatFreq, setBand, type EqSettings } from '../lib/eq';
import { formatTime } from '../lib/format';
import { LyricsTimeline } from '../lib/lyrics';
import * as Q from '../lib/queue';
import type { Track } from '../lib/types';
import { toggleSaved, useConfig, useSaved } from '../state/app';
import { controls, getAnalyser, player, useCurrentTrack, usePlayer } from './player';

// ---- Small controls -------------------------------------------------------------------------------
export function Progress({ compact }: { compact?: boolean }) {
  const time = usePlayer((s) => s.time);
  const duration = usePlayer((s) => s.duration);
  const buffered = usePlayer((s) => s.buffered);
  const [drag, setDrag] = useState<number | null>(null);
  const t = drag ?? time;
  const pct = duration ? (t / duration) * 100 : 0;
  const bpct = duration ? Math.min(100, (buffered / duration) * 100) : 0;
  return (
    <div className={`progress ${compact ? 'compact' : ''}`}>
      <span className="time">{formatTime(t)}</span>
      <input
        type="range"
        className="slider"
        min={0}
        max={duration || 1}
        step={0.1}
        value={t}
        aria-label="Seek"
        style={{ '--pct': `${pct}%`, '--buf': `${bpct}%` } as React.CSSProperties}
        onChange={(e) => setDrag(Number(e.target.value))}
        onPointerUp={() => {
          if (drag !== null) controls.seek(drag);
          setDrag(null);
        }}
        onKeyUp={() => {
          if (drag !== null) controls.seek(drag);
          setDrag(null);
        }}
      />
      <span className="time">{formatTime(duration)}</span>
    </div>
  );
}

export function Volume() {
  const volume = usePlayer((s) => s.volume);
  const muted = usePlayer((s) => s.muted);
  const v = muted ? 0 : volume;
  const Icon = v === 0 ? I.IconMute : v < 0.5 ? I.IconVolumeLow : I.IconVolume;
  return (
    <div className="volume">
      <button className="icon-btn" aria-label={muted ? 'Unmute' : 'Mute'} onClick={controls.toggleMute}>
        <Icon size={20} />
      </button>
      <input
        type="range"
        className="slider"
        min={0}
        max={1}
        step={0.01}
        value={v}
        aria-label="Volume"
        style={{ '--pct': `${v * 100}%` } as React.CSSProperties}
        onChange={(e) => controls.setVolume(Number(e.target.value))}
      />
    </div>
  );
}

function Transport({ big }: { big?: boolean }) {
  const playing = usePlayer((s) => s.playing);
  const waiting = usePlayer((s) => s.waiting);
  const shuffle = usePlayer((s) => s.queue.shuffle);
  const repeat = usePlayer((s) => s.queue.repeat);
  const s = big ? 28 : 20;
  return (
    <div className={`transport ${big ? 'big' : ''}`}>
      <button className={`icon-btn ${shuffle ? 'on' : ''}`} aria-label="Shuffle" aria-pressed={shuffle} onClick={controls.toggleShuffle}>
        <I.IconShuffle size={s - 2} />
      </button>
      <button className="icon-btn" aria-label="Previous" onClick={controls.previous}>
        <I.IconPrev size={s} />
      </button>
      <button className={`play-btn white main ${waiting && playing ? 'loading' : ''}`} aria-label={playing ? 'Pause' : 'Play'} onClick={controls.toggle}>
        {playing ? <I.IconPause size={big ? 34 : 18} /> : <I.IconPlay size={big ? 34 : 18} style={{ marginLeft: big ? 4 : 2 }} />}
      </button>
      <button className="icon-btn" aria-label="Next" onClick={controls.next}>
        <I.IconNext size={s} />
      </button>
      <button className={`icon-btn ${repeat !== 'off' ? 'on' : ''}`} aria-label={`Repeat: ${repeat}`} onClick={controls.cycleRepeat}>
        {repeat === 'one' ? <I.IconRepeatOne size={s - 2} /> : <I.IconRepeat size={s - 2} />}
      </button>
    </div>
  );
}

function LikeButton({ track, size = 20 }: { track: Track; size?: number }) {
  const liked = useSaved('track', track.id);
  return (
    <button className={`icon-btn ${liked ? 'on' : ''}`} aria-label={liked ? 'Remove from Liked Songs' : 'Add to Liked Songs'} onClick={() => toggleSaved('track', track.id)}>
      {liked ? <I.IconHeartFilled size={size} /> : <I.IconHeart size={size} />}
    </button>
  );
}

function QualityBadge() {
  const stream = usePlayer((s) => s.stream);
  if (!stream) return null;
  const d = stream.delivery;
  const label = d.lossless ? `LOSSLESS${d.bitDepth && d.sampleRate ? ` ${d.bitDepth}/${Math.round(d.sampleRate / 100) / 10}` : ''}` : `${(d.codec ?? 'AAC').toUpperCase()}${d.bitrateKbps ? ` ${d.bitrateKbps}` : ''}`;
  return <span className={`quality-badge ${d.lossless ? 'lossless' : ''}`}>{label}</span>;
}

// ---- Desktop now-playing bar ----------------------------------------------------------------------
export function NowPlayingBar() {
  const track = useCurrentTrack();
  const panel = usePlayer((s) => s.panel);
  const cfg = useConfig();
  if (!track) return null;
  return (
    <footer className="now-bar" aria-label="Now playing">
      <div className="nb-left">
        <button className="nb-art" onClick={() => controls.setExpanded(true)} aria-label="Open player">
          <Artwork src={track.artworkUrl ?? track.album?.artworkUrl} />
        </button>
        <div className="nb-meta">
          <div className="nb-title title-font">{track.title}</div>
          <div className="nb-sub">
            <Link to={`/artist/${track.artist.id}`}>{track.artist.name}</Link>
            {track.album && (
              <>
                {' • '}
                <Link to={`/album/${track.album.id}`}>{track.album.title}</Link>
              </>
            )}
          </div>
        </div>
        <LikeButton track={track} />
      </div>
      <div className="nb-center">
        <Transport />
        <Progress compact />
      </div>
      <div className="nb-right">
        <QualityBadge />
        {cfg.features.lyrics && (
          <button className={`icon-btn ${panel === 'lyrics' ? 'on' : ''}`} aria-label="Lyrics" onClick={() => controls.togglePanel('lyrics')}>
            <I.IconLyrics size={20} />
          </button>
        )}
        <button className={`icon-btn ${panel === 'queue' ? 'on' : ''}`} aria-label="Queue" onClick={() => controls.togglePanel('queue')}>
          <I.IconQueue size={20} />
        </button>
        {cfg.features.equalizer && (
          <button className={`icon-btn ${panel === 'eq' ? 'on' : ''}`} aria-label="Equalizer" onClick={() => controls.togglePanel('eq')}>
            <I.IconEq size={20} />
          </button>
        )}
        <Volume />
        <button className="icon-btn" aria-label="Full screen player" onClick={() => controls.setExpanded(true)}>
          <I.IconExpand size={18} />
        </button>
      </div>
    </footer>
  );
}

// ---- Mobile mini player ---------------------------------------------------------------------------
export function MiniPlayer() {
  const track = useCurrentTrack();
  const playing = usePlayer((s) => s.playing);
  const pct = usePlayer((s) => (s.duration ? (s.time / s.duration) * 100 : 0));
  if (!track) return null;
  return (
    <div className="mini-player" onClick={() => controls.setExpanded(true)} role="button" aria-label="Open player" tabIndex={0}>
      <Artwork src={track.artworkUrl ?? track.album?.artworkUrl} />
      <div className="mp-meta">
        <div className="mp-title title-font">{track.title}</div>
        <div className="mp-sub">
          {track.artist.name}
          {track.album ? ` • ${track.album.title}` : ''}
        </div>
      </div>
      <div onClick={(e) => e.stopPropagation()} className="mp-actions">
        <LikeButton track={track} size={22} />
        <button className="icon-btn" aria-label={playing ? 'Pause' : 'Play'} onClick={controls.toggle}>
          {playing ? <I.IconPause size={24} /> : <I.IconPlay size={24} />}
        </button>
      </div>
      <span className="mp-progress" style={{ width: `${pct}%` }} />
    </div>
  );
}

// ---- Side panel (desktop) -------------------------------------------------------------------------
export function SidePanel() {
  const panel = usePlayer((s) => s.panel);
  const track = useCurrentTrack();
  if (panel === 'none' || !track) return null;
  const title = panel === 'queue' ? 'Queue' : panel === 'lyrics' ? 'Lyrics' : 'Equalizer';
  return (
    <aside className="side-panel" aria-label={title}>
      <header>
        <h3>{title}</h3>
        <button className="icon-btn" aria-label="Close panel" onClick={() => controls.togglePanel('none')}>
          <I.IconClose size={18} />
        </button>
      </header>
      <div className="side-body">
        {panel === 'queue' && <QueueView />}
        {panel === 'lyrics' && <LyricsView track={track} />}
        {panel === 'eq' && <EqualizerView />}
      </div>
    </aside>
  );
}

// ---- Lyrics ---------------------------------------------------------------------------------------
export function LyricsView({ track }: { track: Track }) {
  const [state, setState] = useState<{ t?: LyricsTimeline; err?: boolean; loading: boolean; attribution?: string }>({ loading: true });
  useEffect(() => {
    let alive = true;
    setState({ loading: true });
    if (!track.hasLyrics) {
      setState({ loading: false });
      return;
    }
    api
      .lyrics(track.id)
      .then((r) => alive && setState({ t: LyricsTimeline.fromResponse(r), loading: false, attribution: r.attribution?.source ?? undefined }))
      .catch(() => alive && setState({ err: true, loading: false }));
    return () => {
      alive = false;
    };
  }, [track.id, track.hasLyrics]);
  const time = usePlayer((s) => s.time);
  const active = state.t?.activeIndex(time) ?? null;
  const box = useRef<HTMLDivElement>(null);
  const userScrolled = useRef(0);
  useEffect(() => {
    if (active === null || !box.current || Date.now() - userScrolled.current < 4000) return;
    const el = box.current.querySelector<HTMLElement>(`[data-line="${active}"]`);
    if (el) box.current.scrollTo({ top: el.offsetTop - box.current.clientHeight * 0.38, behavior: 'smooth' });
  }, [active]);
  if (state.loading) return <Spinner />;
  if (!state.t || !state.t.lines.length) return <Empty title="No lyrics for this song" icon={<I.IconLyrics size={36} />}>Lyrics appear here when they are available.</Empty>;
  const t = state.t;
  return (
    <div className={`lyrics ${t.synced ? 'synced' : ''}`} ref={box} onWheel={() => (userScrolled.current = Date.now())} onTouchMove={() => (userScrolled.current = Date.now())}>
      {t.lines.map((l, i) => (
        <p
          key={l.id}
          data-line={i}
          className={active === null ? '' : i === active ? 'active' : i < active ? 'past' : ''}
          onClick={t.synced ? () => {
            userScrolled.current = 0;
            controls.seek(l.start);
            if (!player.get().playing) void controls.play();
          } : undefined}
        >
          {l.text || '♪'}
        </p>
      ))}
      {state.attribution && <p className="lyrics-attr">Lyrics: {state.attribution}</p>}
    </div>
  );
}

// ---- Queue ----------------------------------------------------------------------------------------
export function QueueView() {
  const queue = usePlayer((s) => s.queue);
  const cur = Q.current(queue);
  const next = Q.upNext(queue);
  const base = (queue.currentIndex ?? -1) + 1;
  const [dragFrom, setDragFrom] = useState<number | null>(null);
  const [over, setOver] = useState<number | null>(null);
  if (!cur) return <Empty title="Your queue is empty" />;
  return (
    <div className="queue">
      <h4 className="queue-h">Now playing</h4>
      <QueueRow track={cur.track} current />
      <div className="queue-h-row">
        <h4 className="queue-h">Up Next{queue.context?.title ? <span className="muted"> · from {queue.context.title}</span> : null}</h4>
        {next.length > 0 && (
          <button className="pill pill-sm" onClick={controls.clearUpNext}>
            Clear
          </button>
        )}
      </div>
      {next.length === 0 && <p className="muted small">Nothing queued. Add songs with “Play next” or “Add to queue”.</p>}
      <ol className="queue-list">
        {next.map((it, i) => {
          const abs = base + i;
          return (
            <li
              key={it.id}
              draggable
              className={`${over === abs ? 'drag-over' : ''} ${dragFrom === abs ? 'dragging' : ''}`}
              onDragStart={(e) => {
                setDragFrom(abs);
                e.dataTransfer.effectAllowed = 'move';
              }}
              onDragOver={(e) => {
                e.preventDefault();
                setOver(abs);
              }}
              onDragEnd={() => {
                setDragFrom(null);
                setOver(null);
              }}
              onDrop={(e) => {
                e.preventDefault();
                if (dragFrom !== null) controls.moveInQueue(dragFrom, abs);
                setDragFrom(null);
                setOver(null);
              }}
            >
              <QueueRow
                track={it.track}
                onPlay={() => controls.jumpTo(abs)}
                actions={
                  <>
                    <button className="icon-btn hide-xs" aria-label="Move up" disabled={i === 0} onClick={() => controls.moveInQueue(abs, abs - 1)}>
                      <I.IconArrowUp size={16} />
                    </button>
                    <button className="icon-btn hide-xs" aria-label="Move down" disabled={i === next.length - 1} onClick={() => controls.moveInQueue(abs, abs + 1)}>
                      <I.IconArrowDown size={16} />
                    </button>
                    <button className="icon-btn" aria-label={`Remove ${it.track.title} from queue`} onClick={() => controls.removeFromQueue(it.id)}>
                      <I.IconClose size={16} />
                    </button>
                  </>
                }
              />
            </li>
          );
        })}
      </ol>
    </div>
  );
}

function QueueRow({ track, current, onPlay, actions }: { track: Track; current?: boolean; onPlay?: () => void; actions?: React.ReactNode }) {
  return (
    <div className={`queue-row ${current ? 'current' : ''}`}>
      <span className="drag-handle" aria-hidden>
        {!current && <I.IconDrag size={14} />}
      </span>
      <Artwork src={track.artworkUrl ?? track.album?.artworkUrl} />
      <div className="tr-main">
        <div className="tr-title title-font">{track.title}</div>
        <div className="tr-sub">{track.artist.name}</div>
      </div>
      <span className="tr-dur">{formatTime(track.durationMs / 1000)}</span>
      {onPlay && (
        <button className="icon-btn" aria-label={`Play ${track.title}`} onClick={onPlay}>
          <I.IconPlay size={18} />
        </button>
      )}
      {actions}
    </div>
  );
}

// ---- Equalizer ------------------------------------------------------------------------------------
/** Combined magnitude response of the filter chain, for the curve preview (computed with an OfflineAudioContext-free approximation). */
function responseCurve(eq: EqSettings, points = 120): number[] {
  const bands = bandConfigs();
  const out: number[] = [];
  for (let p = 0; p < points; p++) {
    const f = 20 * Math.pow(1000, p / (points - 1)); // 20 Hz … 20 kHz
    let db = 0;
    bands.forEach((b, i) => {
      const g = eq.enabled ? eq.gains[i] : 0;
      const x = Math.log2(f / b.frequency);
      if (b.type === 'peaking') db += g * Math.exp(-(x * x) / (2 * 0.45 * 0.45));
      else if (b.type === 'lowshelf') db += g / (1 + Math.exp(x * 3));
      else db += g / (1 + Math.exp(-x * 3));
    });
    out.push(db);
  }
  return out;
}

function Spectrum() {
  const canvas = useRef<HTMLCanvasElement>(null);
  const playing = usePlayer((s) => s.playing);
  useEffect(() => {
    const an = getAnalyser();
    const c = canvas.current;
    if (!an || !c || !playing) return;
    const ctx = c.getContext('2d')!;
    const data = new Uint8Array(an.frequencyBinCount);
    let raf = 0;
    const color = getComputedStyle(document.documentElement).getPropertyValue('--accent').trim() || '#E31E2D';
    const draw = () => {
      an.getByteFrequencyData(data);
      ctx.clearRect(0, 0, c.width, c.height);
      const n = 48;
      const w = c.width / n;
      ctx.fillStyle = color;
      ctx.globalAlpha = 0.35;
      for (let i = 0; i < n; i++) {
        const idx = Math.floor(Math.pow(i / n, 2) * data.length * 0.9);
        const h = (data[idx] / 255) * c.height;
        ctx.fillRect(i * w + 1, c.height - h, w - 2, h);
      }
      raf = requestAnimationFrame(draw);
    };
    draw();
    return () => cancelAnimationFrame(raf);
  }, [playing]);
  return <canvas ref={canvas} className="eq-spectrum" width={480} height={120} aria-hidden />;
}

export function EqualizerView() {
  const eq = usePlayer((s) => s.eq);
  const curve = useMemo(() => responseCurve(eq), [eq]);
  const path = curve.map((db, i) => `${i === 0 ? 'M' : 'L'}${(i / (curve.length - 1)) * 100},${50 - (db / 14) * 45}`).join(' ');
  const set = (next: EqSettings) => controls.setEq(next);
  return (
    <div className={`eq ${eq.enabled ? '' : 'off'}`}>
      <div className="eq-top">
        <label className="switch">
          <input type="checkbox" checked={eq.enabled} onChange={(e) => set({ ...eq, enabled: e.target.checked })} />
          <span className="switch-track" />
          <span>{eq.enabled ? 'Equalizer on' : 'Equalizer off'}</span>
        </label>
        <button className="pill pill-sm" onClick={() => set({ ...applyPreset(eq, 'Flat'), preamp: 0 })}>
          Reset
        </button>
      </div>
      <div className="eq-presets" role="radiogroup" aria-label="Presets">
        {EQ_PRESET_NAMES.map((p) => (
          <button key={p} role="radio" aria-checked={eq.preset === p} className={`chip ${eq.preset === p ? 'active' : ''}`} onClick={() => set({ ...applyPreset(eq, p), enabled: true })}>
            {p}
          </button>
        ))}
        {eq.preset === 'Custom' && <span className="chip active">Custom</span>}
      </div>
      <div className="eq-graph">
        <Spectrum />
        <svg viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden>
          <line x1="0" x2="100" y1="50" y2="50" className="eq-zero" />
          <path d={path} className="eq-curve" />
        </svg>
      </div>
      <div className="eq-bands">
        <div className="eq-band preamp">
          <span className="eq-val">{eq.preamp > 0 ? '+' : ''}{eq.preamp.toFixed(0)}</span>
          <input
            type="range"
            className="vslider"
            min={EQ_MIN_DB}
            max={EQ_MAX_DB}
            step={0.5}
            value={eq.preamp}
            aria-label="Preamp"
            onChange={(e) => set({ ...eq, preamp: Number(e.target.value) })}
          />
          <span className="eq-freq">PRE</span>
        </div>
        {EQ_FREQUENCIES.map((f, i) => (
          <div className="eq-band" key={f}>
            <span className="eq-val">{eq.gains[i] > 0 ? '+' : ''}{eq.gains[i].toFixed(0)}</span>
            <input
              type="range"
              className="vslider"
              min={EQ_MIN_DB}
              max={EQ_MAX_DB}
              step={0.5}
              value={eq.gains[i]}
              aria-label={`${formatFreq(f)} Hz`}
              onChange={(e) => set({ ...setBand(eq, i, Number(e.target.value)), enabled: true })}
            />
            <span className="eq-freq">{formatFreq(f)}</span>
          </div>
        ))}
      </div>
      <p className="muted small">±12 dB per band. Settings are saved on this device.</p>
    </div>
  );
}

// ---- Full-screen player (Song / Lyrics / Up Next) -------------------------------------------------
export function FullPlayer() {
  const expanded = usePlayer((s) => s.expanded);
  const track = useCurrentTrack();
  const cfg = useConfig();
  const [tab, setTab] = useState<'song' | 'lyrics' | 'next' | 'eq'>('song');
  const nav = useNavigate();
  useEffect(() => {
    if (!expanded) return;
    const k = (e: KeyboardEvent) => e.key === 'Escape' && controls.setExpanded(false);
    window.addEventListener('keydown', k);
    return () => window.removeEventListener('keydown', k);
  }, [expanded]);
  if (!expanded || !track) return null;
  const art = artUrl(track.artworkUrl ?? track.album?.artworkUrl, 'large');
  const go = (to: string) => {
    controls.setExpanded(false);
    nav(to);
  };
  const tabs: [typeof tab, string][] = [
    ['song', 'Song'],
    ...(cfg.features.lyrics ? ([['lyrics', 'Lyrics']] as [typeof tab, string][]) : []),
    ['next', 'Up Next'],
    ...(cfg.features.equalizer ? ([['eq', 'EQ']] as [typeof tab, string][]) : []),
  ];
  return (
    <div className={`full-player ${cfg.theme.playerStyle}`} role="dialog" aria-modal="true" aria-label="Player">
      {cfg.theme.playerStyle === 'artwork' && art && <div className="fp-bg" style={{ backgroundImage: `url("${art}")` }} />}
      <header className="fp-head">
        <button className="icon-btn" aria-label="Close player" onClick={() => controls.setExpanded(false)}>
          <I.IconChevronDown size={26} />
        </button>
        <nav className="fp-tabs" role="tablist">
          {tabs.map(([id, label]) => (
            <button key={id} role="tab" aria-selected={tab === id} className={tab === id ? 'active' : ''} onClick={() => setTab(id)}>
              {label}
            </button>
          ))}
        </nav>
        <span style={{ width: 40 }} />
      </header>
      <div className={`fp-body tab-${tab}`}>
        <div className="fp-song">
          <div className="fp-art">
            <Artwork src={track.artworkUrl ?? track.album?.artworkUrl} size="large" />
          </div>
          <div className="fp-info">
            <LikeButton track={track} size={24} />
            <div className="fp-titles">
              <h2 className="title-font">{track.title}</h2>
              <p>
                <button className="link" onClick={() => go(`/artist/${track.artist.id}`)}>
                  {track.artist.name}
                </button>
                {track.album && (
                  <>
                    {' • '}
                    <button className="link" onClick={() => go(`/album/${track.album!.id}`)}>
                      {track.album.title}
                    </button>
                  </>
                )}
              </p>
            </div>
            <QualityBadge />
          </div>
          {track.genres.length > 0 && (
            <div className="fp-genres" onClick={() => controls.setExpanded(false)}>
              {track.genres.slice(0, 5).map((g) => (
                <GenreChip key={g} name={g} plain />
              ))}
            </div>
          )}
          <Progress />
          <Transport big />
          <div className="fp-bottom">
            <button className="icon-btn" aria-label="Up Next" onClick={() => setTab('next')}>
              <I.IconQueue />
            </button>
            <div className="fp-volume">
              <Volume />
            </div>
            {cfg.features.radio && (
              <button className="icon-btn" aria-label="Artist radio" onClick={() => go(`/mix/${encodeURIComponent(`artist:${track.artist.id}`)}`)}>
                <I.IconRadio />
              </button>
            )}
          </div>
        </div>
        {tab !== 'song' && (
          <div className="fp-side">
            <div className="fp-mini">
              <Artwork src={track.artworkUrl ?? track.album?.artworkUrl} />
              <div className="tr-main">
                <div className="tr-title title-font">{track.title}</div>
                <div className="tr-sub">{track.artist.name}</div>
              </div>
              <button className="icon-btn" aria-label="Next" onClick={controls.next}>
                <I.IconNext />
              </button>
              <MiniToggle />
            </div>
            {tab === 'lyrics' && <LyricsView track={track} />}
            {tab === 'next' && (
              <>
                {track.genres.length > 0 && (
                  <div className="fp-related">
                    <h3>Related Genres</h3>
                    <div className="chip-row" onClick={() => controls.setExpanded(false)}>
                      {track.genres.map((g) => (
                        <GenreChip key={g} name={g} plain />
                      ))}
                    </div>
                  </div>
                )}
                <QueueView />
              </>
            )}
            {tab === 'eq' && <EqualizerView />}
          </div>
        )}
      </div>
    </div>
  );
}

function MiniToggle() {
  const playing = usePlayer((s) => s.playing);
  return (
    <button className="icon-btn" aria-label={playing ? 'Pause' : 'Play'} onClick={controls.toggle}>
      {playing ? <I.IconPause /> : <I.IconPlay />}
    </button>
  );
}

// ---- Keyboard shortcuts ---------------------------------------------------------------------------
export function useKeyboardShortcuts() {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement;
      if (t && (t.isContentEditable || ['INPUT', 'TEXTAREA', 'SELECT'].includes(t.tagName)) && !(t instanceof HTMLInputElement && t.type === 'range')) return;
      if (e.metaKey || e.ctrlKey || e.altKey) return;
      if (!Q.current(player.get().queue)) return;
      const s = player.get();
      switch (e.key) {
        case ' ':
        case 'k':
          if (t instanceof HTMLButtonElement && e.key === ' ') return; // let the focused button act
          e.preventDefault();
          controls.toggle();
          break;
        case 'ArrowRight':
          if (t instanceof HTMLInputElement) return;
          e.preventDefault();
          if (e.shiftKey) controls.next();
          else controls.seek(s.time + 5);
          break;
        case 'ArrowLeft':
          if (t instanceof HTMLInputElement) return;
          e.preventDefault();
          if (e.shiftKey) controls.previous();
          else controls.seek(s.time - 5);
          break;
        case 'ArrowUp':
          if (t instanceof HTMLInputElement) return;
          e.preventDefault();
          controls.setVolume(s.volume + 0.05);
          break;
        case 'ArrowDown':
          if (t instanceof HTMLInputElement) return;
          e.preventDefault();
          controls.setVolume(s.volume - 0.05);
          break;
        case 'm':
          controls.toggleMute();
          break;
        case 's':
          controls.toggleShuffle();
          break;
        case 'r':
          controls.cycleRepeat();
          break;
        case 'n':
          controls.next();
          break;
        case 'p':
          controls.previous();
          break;
        case 'l':
          controls.togglePanel('lyrics');
          break;
        case 'q':
          controls.togglePanel('queue');
          break;
      }
    };
    window.addEventListener('keydown', onKey);
    return () => window.removeEventListener('keydown', onKey);
  }, []);
}
