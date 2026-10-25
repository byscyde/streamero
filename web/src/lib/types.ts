// API models. Mirrors the iOS client (StreameroCore/Models.swift); unknown fields are ignored.

export interface Page<T> {
  items: T[];
  limit: number;
  offset: number;
  total?: number;
  nextOffset: number | null;
}

export interface ArtistRef {
  id: string;
  name: string;
}

export interface AlbumRef {
  id: string;
  title: string;
  artworkUrl?: string | null;
}

export interface SourceQuality {
  codec?: string | null;
  container?: string | null;
  lossless: boolean;
  sampleRate?: number | null;
  bitDepth?: number | null;
  bitrateKbps?: number | null;
}

export interface Track {
  id: string;
  title: string;
  durationMs: number;
  explicit: boolean;
  trackNumber?: number | null;
  discNumber?: number | null;
  genres: string[];
  moods: string[];
  artist: ArtistRef;
  album?: AlbumRef | null;
  artworkUrl?: string | null;
  isLiked: boolean;
  hasLyrics: boolean;
  videoId?: string | null;
  downloadable?: boolean;
  availableProfiles?: string[];
  sourceQuality?: SourceQuality | null;
  addedAt?: string | null;
  lastPlayedAt?: string | null;
  resumePositionMs?: number | null;
  playCount?: number | null;
}

export interface Album {
  id: string;
  title: string;
  albumType: string;
  releaseDate?: string | null;
  genres: string[];
  label?: string | null;
  explicit: boolean;
  artworkUrl?: string | null;
  artist: ArtistRef;
  trackCount: number;
  durationMs: number;
  isSaved?: boolean | null;
}

export interface Artist {
  id: string;
  name: string;
  bio?: string | null;
  genres: string[];
  artworkUrl?: string | null;
  followerCount?: number | null;
  isFollowed?: boolean | null;
}

export interface SubtitleInfo {
  id: string;
  language: string;
  label: string;
  kind: string;
  isDefault: boolean;
  forced: boolean;
}

export interface Video {
  id: string;
  title: string;
  description?: string | null;
  durationMs: number;
  explicit: boolean;
  genres: string[];
  thumbnailUrl?: string | null;
  artist?: ArtistRef | null;
  trackId?: string | null;
  hasAudioOnly?: boolean;
  subtitles?: SubtitleInfo[];
  qualities?: number[];
  isLiked: boolean;
  progress?: { positionMs: number; completed: boolean } | null;
  viewCount?: number;
}

export interface Playlist {
  id: string;
  title: string;
  description?: string | null;
  visibility: string;
  isCollaborative: boolean;
  isEditorial: boolean;
  owner?: { id: string; displayName: string } | null;
  artworkUrl?: string | null;
  mosaicUrls?: string[];
  itemCount: number;
  durationMs: number;
  version: number;
  isOwner: boolean;
  canEdit: boolean;
  isSaved: boolean;
  shareUrl?: string | null;
}

export interface PlaylistItem {
  itemId: string;
  position: number;
  track?: Track | null;
  video?: Video | null;
}

export interface PlaylistPage {
  playlist: Playlist;
  items: Page<PlaylistItem>;
}

export interface ArtistPage {
  artist: Artist;
  topTracks: Track[];
  releases: { albums: Album[]; singles: Album[]; compilations: Album[] };
  videos: Video[];
  related: Artist[];
}

export interface AlbumPage {
  album: Album;
  tracks: Track[];
  moreByArtist: Album[];
  related: Album[];
}

export interface VideoPage {
  video: Video;
  related: Video[];
}

export interface LyricsResponse {
  trackId: string;
  synced: boolean;
  language?: string | null;
  lines: { startMs: number; text: string; words?: { startMs: number; text: string }[] | null }[];
  attribution?: { source?: string | null; license?: string | null };
}

export interface GenreInfo {
  name: string;
  trackCount: number;
  kind?: string | null;
  artworkUrl?: string | null;
}

export interface Mix {
  id: string;
  kind: string;
  title: string;
  description: string;
  artworkUrls?: string[] | null;
}

export interface MixDetail {
  mix: Mix;
  items: { track: Track; score: number; reasons: string[] }[];
}

export type HomeItem =
  | ({ type: 'track' } & Track)
  | ({ type: 'album' } & Album)
  | ({ type: 'artist' } & Artist)
  | ({ type: 'playlist' } & Playlist)
  | ({ type: 'video' } & Video)
  | ({ type: 'mix' } & Mix)
  | ({ type: 'genre' } & GenreInfo)
  | ({ type: 'mood' } & GenreInfo);

export interface HomeSection {
  id: string;
  kind: string;
  title: string;
  subtitle?: string | null;
  layout: 'carousel' | 'grid' | 'list' | 'hero' | 'chips' | string;
  items: HomeItem[];
}

export interface HomeFeed {
  greeting: string;
  isCatalogEmpty: boolean;
  sections: HomeSection[];
}

export interface SearchResults {
  tracks?: Page<Track>;
  artists?: Page<Artist>;
  albums?: Page<Album>;
  playlists?: Page<Playlist>;
  videos?: Page<Video>;
  genres?: { items: GenreInfo[] };
}

export interface SearchResponse {
  query: string;
  results: SearchResults;
}

export interface TrackStream {
  trackId: string;
  requestedProfile: string;
  profile: string;
  url: string;
  expiresAt: string;
  mimeType: string;
  durationMs: number;
  delivery: { codec?: string | null; bitrateKbps?: number | null; sampleRate?: number | null; bitDepth?: number | null; lossless: boolean };
  availableProfiles?: string[];
}

export interface VideoStream {
  videoId: string;
  durationMs: number;
  hlsUrl: string;
  expiresAt: string;
  qualities: { height: number; width: number; bandwidth: number; url: string }[];
  subtitles: (SubtitleInfo & { vttUrl: string })[];
}

export interface User {
  id: string;
  email: string;
  displayName: string;
  role: string;
  emailVerified: boolean;
  avatarUrl?: string | null;
  allowExplicit?: boolean;
  historyEnabled?: boolean;
  personalizationEnabled?: boolean;
  hasPassword?: boolean;
  preferences?: Record<string, unknown> | null;
  preferencesVersion?: number;
}

export interface Session {
  accessToken: string;
  refreshToken: string;
  expiresIn: number;
  tokenType: string;
  user: User;
}

export interface DeviceSession {
  id: string;
  device?: string | null;
  lastActiveAt: string;
  expiresAt: string;
}

export interface HistoryEntry {
  id: string;
  playedAt: string;
  durationPlayedMs: number;
  completed: boolean;
  track: Track;
}

export interface LibraryIds {
  tracks: string[];
  albums: string[];
  artists: string[];
  videos: string[];
  playlists: string[];
}

export interface SyncState {
  catalogVersion: string;
  libraryVersion: string;
  configVersion?: string;
  serverTime: string;
}

export interface PlaybackEvent {
  clientEventId: string;
  trackId?: string;
  videoId?: string;
  playedAt: string;
  durationPlayedMs: number;
  completed: boolean;
  contextType?: string;
  contextId?: string;
  deviceId?: string;
}

export interface YouTubeResult {
  videoId: string;
  title: string;
  channelTitle?: string | null;
  thumbnailUrl?: string | null;
  embedUrl: string;
  watchUrl: string;
}

export type LibraryItemType = 'track' | 'album' | 'artist' | 'video' | 'playlist';
export type StreamProfile = 'data_saver' | 'standard' | 'high' | 'lossless';
