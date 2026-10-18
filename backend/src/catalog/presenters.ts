/**
 * SQL projections + row mappers shared by every endpoint that returns catalog objects, so that a
 * track looks the same in search, playlists, albums and the home feed, and every list is fetched
 * with a single query (no per-row lookups).
 */
let baseUrl = 'http://localhost:8080';
export function setPublicBaseUrl(url: string) {
  baseUrl = url.replace(/\/$/, '');
}
export const artworkUrl = (assetId: string | null | undefined) => (assetId ? `${baseUrl}/v1/artwork/${assetId}` : null);

/** `$u` must be replaced with the positional parameter holding the viewer id (or NULL). */
export const trackSelect = (u: string) => `
  t.id, t.title, t.duration_ms, t.explicit, t.track_number, t.disc_number, t.genres, t.moods,
  t.downloadable, t.status, t.play_count, t.created_at,
  ar.id AS artist_id, ar.name AS artist_name,
  al.id AS album_id, al.title AS album_title, al.artwork_asset_id AS album_artwork,
  oa.codec AS src_codec, oa.is_lossless AS src_lossless, oa.sample_rate AS src_sample_rate,
  oa.bit_depth AS src_bit_depth, oa.bitrate AS src_bitrate, oa.container AS src_container,
  (SELECT coalesce(array_agg(tr.profile::text ORDER BY tr.profile), '{}') FROM track_renditions tr WHERE tr.track_id = t.id) AS profiles,
  EXISTS (SELECT 1 FROM lyrics ly WHERE ly.track_id = t.id) AS has_lyrics,
  (SELECT v.id FROM videos v WHERE v.track_id = t.id AND v.status = 'ready' ORDER BY v.created_at LIMIT 1) AS video_id,
  (${u}::uuid IS NOT NULL AND EXISTS (SELECT 1 FROM liked_tracks lt WHERE lt.track_id = t.id AND lt.user_id = ${u}::uuid)) AS is_liked`;

export const trackFrom = `
  tracks t
  JOIN artists ar ON ar.id = t.artist_id
  LEFT JOIN albums al ON al.id = t.album_id
  LEFT JOIN media_assets oa ON oa.id = t.original_asset_id`;

export function presentTrack(r: any) {
  return {
    id: r.id,
    title: r.title,
    durationMs: r.duration_ms,
    explicit: r.explicit,
    trackNumber: r.track_number,
    discNumber: r.disc_number,
    genres: r.genres,
    moods: r.moods,
    artist: { id: r.artist_id, name: r.artist_name },
    album: r.album_id ? { id: r.album_id, title: r.album_title, artworkUrl: artworkUrl(r.album_artwork) } : null,
    artworkUrl: artworkUrl(r.album_artwork),
    isLiked: !!r.is_liked,
    hasLyrics: !!r.has_lyrics,
    videoId: r.video_id ?? null,
    downloadable: r.downloadable,
    status: r.status,
    availableProfiles: r.profiles ?? [],
    sourceQuality: r.src_codec
      ? {
          codec: r.src_codec,
          container: r.src_container,
          lossless: r.src_lossless,
          sampleRate: r.src_sample_rate,
          bitDepth: r.src_bit_depth,
          bitrateKbps: r.src_bitrate ? Math.round(r.src_bitrate / 1000) : null,
        }
      : null,
  };
}
export type TrackDto = ReturnType<typeof presentTrack>;

export const albumSelect = `
  al.id, al.title, al.album_type, al.release_date, al.genres, al.label, al.explicit, al.artwork_asset_id, al.created_at,
  ar.id AS artist_id, ar.name AS artist_name,
  (SELECT count(*)::int FROM tracks t WHERE t.album_id = al.id AND t.status = 'ready') AS track_count,
  (SELECT coalesce(sum(t.duration_ms), 0)::bigint FROM tracks t WHERE t.album_id = al.id AND t.status = 'ready') AS duration_ms`;
export const albumFrom = `albums al JOIN artists ar ON ar.id = al.artist_id`;

export function presentAlbum(r: any) {
  return {
    id: r.id,
    title: r.title,
    albumType: r.album_type,
    releaseDate: r.release_date,
    genres: r.genres,
    label: r.label,
    explicit: r.explicit,
    artworkUrl: artworkUrl(r.artwork_asset_id),
    artist: { id: r.artist_id, name: r.artist_name },
    trackCount: r.track_count ?? 0,
    durationMs: Number(r.duration_ms ?? 0),
    ...(r.is_saved !== undefined ? { isSaved: !!r.is_saved } : {}),
  };
}

export const artistSelect = `
  ar.id, ar.name, ar.bio, ar.genres, ar.artwork_asset_id,
  coalesce(ar.artwork_asset_id, (SELECT al.artwork_asset_id FROM albums al WHERE al.artist_id = ar.id AND al.artwork_asset_id IS NOT NULL ORDER BY al.release_date DESC NULLS LAST LIMIT 1)) AS display_artwork`;

export function presentArtist(r: any) {
  return {
    id: r.id,
    name: r.name,
    bio: r.bio ?? null,
    genres: r.genres ?? [],
    artworkUrl: artworkUrl(r.display_artwork ?? r.artwork_asset_id),
    ...(r.follower_count !== undefined ? { followerCount: Number(r.follower_count) } : {}),
    ...(r.is_followed !== undefined ? { isFollowed: !!r.is_followed } : {}),
  };
}

