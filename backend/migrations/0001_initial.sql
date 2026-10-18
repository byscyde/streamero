-- STREAMERO initial schema
CREATE EXTENSION IF NOT EXISTS citext;
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TYPE user_role AS ENUM ('user', 'editor', 'admin');
CREATE TYPE asset_kind AS ENUM ('original', 'audio_rendition', 'hls', 'artwork', 'thumbnail', 'preview', 'subtitle', 'avatar', 'audio_only');
CREATE TYPE media_status AS ENUM ('processing', 'ready', 'failed');
CREATE TYPE album_type AS ENUM ('album', 'single', 'ep', 'compilation');
CREATE TYPE stream_profile AS ENUM ('data_saver', 'standard', 'high', 'lossless');
CREATE TYPE playlist_visibility AS ENUM ('private', 'unlisted', 'public');
CREATE TYPE job_status AS ENUM ('queued', 'running', 'succeeded', 'failed', 'cancelled');
CREATE TYPE job_type AS ENUM ('ingest_audio', 'ingest_video', 'import_url', 'import_path', 'attach_subtitle', 'attach_artwork', 'reprocess');
CREATE TYPE email_token_purpose AS ENUM ('verify_email', 'reset_password');
CREATE TYPE subtitle_kind AS ENUM ('subtitles', 'captions', 'descriptions');
CREATE TYPE lyrics_kind AS ENUM ('synced', 'plain');

CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- ---------------------------------------------------------------- media assets
CREATE TABLE media_assets (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind            asset_kind NOT NULL,
  storage_key     text NOT NULL UNIQUE,          -- object key or key prefix (HLS); never exposed to clients
  mime_type       text NOT NULL,
  size_bytes      bigint NOT NULL DEFAULT 0 CHECK (size_bytes >= 0),
  checksum_sha256 text,
  container       text,
  codec           text,
  bitrate         integer,
  sample_rate     integer,
  bit_depth       integer,
  channels        integer,
  duration_ms     integer,
  width           integer,
  height          integer,
  is_lossless     boolean NOT NULL DEFAULT false,
  profile         text,
  metadata        jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX media_assets_checksum_idx ON media_assets (checksum_sha256) WHERE checksum_sha256 IS NOT NULL;
CREATE INDEX media_assets_kind_idx ON media_assets (kind);

-- ---------------------------------------------------------------- users & auth
CREATE TABLE users (
  id                       uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  email                    citext NOT NULL UNIQUE,
  password_hash            text,
  display_name             text NOT NULL,
  avatar_asset_id          uuid REFERENCES media_assets(id) ON DELETE SET NULL,
  role                     user_role NOT NULL DEFAULT 'user',
  email_verified_at        timestamptz,
  apple_sub                text UNIQUE,
  allow_explicit           boolean NOT NULL DEFAULT true,
  history_enabled          boolean NOT NULL DEFAULT true,
  personalization_enabled  boolean NOT NULL DEFAULT true,
  preferences              jsonb NOT NULL DEFAULT '{}'::jsonb,
  preferences_version      integer NOT NULL DEFAULT 0,
  disabled_at              timestamptz,
  created_at               timestamptz NOT NULL DEFAULT now(),
  updated_at               timestamptz NOT NULL DEFAULT now()
);
CREATE TRIGGER users_updated_at BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE refresh_tokens (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  family_id    uuid NOT NULL,
  token_hash   text NOT NULL UNIQUE,
  expires_at   timestamptz NOT NULL,
  revoked_at   timestamptz,
  replaced_by  uuid REFERENCES refresh_tokens(id) ON DELETE SET NULL,
  user_agent   text,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX refresh_tokens_user_idx ON refresh_tokens (user_id);
CREATE INDEX refresh_tokens_family_idx ON refresh_tokens (family_id);

CREATE TABLE email_tokens (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  purpose     email_token_purpose NOT NULL,
  token_hash  text NOT NULL UNIQUE,
  expires_at  timestamptz NOT NULL,
  used_at     timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX email_tokens_user_idx ON email_tokens (user_id, purpose);

-- ---------------------------------------------------------------- catalog
CREATE TABLE artists (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name              text NOT NULL CHECK (length(name) BETWEEN 1 AND 300),
  sort_name         text,
  bio               text,
  genres            text[] NOT NULL DEFAULT '{}',
  artwork_asset_id  uuid REFERENCES media_assets(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  search            tsvector GENERATED ALWAYS AS (to_tsvector('simple', coalesce(name, ''))) STORED
);
CREATE UNIQUE INDEX artists_name_unique ON artists (lower(name));
CREATE INDEX artists_search_idx ON artists USING gin (search);
CREATE INDEX artists_name_trgm ON artists USING gin (name gin_trgm_ops);
CREATE TRIGGER artists_updated_at BEFORE UPDATE ON artists FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE albums (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title             text NOT NULL CHECK (length(title) BETWEEN 1 AND 300),
  artist_id         uuid NOT NULL REFERENCES artists(id) ON DELETE RESTRICT,
  album_type        album_type NOT NULL DEFAULT 'album',
  release_date      date,
  genres            text[] NOT NULL DEFAULT '{}',
  label             text,
  explicit          boolean NOT NULL DEFAULT false,
  artwork_asset_id  uuid REFERENCES media_assets(id) ON DELETE SET NULL,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  search            tsvector GENERATED ALWAYS AS (to_tsvector('simple', coalesce(title, ''))) STORED
);
CREATE UNIQUE INDEX albums_artist_title_unique ON albums (artist_id, lower(title));
CREATE INDEX albums_artist_idx ON albums (artist_id, release_date DESC);
CREATE INDEX albums_search_idx ON albums USING gin (search);
CREATE INDEX albums_title_trgm ON albums USING gin (title gin_trgm_ops);
CREATE INDEX albums_created_idx ON albums (created_at DESC);
CREATE TRIGGER albums_updated_at BEFORE UPDATE ON albums FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE tracks (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title              text NOT NULL CHECK (length(title) BETWEEN 1 AND 500),
  artist_id          uuid NOT NULL REFERENCES artists(id) ON DELETE RESTRICT,
  album_id           uuid REFERENCES albums(id) ON DELETE SET NULL,
  disc_number        integer NOT NULL DEFAULT 1 CHECK (disc_number > 0),
  track_number       integer CHECK (track_number > 0),
  duration_ms        integer NOT NULL DEFAULT 0 CHECK (duration_ms >= 0),
  explicit           boolean NOT NULL DEFAULT false,
  genres             text[] NOT NULL DEFAULT '{}',
  moods              text[] NOT NULL DEFAULT '{}',
  isrc               text,
  original_asset_id  uuid REFERENCES media_assets(id) ON DELETE RESTRICT,
  status             media_status NOT NULL DEFAULT 'processing',
  downloadable       boolean NOT NULL DEFAULT true,
  play_count         bigint NOT NULL DEFAULT 0,
  created_at         timestamptz NOT NULL DEFAULT now(),
  updated_at         timestamptz NOT NULL DEFAULT now(),
  search             tsvector GENERATED ALWAYS AS (to_tsvector('simple', coalesce(title, ''))) STORED
);
CREATE INDEX tracks_album_idx ON tracks (album_id, disc_number, track_number);
CREATE INDEX tracks_artist_idx ON tracks (artist_id);
CREATE INDEX tracks_search_idx ON tracks USING gin (search);
CREATE INDEX tracks_title_trgm ON tracks USING gin (title gin_trgm_ops);
CREATE INDEX tracks_genres_idx ON tracks USING gin (genres);
CREATE INDEX tracks_moods_idx ON tracks USING gin (moods);
CREATE INDEX tracks_created_idx ON tracks (created_at DESC);
CREATE INDEX tracks_play_count_idx ON tracks (play_count DESC);
CREATE TRIGGER tracks_updated_at BEFORE UPDATE ON tracks FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE track_renditions (
  track_id  uuid NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
  profile   stream_profile NOT NULL,
  asset_id  uuid NOT NULL REFERENCES media_assets(id) ON DELETE RESTRICT,
  PRIMARY KEY (track_id, profile)
);
CREATE INDEX track_renditions_asset_idx ON track_renditions (asset_id);

CREATE TABLE lyrics (
  track_id      uuid PRIMARY KEY REFERENCES tracks(id) ON DELETE CASCADE,
  kind          lyrics_kind NOT NULL,
  content       text NOT NULL,
  language      text,
  source        text,
  license_note  text,
  updated_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE videos (
  id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title                text NOT NULL CHECK (length(title) BETWEEN 1 AND 500),
  description          text,
  artist_id            uuid REFERENCES artists(id) ON DELETE SET NULL,
  track_id             uuid REFERENCES tracks(id) ON DELETE SET NULL,
  duration_ms          integer NOT NULL DEFAULT 0,
  explicit             boolean NOT NULL DEFAULT false,
  genres               text[] NOT NULL DEFAULT '{}',
  original_asset_id    uuid REFERENCES media_assets(id) ON DELETE RESTRICT,
  hls_asset_id         uuid REFERENCES media_assets(id) ON DELETE SET NULL,
  thumbnail_asset_id   uuid REFERENCES media_assets(id) ON DELETE SET NULL,
  preview_asset_id     uuid REFERENCES media_assets(id) ON DELETE SET NULL,
  audio_asset_id       uuid REFERENCES media_assets(id) ON DELETE SET NULL,
  status               media_status NOT NULL DEFAULT 'processing',
  downloadable         boolean NOT NULL DEFAULT false,
  view_count           bigint NOT NULL DEFAULT 0,
  created_at           timestamptz NOT NULL DEFAULT now(),
  updated_at           timestamptz NOT NULL DEFAULT now(),
  search               tsvector GENERATED ALWAYS AS (to_tsvector('simple', coalesce(title, '') || ' ' || coalesce(description, ''))) STORED
);
CREATE INDEX videos_artist_idx ON videos (artist_id);
CREATE INDEX videos_track_idx ON videos (track_id);
CREATE INDEX videos_search_idx ON videos USING gin (search);
CREATE INDEX videos_title_trgm ON videos USING gin (title gin_trgm_ops);
CREATE INDEX videos_created_idx ON videos (created_at DESC);
CREATE TRIGGER videos_updated_at BEFORE UPDATE ON videos FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE video_renditions (
  video_id   uuid NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
  height     integer NOT NULL,
  width      integer NOT NULL,
  bandwidth  integer NOT NULL,
  playlist   text NOT NULL,        -- path of the variant playlist relative to the HLS root
  PRIMARY KEY (video_id, height)
);

CREATE TABLE subtitle_tracks (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  video_id            uuid NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
  language            text NOT NULL CHECK (language ~ '^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$'),
  label               text NOT NULL,
  kind                subtitle_kind NOT NULL DEFAULT 'subtitles',
  is_default          boolean NOT NULL DEFAULT false,
  forced              boolean NOT NULL DEFAULT false,
  asset_id            uuid NOT NULL REFERENCES media_assets(id) ON DELETE RESTRICT,   -- normalised WebVTT
  original_asset_id   uuid REFERENCES media_assets(id) ON DELETE RESTRICT,            -- uploaded SRT/VTT, preserved
  created_at          timestamptz NOT NULL DEFAULT now(),
  UNIQUE (video_id, language, kind)
);

-- ---------------------------------------------------------------- playlists
CREATE TABLE playlists (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id          uuid REFERENCES users(id) ON DELETE CASCADE,   -- NULL = editorial playlist
  title             text NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
  description       text,
  artwork_asset_id  uuid REFERENCES media_assets(id) ON DELETE SET NULL,
  visibility        playlist_visibility NOT NULL DEFAULT 'private',
  share_token       text NOT NULL UNIQUE DEFAULT encode(gen_random_bytes(12), 'hex'),
  is_collaborative  boolean NOT NULL DEFAULT false,
  is_editorial      boolean NOT NULL DEFAULT false,
  version           integer NOT NULL DEFAULT 1,
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now(),
  search            tsvector GENERATED ALWAYS AS (to_tsvector('simple', coalesce(title, '') || ' ' || coalesce(description, ''))) STORED
);
CREATE INDEX playlists_owner_idx ON playlists (owner_id, updated_at DESC);
CREATE INDEX playlists_search_idx ON playlists USING gin (search);
CREATE TRIGGER playlists_updated_at BEFORE UPDATE ON playlists FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TABLE playlist_items (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  playlist_id  uuid NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
  track_id     uuid REFERENCES tracks(id) ON DELETE CASCADE,
  video_id     uuid REFERENCES videos(id) ON DELETE CASCADE,
  position     integer NOT NULL CHECK (position >= 0),
  added_by     uuid REFERENCES users(id) ON DELETE SET NULL,
  added_at     timestamptz NOT NULL DEFAULT now(),
  CHECK ((track_id IS NOT NULL) <> (video_id IS NOT NULL)),
  UNIQUE (playlist_id, position) DEFERRABLE INITIALLY DEFERRED
);
CREATE INDEX playlist_items_track_idx ON playlist_items (track_id);
CREATE INDEX playlist_items_video_idx ON playlist_items (video_id);

CREATE TABLE playlist_collaborators (
  playlist_id  uuid NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  can_edit     boolean NOT NULL DEFAULT true,
  added_at     timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (playlist_id, user_id)
);

-- ---------------------------------------------------------------- library
CREATE TABLE liked_tracks (
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  track_id    uuid NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, track_id)
);
CREATE INDEX liked_tracks_recent_idx ON liked_tracks (user_id, created_at DESC);

CREATE TABLE saved_albums (
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  album_id    uuid NOT NULL REFERENCES albums(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, album_id)
);

CREATE TABLE followed_artists (
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  artist_id   uuid NOT NULL REFERENCES artists(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, artist_id)
);

CREATE TABLE liked_videos (
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  video_id    uuid NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, video_id)
);

CREATE TABLE saved_playlists (
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  playlist_id  uuid NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
  created_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, playlist_id)
);

-- Removal tombstones make offline library edits from several devices converge (last write wins).
CREATE TABLE library_removals (
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  item_type   text NOT NULL CHECK (item_type IN ('track', 'album', 'artist', 'video', 'playlist')),
  item_id     uuid NOT NULL,
  removed_at  timestamptz NOT NULL,
  PRIMARY KEY (user_id, item_type, item_id)
);
CREATE INDEX library_removals_recent_idx ON library_removals (user_id, removed_at);

-- ---------------------------------------------------------------- playback
CREATE TABLE playback_events (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id             uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  track_id            uuid REFERENCES tracks(id) ON DELETE CASCADE,
  video_id            uuid REFERENCES videos(id) ON DELETE CASCADE,
  client_event_id     text NOT NULL,
  played_at           timestamptz NOT NULL,
  duration_played_ms  integer NOT NULL DEFAULT 0 CHECK (duration_played_ms >= 0),
  completed           boolean NOT NULL DEFAULT false,
  context_type        text,
  context_id          uuid,
  device_id           text,
  created_at          timestamptz NOT NULL DEFAULT now(),
  CHECK ((track_id IS NOT NULL) <> (video_id IS NOT NULL)),
  UNIQUE (user_id, client_event_id)
);
CREATE INDEX playback_events_user_recent_idx ON playback_events (user_id, played_at DESC);
CREATE INDEX playback_events_track_idx ON playback_events (track_id, played_at DESC);
CREATE INDEX playback_events_played_at_idx ON playback_events (played_at DESC);

CREATE TABLE video_progress (
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  video_id     uuid NOT NULL REFERENCES videos(id) ON DELETE CASCADE,
  position_ms  integer NOT NULL CHECK (position_ms >= 0),
  duration_ms  integer NOT NULL DEFAULT 0,
  completed    boolean NOT NULL DEFAULT false,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, video_id)
);
CREATE INDEX video_progress_recent_idx ON video_progress (user_id, updated_at DESC);

CREATE TABLE track_progress (
  user_id      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  track_id     uuid NOT NULL REFERENCES tracks(id) ON DELETE CASCADE,
  position_ms  integer NOT NULL CHECK (position_ms >= 0),
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, track_id)
);

