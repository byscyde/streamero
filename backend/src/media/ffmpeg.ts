import { spawn } from 'node:child_process';

/**
 * Container formats accepted as *input*. Passed to FFmpeg/FFprobe as `-format_whitelist` so crafted
 * files cannot switch to demuxers that read other files or URLs (hls, concat, image2 sequences, ...).
 */
export const INPUT_FORMATS = [
  'mp3', 'mov', 'mp4', 'm4a', '3gp', '3g2', 'mj2', 'flac', 'wav', 'w64', 'aiff', 'ogg', 'matroska', 'webm',
  'aac', 'avi', 'mpegts', 'caf', 'wv', 'ape', 'srt', 'webvtt', 'ass', 'mjpeg', 'png_pipe', 'jpeg_pipe', 'webp_pipe',
] as const;

const SAFE_INPUT_ARGS = ['-protocol_whitelist', 'file', '-format_whitelist', INPUT_FORMATS.join(',')];

export interface FfmpegOptions {
  ffmpegPath: string;
  ffprobePath: string;
  timeoutSeconds: number;
  threads: number;
}

export interface ProbeStream {
  index: number;
  codec_type: 'audio' | 'video' | 'subtitle' | 'data' | 'attachment';
  codec_name?: string;
  profile?: string;
  width?: number;
  height?: number;
  sample_rate?: string;
  channels?: number;
  bits_per_raw_sample?: string;
  bits_per_sample?: number;
  sample_fmt?: string;
  bit_rate?: string;
  duration?: string;
  avg_frame_rate?: string;
  disposition?: Record<string, number>;
  tags?: Record<string, string>;
}

export interface ProbeResult {
  format: {
    format_name: string;
    duration?: string;
    bit_rate?: string;
    size?: string;
    tags?: Record<string, string>;
  };
  streams: ProbeStream[];
}

export class FfmpegError extends Error {
  constructor(
    message: string,
    readonly stderrTail: string,
  ) {
    super(message);
  }
}

export class Ffmpeg {
  constructor(private readonly opts: FfmpegOptions) {}

  private run(bin: string, args: string[], onStdout?: (chunk: string) => void, timeoutSeconds = this.opts.timeoutSeconds) {
    return new Promise<{ stdout: string; stderr: string }>((resolve, reject) => {
      // No shell: arguments are passed verbatim, so file names can never inject commands.
      const child = spawn(bin, args, { stdio: ['ignore', 'pipe', 'pipe'], env: { PATH: process.env.PATH ?? '/usr/bin:/bin' } });
      let stdout = '';
      let stderr = '';
      const timer = setTimeout(() => child.kill('SIGKILL'), timeoutSeconds * 1000);
      child.stdout.setEncoding('utf8').on('data', (d: string) => {
        if (onStdout) onStdout(d);
        else if (stdout.length < 8 * 1024 * 1024) stdout += d;
      });
      child.stderr.setEncoding('utf8').on('data', (d: string) => {
        stderr = (stderr + d).slice(-16_000);
      });
      child.on('error', (err) => {
        clearTimeout(timer);
        reject(new FfmpegError(`${bin} could not be started: ${err.message}`, ''));
      });
      child.on('close', (code, signal) => {
        clearTimeout(timer);
        if (code === 0) resolve({ stdout, stderr });
        else
          reject(
            new FfmpegError(
              signal === 'SIGKILL' ? `${bin} timed out after ${timeoutSeconds}s` : `${bin} exited with code ${code}`,
              stderr.split('\n').slice(-12).join('\n'),
            ),
          );
      });
    });
  }

  /**
   * `trusted` is only for files STREAMERO generated itself (e.g. rendered JPEGs), which need the
   * image2 demuxer; untrusted input is always probed with the strict whitelist.
   */
  async probe(file: string, opts: { trusted?: boolean } = {}): Promise<ProbeResult> {
    const inputArgs = opts.trusted ? ['-protocol_whitelist', 'file', '-format_whitelist', [...INPUT_FORMATS, 'image2'].join(',')] : SAFE_INPUT_ARGS;
    const { stdout } = await this.run(
      this.opts.ffprobePath,
      ['-v', 'error', ...inputArgs, '-print_format', 'json', '-show_format', '-show_streams', '--', file],
      undefined,
      120,
    );
    const parsed = JSON.parse(stdout) as ProbeResult;
    if (!parsed.format) throw new FfmpegError('ffprobe returned no format information', '');
    parsed.streams ??= [];
    return parsed;
  }

  /**
   * Runs ffmpeg with hardened input options. `inputs` are local file paths; `args` are output options.
   * Progress (0..1) is reported when `durationMs` is known.
   */
  async exec(inputs: Array<string | { path: string; pre?: string[] }>, args: string[], opts: { durationMs?: number; onProgress?: (fraction: number) => void } = {}) {
    const full = ['-hide_banner', '-nostdin', '-y', '-loglevel', 'error', '-threads', String(this.opts.threads)];
    for (const input of inputs) {
      const { path, pre = [] } = typeof input === 'string' ? { path: input } : input;
      full.push(...pre, ...SAFE_INPUT_ARGS, '-i', path);
    }
    if (opts.onProgress) full.push('-progress', 'pipe:1', '-nostats');
    full.push(...args);
    let buffer = '';
    await this.run(
      this.opts.ffmpegPath,
      full,
      opts.onProgress
        ? (chunk) => {
            buffer += chunk;
            const lines = buffer.split('\n');
            buffer = lines.pop() ?? '';
            for (const line of lines) {
              const m = line.match(/^out_time_(?:us|ms)=(\d+)/);
              if (m && opts.durationMs) opts.onProgress!(Math.min(1, Number(m[1]) / 1000 / opts.durationMs));
            }
          }
        : undefined,
    );
  }
}

export function durationMs(probe: ProbeResult): number {
  const d = Number(probe.format.duration ?? probe.streams.find((s) => s.duration)?.duration ?? 0);
  return Number.isFinite(d) ? Math.round(d * 1000) : 0;
}

/** Case-insensitive tag lookup across format and stream tags. */
export function tag(probe: ProbeResult, ...names: string[]): string | undefined {
  const sources = [probe.format.tags ?? {}, ...probe.streams.map((s) => s.tags ?? {})];
  for (const name of names) {
    for (const tags of sources) {
      for (const [k, v] of Object.entries(tags)) {
        if (k.toLowerCase() === name.toLowerCase() && typeof v === 'string' && v.trim()) return v.trim();
      }
    }
  }
  return undefined;
}