export const videoSelect = (u: string) => `
  v.id, v.title, v.description, v.duration_ms, v.explicit, v.genres, v.status, v.downloadable, v.view_count, v.created_at,
  v.thumbnail_asset_id, v.track_id, (v.audio_asset_id IS NOT NULL) AS has_audio_only, (v.preview_asset_id IS NOT NULL) AS has_preview,
  ar.id AS artist_id, ar.name AS artist_name,
  (SELECT coalesce(json_agg(json_build_object('id', s.id, 'language', s.language, 'label', s.label, 'kind', s.kind,
      'isDefault', s.is_default, 'forced', s.forced) ORDER BY s.is_default DESC, s.label), '[]'::json)
     FROM subtitle_tracks s WHERE s.video_id = v.id) AS subtitles,
  (SELECT coalesce(array_agg(vr.height ORDER BY vr.height DESC), '{}') FROM video_renditions vr WHERE vr.video_id = v.id) AS qualities,
  (${u}::uuid IS NOT NULL AND EXISTS (SELECT 1 FROM liked_videos lv WHERE lv.video_id = v.id AND lv.user_id = ${u}::uuid)) AS is_liked,
  (SELECT json_build_object('positionMs', vp.position_ms, 'completed', vp.completed, 'updatedAt', vp.updated_at)
     FROM video_progress vp WHERE vp.video_id = v.id AND vp.user_id = ${u}::uuid) AS progress`;
export const videoFrom = `videos v LEFT JOIN artists ar ON ar.id = v.artist_id`;

export function presentVideo(r: any) {
  return {
    id: r.id,
    title: r.title,
    description: r.description ?? null,
    durationMs: r.duration_ms,
    explicit: r.explicit,
    genres: r.genres,
    status: r.status,
    thumbnailUrl: artworkUrl(r.thumbnail_asset_id),
    artist: r.artist_id ? { id: r.artist_id, name: r.artist_name } : null,
    trackId: r.track_id ?? null,
    hasAudioOnly: !!r.has_audio_only,
    hasTimelinePreview: !!r.has_preview,
    subtitles: r.subtitles ?? [],
    qualities: r.qualities ?? [],
    downloadable: r.downloadable,
    isLiked: !!r.is_liked,
    progress: r.progress ?? null,
    viewCount: Number(r.view_count ?? 0),
  };
}

export const playlistSelect = (u: string) => `
  p.id, p.title, p.description, p.visibility, p.is_collaborative, p.is_editorial, p.version, p.share_token,
  p.created_at, p.updated_at, p.owner_id, p.artwork_asset_id, ow.display_name AS owner_name,
  (SELECT count(*)::int FROM playlist_items pi WHERE pi.playlist_id = p.id) AS item_count,
  (SELECT coalesce(sum(coalesce(t.duration_ms, v.duration_ms)), 0)::bigint FROM playlist_items pi
     LEFT JOIN tracks t ON t.id = pi.track_id LEFT JOIN videos v ON v.id = pi.video_id WHERE pi.playlist_id = p.id) AS duration_ms,
  (SELECT coalesce(array_agg(x.art ORDER BY x.pos), '{}') FROM (
     SELECT al.artwork_asset_id AS art, min(pi.position) AS pos
     FROM playlist_items pi JOIN tracks t ON t.id = pi.track_id JOIN albums al ON al.id = t.album_id
     WHERE pi.playlist_id = p.id AND al.artwork_asset_id IS NOT NULL
     GROUP BY al.artwork_asset_id ORDER BY pos LIMIT 4) x) AS mosaic,
  (${u}::uuid IS NOT NULL AND (p.owner_id = ${u}::uuid OR EXISTS (SELECT 1 FROM playlist_collaborators pc
     WHERE pc.playlist_id = p.id AND pc.user_id = ${u}::uuid AND pc.can_edit))) AS can_edit,
  (${u}::uuid IS NOT NULL AND EXISTS (SELECT 1 FROM saved_playlists sp WHERE sp.playlist_id = p.id AND sp.user_id = ${u}::uuid)) AS is_saved`;
export const playlistFrom = `playlists p LEFT JOIN users ow ON ow.id = p.owner_id`;

export function presentPlaylist(r: any, viewerId?: string | null) {
  const mosaic: string[] = r.mosaic ?? [];
  return {
    id: r.id,
    title: r.title,
    description: r.description ?? null,
    visibility: r.visibility,
    isCollaborative: r.is_collaborative,
    isEditorial: r.is_editorial,
    owner: r.owner_id ? { id: r.owner_id, displayName: r.owner_name } : null,
    artworkUrl: artworkUrl(r.artwork_asset_id ?? mosaic[0]),
    mosaicUrls: mosaic.map((m) => artworkUrl(m)!),
    itemCount: r.item_count ?? 0,
    durationMs: Number(r.duration_ms ?? 0),
    version: r.version,
    isOwner: !!viewerId && r.owner_id === viewerId,
    canEdit: !!r.can_edit,
    isSaved: !!r.is_saved,
    shareUrl: r.visibility === 'private' ? null : `${baseUrl}/v1/share/playlists/${r.share_token}`,
    updatedAt: r.updated_at,
  };
}