CREATE TABLE playback_state (
  user_id        uuid PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
  state          jsonb NOT NULL,
  version        integer NOT NULL DEFAULT 1,
  device_id      text,
  updated_at     timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE recent_searches (
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  query       text NOT NULL CHECK (length(query) BETWEEN 1 AND 200),
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, query)
);

CREATE TABLE download_grants (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  track_id    uuid REFERENCES tracks(id) ON DELETE CASCADE,
  video_id    uuid REFERENCES videos(id) ON DELETE CASCADE,
  profile     text NOT NULL,
  asset_id    uuid NOT NULL REFERENCES media_assets(id) ON DELETE CASCADE,
  expires_at  timestamptz NOT NULL,
  revoked_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now(),
  CHECK ((track_id IS NOT NULL) <> (video_id IS NOT NULL))
);
CREATE INDEX download_grants_user_idx ON download_grants (user_id, created_at DESC);

-- ---------------------------------------------------------------- ingestion
CREATE TABLE upload_sessions (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_by      uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  filename        text NOT NULL,
  mime_type       text NOT NULL,
  total_bytes     bigint NOT NULL CHECK (total_bytes > 0),
  chunk_bytes     integer NOT NULL CHECK (chunk_bytes > 0),
  received_chunks integer[] NOT NULL DEFAULT '{}',
  storage_key     text NOT NULL,
  storage_upload  text NOT NULL,                 -- multipart upload id in the storage backend
  parts           jsonb NOT NULL DEFAULT '{}'::jsonb,
  purpose         text NOT NULL,
  options         jsonb NOT NULL DEFAULT '{}'::jsonb,
  status          text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'completed', 'aborted', 'expired')),
  job_id          uuid,
  expires_at      timestamptz NOT NULL,
  created_at      timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ingestion_jobs (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  type          job_type NOT NULL,
  status        job_status NOT NULL DEFAULT 'queued',
  progress      integer NOT NULL DEFAULT 0 CHECK (progress BETWEEN 0 AND 100),
  attempts      integer NOT NULL DEFAULT 0,
  max_attempts  integer NOT NULL DEFAULT 3,
  input         jsonb NOT NULL,
  result        jsonb,
  error         text,
  logs          jsonb NOT NULL DEFAULT '[]'::jsonb,
  provenance    jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_by    uuid REFERENCES users(id) ON DELETE SET NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  started_at    timestamptz,
  finished_at   timestamptz
);
CREATE INDEX ingestion_jobs_status_idx ON ingestion_jobs (status, created_at DESC);

