/**
 * Audio output: two HTMLAudioElements (current + preloaded next, for near-gapless transitions) routed
 * through one Web Audio graph:  element → MediaElementSource → preamp → 10 BiquadFilters → analyser → out.
 * The AudioContext is created on the first user-initiated play (browser autoplay policy). If Web Audio
 * is unavailable the elements still play directly, just without the EQ.
 */
import { bandConfigs, effectiveGains, preampGain, type EqSettings } from '../lib/eq';

export interface EngineEvents {
  onTime(current: number, duration: number, buffered: number): void;
  onPlaying(playing: boolean): void;
  onWaiting(waiting: boolean): void;
  onEnded(): void;
  onError(message: string): void;
}

function makeAudio(): HTMLAudioElement {
  const a = new Audio();
  a.preload = 'auto';
  return a;
}

export function needsCors(url: string, origin = typeof location !== 'undefined' ? location.origin : ''): boolean {
  try {
    return new URL(url, origin || 'http://x.invalid').origin !== origin;
  } catch {
    return false;
  }
}

export class AudioEngine {
  private els: [HTMLAudioElement, HTMLAudioElement] = [makeAudio(), makeAudio()];
  private active = 0;
  private preloadedKey: string | null = null;
  private ctx: AudioContext | null = null;
  private preamp: GainNode | null = null;
  private filters: BiquadFilterNode[] = [];
  analyser: AnalyserNode | null = null;
  private eq: EqSettings | null = null;
  private volume = 1;
  private muted = false;

  constructor(private readonly ev: EngineEvents) {
    for (const el of this.els) this.attach(el);
  }

  get element() {
    return this.els[this.active];
  }
  private get standby() {
    return this.els[1 - this.active];
  }

  private attach(el: HTMLAudioElement) {
    const isActive = () => el === this.element;
    const time = () => {
      if (!isActive()) return;
      const b = el.buffered.length ? el.buffered.end(el.buffered.length - 1) : 0;
      this.ev.onTime(el.currentTime, Number.isFinite(el.duration) ? el.duration : 0, b);
    };
    el.addEventListener('timeupdate', time);
    el.addEventListener('durationchange', time);
    el.addEventListener('progress', time);
    el.addEventListener('playing', () => isActive() && (this.ev.onPlaying(true), this.ev.onWaiting(false)));
    el.addEventListener('pause', () => isActive() && this.ev.onPlaying(false));
    el.addEventListener('waiting', () => isActive() && this.ev.onWaiting(true));
    el.addEventListener('canplay', () => isActive() && this.ev.onWaiting(false));
    el.addEventListener('ended', () => isActive() && this.ev.onEnded());
    el.addEventListener('error', () => {
      if (!isActive() || !el.src) return;
      const code = el.error?.code;
      this.ev.onError(code === 4 ? 'This format is not supported by your browser.' : 'Playback failed. Check your connection.');
    });
  }

  /** Builds the Web Audio graph once, on a user gesture. */
  private ensureGraph() {
    if (this.ctx) {
      if (this.ctx.state === 'suspended') void this.ctx.resume();
      return;
    }
    const Ctor = window.AudioContext ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!Ctor) return;
    try {
      const ctx = new Ctor({ latencyHint: 'playback' });
      const preamp = ctx.createGain();
      const filters = bandConfigs().map((b) => {
        const f = ctx.createBiquadFilter();
        f.type = b.type;
        f.frequency.value = b.frequency;
        f.Q.value = b.Q;
        f.gain.value = 0;
        return f;
      });
      const analyser = ctx.createAnalyser();
      analyser.fftSize = 256;
      let node: AudioNode = preamp;
      for (const f of filters) {
        node.connect(f);
        node = f;
      }
      node.connect(analyser);
      analyser.connect(ctx.destination);
      for (const el of this.els) ctx.createMediaElementSource(el).connect(preamp);
      this.ctx = ctx;
      this.preamp = preamp;
      this.filters = filters;
      this.analyser = analyser;
      if (this.eq) this.setEq(this.eq);
    } catch {
      this.ctx = null; // fall back to plain element output
    }
  }

  get eqAvailable() {
    return !!this.ctx || typeof window.AudioContext !== 'undefined';
  }

  setEq(s: EqSettings) {
    this.eq = s;
    if (!this.ctx || !this.preamp) return;
    const t = this.ctx.currentTime;
    const gains = effectiveGains(s);
    this.filters.forEach((f, i) => f.gain.setTargetAtTime(gains[i], t, 0.02));
    this.preamp.gain.setTargetAtTime(preampGain(s), t, 0.02);
  }

  setVolume(v: number, muted: boolean) {
    this.volume = Math.max(0, Math.min(1, v));
    this.muted = muted;
    for (const el of this.els) {
      el.volume = this.volume * this.volume; // perceptual curve
      el.muted = muted;
    }
  }

  private prepare(el: HTMLAudioElement, url: string) {
    if (needsCors(url)) el.crossOrigin = 'anonymous';
    else el.removeAttribute('crossorigin');
    el.src = url;
    el.volume = this.volume * this.volume;
    el.muted = this.muted;
  }

  /** Loads `url` as the current item. Uses the preloaded element when it holds the same item. */
  load(key: string, url: string, startAt = 0, autoplay = true) {
    if (this.preloadedKey === key && this.standby.src) {
      this.element.pause();
      this.element.removeAttribute('src');
      this.element.load();
      this.active = 1 - this.active;
      this.preloadedKey = null;
    } else {
      this.element.pause();
      this.prepare(this.element, url);
    }
    const el = this.element;
    if (startAt > 0) {
      const seek = () => {
        el.currentTime = startAt;
        el.removeEventListener('loadedmetadata', seek);
      };
      if (el.readyState >= 1) el.currentTime = startAt;
      else el.addEventListener('loadedmetadata', seek);
    } else if (el.currentTime > 0) el.currentTime = 0;
    if (autoplay) return this.play();
    return Promise.resolve();
  }

  /** Buffers the next item in the standby element. */
  preload(key: string, url: string) {
    if (this.preloadedKey === key) return;
    this.preloadedKey = key;
    this.standby.pause();
    this.prepare(this.standby, url);
    this.standby.load();
  }

  clearPreload() {
    this.preloadedKey = null;
    this.standby.removeAttribute('src');
  }

  async play() {
    this.ensureGraph();
    try {
      await this.element.play();
    } catch (e) {
      if ((e as Error).name === 'NotAllowedError') this.ev.onPlaying(false);
      else if ((e as Error).name !== 'AbortError') this.ev.onError('Playback failed.');
    }
  }

  pause() {
    this.element.pause();
  }

  seek(t: number) {
    const el = this.element;
    if (Number.isFinite(t)) el.currentTime = Math.max(0, Math.min(t, Number.isFinite(el.duration) ? el.duration : t));
  }

  stop() {
    for (const el of this.els) {
      el.pause();
      el.removeAttribute('src');
      el.load();
    }
    this.preloadedKey = null;
  }

  canPlay(mime: string) {
    return this.element.canPlayType(mime) !== '';
  }
}
