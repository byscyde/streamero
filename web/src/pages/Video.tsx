import { useEffect, useRef, useState } from 'react';
import { Link, useParams } from 'react-router-dom';
import * as I from '../components/Icons';
import { Carousel, Empty, ErrorState, Section, Spinner, VideoCard } from '../components/ui';
import { api, ApiError, media } from '../lib/api';
import { compactNumber, uuid } from '../lib/format';
import { settings } from '../lib/settings';
import type { VideoStream } from '../lib/types';
import { controls } from '../player/player';
import { toggleSaved, useConfig, useLoad, useSaved } from '../state/app';
import { errorText } from '../state/store';

/** Plays the HLS stream: native HLS on Safari, hls.js (Media Source Extensions) elsewhere. */
function HlsPlayer({ stream, startAt, poster, onProgress, onEnded }: { stream: VideoStream; startAt: number; poster?: string; onProgress: (pos: number, dur: number, playing: boolean) => void; onEnded: () => void }) {
  const ref = useRef<HTMLVideoElement>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    const video = ref.current!;
    const src = media(stream.hlsUrl)!;
    let hls: { destroy(): void } | null = null;
    let cancelled = false;
    const seekStart = () => {
      if (startAt > 0 && startAt < (video.duration || Infinity) - 5) video.currentTime = startAt;
    };
    video.addEventListener('loadedmetadata', seekStart, { once: true });
    if (video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = src;
    } else {
      void import('hls.js').then(({ default: Hls }) => {
        if (cancelled) return;
        if (!Hls.isSupported()) {
          setError('Your browser cannot play this video (Media Source Extensions are unavailable).');
          return;
        }
        // Worker off: CSP has no blob: worker-src. Capped to the player size to save bandwidth.
        const h = new Hls({ enableWorker: false, capLevelToPlayerSize: true, startLevel: -1 });
        h.on(Hls.Events.ERROR, (_e, data) => {
          if (data.fatal) {
            if (data.type === Hls.ErrorTypes.NETWORK_ERROR) h.startLoad();
            else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) h.recoverMediaError();
            else setError('Playback failed.');
          }
        });
        h.loadSource(src);
        h.attachMedia(video);
        hls = h;
      });
    }
    return () => {
      cancelled = true;
      hls?.destroy();
      video.removeAttribute('src');
      video.load();
    };
  }, [stream.hlsUrl, startAt]);

  useEffect(() => {
    const v = ref.current!;
    const tick = () => onProgress(v.currentTime, v.duration || stream.durationMs / 1000, !v.paused);
    const play = () => controls.pause(); // one thing at a time: pause music when the video plays
    v.addEventListener('timeupdate', tick);
    v.addEventListener('pause', tick);
    v.addEventListener('play', play);
    v.addEventListener('ended', onEnded);
    return () => {
      v.removeEventListener('timeupdate', tick);
      v.removeEventListener('pause', tick);
      v.removeEventListener('play', play);
      v.removeEventListener('ended', onEnded);
    };
  }, [onProgress, onEnded, stream.durationMs]);

  return (
    <div className="video-frame">
      <video ref={ref} controls playsInline autoPlay poster={poster} crossOrigin={undefined}>
        {stream.subtitles.map((s) => (
          <track key={s.id} kind={s.kind === 'captions' ? 'captions' : 'subtitles'} src={media(s.vttUrl)} srcLang={s.language} label={s.label} default={s.isDefault} />
        ))}
      </video>
      {error && <div className="video-error">{error}</div>}
    </div>
  );
}

export default function VideoPage() {
  const { id = '' } = useParams();
  const cfg = useConfig();
  const page = useLoad(() => api.video(id), [id], 'catalog');
  const stream = useLoad(() => api.videoStream(id), [id], 'none');
  const liked = useSaved('video', id);
  const last = useRef({ pos: 0, dur: 0, saved: 0, watchedMs: 0, lastTick: 0, startedAt: Date.now() });

  // Save progress every 15 s while playing, on pause and when leaving; report a play event at the end.
  const onProgress = useRef((pos: number, dur: number, playing: boolean) => {
    const l = last.current;
    const now = Date.now();
    if (playing && l.lastTick) l.watchedMs += Math.min(2000, now - l.lastTick);
    l.lastTick = playing ? now : 0;
    l.pos = pos;
    l.dur = dur;
    if (!playing || now - l.saved > 15_000) {
      l.saved = now;
      if (pos > 1) api.saveVideoProgress(id, pos * 1000, dur * 1000).catch(() => undefined);
    }
  }).current;
  const onEnded = useRef(() => undefined).current;
  useEffect(
    () => () => {
      const l = last.current;
      if (l.pos > 1) api.saveVideoProgress(id, l.pos * 1000, l.dur * 1000).catch(() => undefined);
      if (l.watchedMs >= 1000)
        api
          .sendPlaybackEvents([
            { clientEventId: uuid(), videoId: id, playedAt: new Date(l.startedAt).toISOString(), durationPlayedMs: Math.round(l.watchedMs), completed: l.dur > 0 && l.pos >= l.dur * 0.95, deviceId: settings.deviceId },
          ])
          .catch(() => undefined);
    },
    [id],
  );

  if (!cfg.features.videos) return <Empty title="Videos are turned off" />;
  if (page.loading && !page.data) return <Spinner />;
  if (page.error && !page.data) return page.error instanceof ApiError && page.error.status === 404 ? <Empty title="Video not found" /> : <ErrorState error={page.error} onRetry={page.reload} />;
  const { video, related } = page.data!;
  const resume = video.progress && !video.progress.completed ? video.progress.positionMs / 1000 : 0;
  return (
    <div className="page video-page">
      {stream.data ? (
        <HlsPlayer stream={stream.data} startAt={resume} poster={media(video.thumbnailUrl ? `${video.thumbnailUrl}?size=large` : null)} onProgress={onProgress} onEnded={onEnded} />
      ) : stream.error ? (
        <div className="video-frame">
          <div className="video-error">{errorText(stream.error)}</div>
        </div>
      ) : (
        <div className="video-frame">
          <Spinner />
        </div>
      )}
      <div className="video-info">
        <div>
          <h1 className="title-font">{video.title}</h1>
          <p className="muted">
            {video.artist && <Link to={`/artist/${video.artist.id}`}>{video.artist.name}</Link>}
            {video.viewCount ? ` • ${compactNumber(video.viewCount)} views` : ''}
            {video.subtitles?.length ? (
              <span title="Subtitles available">
                {' '}
                • <I.IconSubtitles size={14} /> {video.subtitles.map((s) => s.label).join(', ')}
              </span>
            ) : null}
          </p>
        </div>
        <div className="row">
          <button className={`pill ${liked ? 'on' : ''}`} onClick={() => toggleSaved('video', id)}>
            {liked ? <I.IconHeartFilled size={16} /> : <I.IconHeart size={16} />} {liked ? 'Liked' : 'Like'}
          </button>
          {video.trackId && (
            <button
              className="pill"
              onClick={() =>
                api
                  .track(video.trackId!)
                  .then((t) => controls.playTracks([t], 0, { type: 'video', id }))
                  .catch(() => undefined)
              }
            >
              <I.IconMusic size={16} /> Listen to the song
            </button>
          )}
        </div>
      </div>
      {video.description && <p className="bio">{video.description}</p>}
      {related.length > 0 && (
        <Section title="More videos">
          <Carousel className="videos">
            {related.map((v) => (
              <VideoCard key={v.id} video={v} />
            ))}
          </Carousel>
        </Section>
      )}
    </div>
  );
}