-- ---------------------------------------------------------------- home & audit
CREATE TABLE home_sections (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind        text NOT NULL,
  title       text NOT NULL,
  position    integer NOT NULL,
  enabled     boolean NOT NULL DEFAULT true,
  config      jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE audit_logs (
  id           bigserial PRIMARY KEY,
  actor_id     uuid REFERENCES users(id) ON DELETE SET NULL,
  action       text NOT NULL,
  target_type  text,
  target_id    text,
  metadata     jsonb NOT NULL DEFAULT '{}'::jsonb,
  ip           inet,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX audit_logs_created_idx ON audit_logs (created_at DESC);
CREATE INDEX audit_logs_actor_idx ON audit_logs (actor_id, created_at DESC);

CREATE TABLE idempotency_keys (
  user_id     uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  key         text NOT NULL,
  route       text NOT NULL,
  status      integer NOT NULL,
  response    jsonb NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, key)
);

INSERT INTO home_sections (kind, title, position) VALUES
  ('continue_listening', 'Continue listening', 0),
  ('recently_played', 'Recently played', 1),
  ('made_for_you', 'Made for you', 2),
  ('continue_watching', 'Continue watching', 3),
  ('favorite_artists', 'Your artists', 4),
  ('recently_added', 'New in STREAMERO', 5),
  ('trending', 'Trending now', 6),
  ('album_recommendations', 'Albums for you', 7),
  ('music_videos', 'Music videos', 8),
  ('featured_playlists', 'Featured playlists', 9),
  ('genres', 'Browse by genre', 10),
  ('moods', 'Moods', 11);
