import { readFileSync } from 'node:fs';
import { afterAll, beforeAll, describe, expect, it } from 'vitest';
import { auth, makeFixture, registerUser, startApp, uploadFile, type TestContext } from '../helpers.js';

let ctx: TestContext;
let alice: Awaited<ReturnType<typeof registerUser>>;
let bob: Awaited<ReturnType<typeof registerUser>>;
const tracks: string[] = [];
let albumId: string;
let artistId: string;

/** Inserts catalog rows directly (fast); one real ingested track is added for streaming/downloads. */
async function seedCatalog() {
  const a = await ctx.db.one(`INSERT INTO artists (name, genres) VALUES ('Midnight Echo', '{synthwave}') RETURNING id`);
  const b = await ctx.db.one(`INSERT INTO artists (name, genres) VALUES ('Coral Static', '{indie}') RETURNING id`);
  artistId = a.id;
  const al = await ctx.db.one(`INSERT INTO albums (title, artist_id, genres, release_date) VALUES ('Afterglow', $1, '{synthwave}', '2024-02-02') RETURNING id`, [a.id]);
  albumId = al.id;
  const specs = [
    ['Starlight Drive', a.id, al.id, '{synthwave}', '{night}', false],
    ['Chrome Hearts', a.id, al.id, '{synthwave}', '{energetic}', true],
    ['Velvet Rain', b.id, null, '{indie}', '{chill}', false],
    ['Paper Lanterns', b.id, null, '{indie}', '{chill}', false],
  ] as const;
  for (const [i, [title, artist, album, genres, moods, explicit]] of specs.entries()) {
    const t = await ctx.db.one(
      `INSERT INTO tracks (title, artist_id, album_id, track_number, duration_ms, genres, moods, explicit, status, play_count)
       VALUES ($1, $2, $3, $4, 200000, $5, $6, $7, 'ready', $8) RETURNING id`,
      [title, artist, album, i + 1, genres, moods, explicit, 10 - i],
    );
    tracks.push(t.id);
  }
}

beforeAll(async () => {
  ctx = await startApp();
  alice = await registerUser(ctx);
  bob = await registerUser(ctx);
  await seedCatalog();
});
afterAll(() => ctx.close());

describe('library', () => {
  it('likes, follows and saves, idempotently', async () => {
    await ctx.http.put(`/v1/me/liked/tracks/${tracks[0]}`).set(auth(alice.token)).expect(200);
    await ctx.http.put(`/v1/me/liked/tracks/${tracks[0]}`).set(auth(alice.token)).expect(200);
    await ctx.http.put(`/v1/me/liked/tracks/${tracks[2]}`).set(auth(alice.token)).expect(200);
    await ctx.http.put(`/v1/me/albums/${albumId}`).set(auth(alice.token)).expect(200);
    await ctx.http.put(`/v1/me/following/artists/${artistId}`).set(auth(alice.token)).expect(200);
    await ctx.http.put(`/v1/me/liked/tracks/00000000-0000-4000-8000-000000000000`).set(auth(alice.token)).expect(404);

    const liked = await ctx.http.get('/v1/me/liked/tracks').query({ sort: 'title' }).set(auth(alice.token)).expect(200);
    expect(liked.body.total).toBe(2);
    expect(liked.body.items.map((t: any) => t.title)).toEqual(['Starlight Drive', 'Velvet Rain']);
    expect(liked.body.items[0].isLiked).toBe(true);
    const filtered = await ctx.http.get('/v1/me/liked/tracks').query({ q: 'coral' }).set(auth(alice.token)).expect(200);
    expect(filtered.body.items.map((t: any) => t.title)).toEqual(['Velvet Rain']);

    const summary = await ctx.http.get('/v1/me/library').set(auth(alice.token)).expect(200);
    expect(summary.body).toMatchObject({ likedTracks: 2, albums: 1, artists: 1 });
    // Private to the user.
    const bobs = await ctx.http.get('/v1/me/library').set(auth(bob.token)).expect(200);
    expect(bobs.body.likedTracks).toBe(0);

    const artist = await ctx.http.get(`/v1/artists/${artistId}`).set(auth(alice.token)).expect(200);
    expect(artist.body.artist).toMatchObject({ isFollowed: true, followerCount: 1 });
    expect(artist.body.topTracks[0].title).toBe('Starlight Drive');
    expect(artist.body.releases.albums[0].title).toBe('Afterglow');
  });

  it('merges offline edits from several devices with last-write-wins', async () => {
    const t0 = Date.now();
    const at = (ms: number) => new Date(t0 - 60_000 + ms).toISOString();
    const res = await ctx.http
      .post('/v1/me/library/sync')
      .set(auth(alice.token))
      .send({
        changes: [
          { type: 'track', id: tracks[1], op: 'add', at: at(1000) },
          { type: 'track', id: tracks[1], op: 'remove', at: at(5000) },
          { type: 'track', id: tracks[3], op: 'remove', at: at(1000) },
          { type: 'track', id: tracks[3], op: 'add', at: at(2000) },
        ],
      })
      .expect(200);
    expect(res.body.results).toHaveLength(4);
    // A stale add from a device that was offline (older than the removal) must not resurrect the like.
    await ctx.http.post('/v1/me/library/sync').set(auth(alice.token)).send({ changes: [{ type: 'track', id: tracks[1], op: 'add', at: at(3000) }] }).expect(200);
    const ids = await ctx.http.get('/v1/me/library/ids').set(auth(alice.token)).expect(200);
    expect(ids.body.tracks).toContain(tracks[3]);
    expect(ids.body.tracks).not.toContain(tracks[1]);
    const changes = await ctx.http.get('/v1/me/library/changes').query({ since: new Date(t0 - 120_000).toISOString() }).set(auth(alice.token)).expect(200);
    expect(changes.body.removed.map((r: any) => r.id)).toContain(tracks[1]);
  });
});

describe('playlists', () => {
  let playlistId: string;
  it('creates, adds, reorders and removes with version checks', async () => {
    const created = await ctx.http.post('/v1/playlists').set(auth(alice.token)).send({ title: 'Road trip', visibility: 'private' }).expect(201);
    playlistId = created.body.playlist.id;
    expect(created.body.playlist).toMatchObject({ isOwner: true, canEdit: true, itemCount: 0, version: 1 });

    const added = await ctx.http.post(`/v1/playlists/${playlistId}/items`).set(auth(alice.token)).send({ trackIds: [tracks[0], tracks[1], tracks[2]], expectedVersion: 1 }).expect(201);
    expect(added.body.items.items.map((i: any) => i.track.id)).toEqual([tracks[0], tracks[1], tracks[2]]);
    const inserted = await ctx.http.post(`/v1/playlists/${playlistId}/items`).set(auth(alice.token)).send({ trackIds: [tracks[3]], position: 1 }).expect(201);
    expect(inserted.body.items.items.map((i: any) => i.track.id)).toEqual([tracks[0], tracks[3], tracks[1], tracks[2]]);
    const version = inserted.body.playlist.version;

    const stale = await ctx.http.post(`/v1/playlists/${playlistId}/items/move`).set(auth(alice.token)).send({ itemId: inserted.body.items.items[0].itemId, toIndex: 3, expectedVersion: 1 }).expect(409);
    expect(stale.body.error).toMatchObject({ code: 'version_conflict', details: { currentVersion: version } });

    const moved = await ctx.http.post(`/v1/playlists/${playlistId}/items/move`).set(auth(alice.token)).send({ itemId: inserted.body.items.items[0].itemId, toIndex: 3, expectedVersion: version }).expect(200);
    expect(moved.body.items.items.map((i: any) => i.track.id)).toEqual([tracks[3], tracks[1], tracks[2], tracks[0]]);
    expect(moved.body.items.items.map((i: any) => i.position)).toEqual([0, 1, 2, 3]);

    const ids = moved.body.items.items.map((i: any) => i.itemId);
    const reordered = await ctx.http.post(`/v1/playlists/${playlistId}/items/reorder`).set(auth(alice.token)).send({ itemIds: [...ids].reverse() }).expect(200);
    expect(reordered.body.items.items[0].track.id).toBe(tracks[0]);
    await ctx.http.post(`/v1/playlists/${playlistId}/items/reorder`).set(auth(alice.token)).send({ itemIds: ids.slice(1) }).expect(409);

    const removed = await ctx.http.post(`/v1/playlists/${playlistId}/items/remove`).set(auth(alice.token)).send({ itemIds: [ids[0]] }).expect(200);
    expect(removed.body.playlist.itemCount).toBe(3);
    expect(removed.body.items.items.map((i: any) => i.position)).toEqual([0, 1, 2]);
    expect(removed.body.playlist.mosaicUrls).toEqual([]);
  });

  it('enforces access control and share links', async () => {
    await ctx.http.get(`/v1/playlists/${playlistId}`).set(auth(bob.token)).expect(404);
    await ctx.http.post(`/v1/playlists/${playlistId}/items`).set(auth(bob.token)).send({ trackIds: [tracks[0]] }).expect(404);
    const pub = await ctx.http.patch(`/v1/playlists/${playlistId}`).set(auth(alice.token)).send({ visibility: 'unlisted' }).expect(200);
    const shareUrl = new URL(pub.body.playlist.shareUrl).pathname;
    const shared = await ctx.http.get(shareUrl).expect(200);
    expect(shared.body.playlist).toMatchObject({ title: 'Road trip', canEdit: false });
    const asBob = await ctx.http.get(`/v1/playlists/${playlistId}`).set(auth(bob.token)).expect(200);
    expect(asBob.body.playlist.canEdit).toBe(false);
    await ctx.http.post(`/v1/playlists/${playlistId}/items`).set(auth(bob.token)).send({ trackIds: [tracks[0]] }).expect(403);
    await ctx.http.delete(`/v1/playlists/${playlistId}`).set(auth(bob.token)).expect(403);

    // Collaboration.
    await ctx.http.patch(`/v1/playlists/${playlistId}`).set(auth(alice.token)).send({ isCollaborative: true }).expect(200);
    await ctx.http.post(`/v1/playlists/${playlistId}/collaborators`).set(auth(alice.token)).send({ email: bob.email }).expect(201);
    await ctx.http.post(`/v1/playlists/${playlistId}/items`).set(auth(bob.token)).send({ trackIds: [tracks[0]] }).expect(201);
    await ctx.http.patch(`/v1/playlists/${playlistId}`).set(auth(bob.token)).send({ title: 'Hijack' }).expect(403);

    await ctx.http.put(`/v1/me/saved/playlists/${playlistId}`).set(auth(bob.token)).expect(200);
    const bobLists = await ctx.http.get('/v1/me/playlists').set(auth(bob.token)).expect(200);
    expect(bobLists.body.items.map((p: any) => p.id)).toContain(playlistId);
  });
});

describe('playback', () => {
  it('records events idempotently and builds history', async () => {
    const events = [
      { clientEventId: 'evt-00000001', trackId: tracks[2], playedAt: new Date(Date.now() - 5000).toISOString(), durationPlayedMs: 45000, contextType: 'album', contextId: albumId },
      { clientEventId: 'evt-00000002', trackId: tracks[3], playedAt: new Date().toISOString(), durationPlayedMs: 5000 },
    ];
    const before = (await ctx.db.one('SELECT play_count FROM tracks WHERE id = $1', [tracks[2]])).play_count;
    const r1 = await ctx.http.post('/v1/me/playback/events').set(auth(alice.token)).send({ events }).expect(200);
    expect(r1.body).toEqual({ accepted: 2, duplicates: 0 });
    const r2 = await ctx.http.post('/v1/me/playback/events').set(auth(alice.token)).send({ events }).expect(200);
    expect(r2.body).toEqual({ accepted: 0, duplicates: 2 });
    const after = (await ctx.db.one('SELECT play_count FROM tracks WHERE id = $1', [tracks[2]])).play_count;
    expect(after).toBe(before + 1); // 5 s play did not count, retry did not double count

    const recent = await ctx.http.get('/v1/me/recently-played').set(auth(alice.token)).expect(200);
    expect(recent.body.items.map((t: any) => t.id)).toEqual([tracks[3], tracks[2]]);
    const contexts = await ctx.http.get('/v1/me/recently-played/contexts').set(auth(alice.token)).expect(200);
    expect(contexts.body.items[0]).toMatchObject({ type: 'album', id: albumId });
  });

  it('respects disabled listening history', async () => {
    await ctx.http.patch('/v1/me').set(auth(bob.token)).send({ historyEnabled: false }).expect(200);
    await ctx.http.post('/v1/me/playback/events').set(auth(bob.token)).send({ events: [{ clientEventId: 'bob-evt-0001', trackId: tracks[0], playedAt: new Date().toISOString(), durationPlayedMs: 60000 }] }).expect(200);
    const n = await ctx.db.one('SELECT count(*)::int AS n FROM playback_events WHERE user_id = $1', [bob.id]);
    expect(n.n).toBe(0);
  });

  it('syncs the playback queue with compare-and-swap', async () => {
    const s1 = await ctx.http.put('/v1/me/playback-state').set(auth(alice.token)).send({ state: { queue: tracks, index: 1, positionMs: 1234 }, baseVersion: 0, deviceId: 'iphone' }).expect(200);
    expect(s1.body.version).toBe(1);
    const conflict = await ctx.http.put('/v1/me/playback-state').set(auth(alice.token)).send({ state: { queue: [], index: 0 }, baseVersion: 0, deviceId: 'ipad' }).expect(409);
    expect(conflict.body.error.details.state.positionMs).toBe(1234);
    await ctx.http.put('/v1/me/playback-state').set(auth(alice.token)).send({ state: { queue: [], index: 0 }, baseVersion: 1, deviceId: 'ipad' }).expect(200);
    const got = await ctx.http.get('/v1/me/playback-state').set(auth(alice.token)).expect(200);
    expect(got.body).toMatchObject({ version: 2, deviceId: 'ipad' });
  });
});

describe('search, discovery and home', () => {
  it('searches with prefixes and typo tolerance', async () => {
    const r = await ctx.http.get('/v1/search').query({ q: 'starl' }).set(auth(alice.token)).expect(200);
    expect(r.body.results.tracks.items[0].title).toBe('Starlight Drive');
    const typo = await ctx.http.get('/v1/search').query({ q: 'Midnite Echo', types: 'artists' }).set(auth(alice.token)).expect(200);
    expect(typo.body.results.artists.items[0].name).toBe('Midnight Echo');
    const byArtist = await ctx.http.get('/v1/search').query({ q: 'coral', types: 'tracks' }).set(auth(alice.token)).expect(200);
    expect(byArtist.body.results.tracks.items.map((t: any) => t.title).sort()).toEqual(['Paper Lanterns', 'Velvet Rain']);
    const genre = await ctx.http.get('/v1/search').query({ q: 'synth', types: 'genres' }).set(auth(alice.token)).expect(200);
    expect(genre.body.results.genres.items[0]).toMatchObject({ name: 'synthwave', kind: 'genre' });
    const inj = await ctx.http.get('/v1/search').query({ q: "'); DROP TABLE tracks; --" }).set(auth(alice.token)).expect(200);
    expect(inj.body.query).toBeTruthy();
    const sugg = await ctx.http.get('/v1/search/suggestions').query({ q: 'vel' }).set(auth(alice.token)).expect(200);
    expect(sugg.body.items[0]).toMatchObject({ text: 'Velvet Rain', type: 'track' });
    await ctx.http.post('/v1/me/recent-searches').set(auth(alice.token)).send({ query: 'starl' }).expect(204);
    const recent = await ctx.http.get('/v1/me/recent-searches').set(auth(alice.token)).expect(200);
    expect(recent.body.items[0].query).toBe('starl');
  });

  it('builds explainable mixes and a backend-driven home feed', async () => {
    const mixes = await ctx.http.get('/v1/mixes').set(auth(alice.token)).expect(200);
    expect(mixes.body.items.length).toBeGreaterThan(0);
    const first = mixes.body.items[0];
    const mix = await ctx.http.get(`/v1/mixes/${encodeURIComponent(first.id)}`).set(auth(alice.token)).expect(200);
    expect(mix.body.items.length).toBeGreaterThan(0);
    expect(mix.body.items[0].reasons.length).toBeGreaterThan(0);

    // Explicit filter.
    await ctx.http.patch('/v1/me').set(auth(alice.token)).send({ allowExplicit: false }).expect(200);
    const clean = await ctx.http.get('/v1/mixes/genre:synthwave').set(auth(alice.token)).expect(200);
    expect(clean.body.items.every((i: any) => !i.track.explicit)).toBe(true);

    const home = await ctx.http.get('/v1/home').set(auth(alice.token)).expect(200);
    expect(home.body.greeting).toMatch(/^Good (morning|afternoon|evening|night), Test/);
    const kinds = home.body.sections.map((s: any) => s.kind);
    expect(kinds).toEqual(expect.arrayContaining(['recently_played', 'made_for_you', 'trending', 'genres', 'favorite_artists']));
    // Section order/visibility is configurable by editors.
    const admin = await registerUser(ctx, 'editor');
    const sections = (await ctx.http.get('/v1/admin/home-sections').set(auth(admin.token)).expect(200)).body;
    await ctx.http.put('/v1/admin/home-sections').set(auth(admin.token)).send({ sections: sections.map((s: any) => ({ ...s, enabled: s.kind === 'trending' })).map(({ position, ...s }: any) => s) }).expect(200);
    const home2 = await ctx.http.get('/v1/home').set(auth(alice.token)).expect(200);
    expect(home2.body.sections.map((s: any) => s.kind)).toEqual(['trending']);
  });

  it('shows an empty state for a new catalog-less user feed', async () => {
    const g = await ctx.http.get('/v1/genres').set(auth(bob.token)).expect(200);
    expect(g.body.genres.map((x: any) => x.name)).toEqual(expect.arrayContaining(['synthwave', 'indie']));
  });
});

describe('sync state', () => {
  it('changes the library version only for the affected user and the catalog version on catalog edits', async () => {
    const s1 = (await ctx.http.get('/v1/sync/state').set(auth(alice.token)).expect(200)).body;
    const b1 = (await ctx.http.get('/v1/sync/state').set(auth(bob.token)).expect(200)).body;
    expect(s1.catalogVersion).toBe(b1.catalogVersion);
    // Unchanged state gives the same versions.
    expect((await ctx.http.get('/v1/sync/state').set(auth(alice.token))).body.libraryVersion).toBe(s1.libraryVersion);
    await ctx.http.put(`/v1/me/albums/${albumId}`).set(auth(bob.token)).expect(200);
    await ctx.http.delete(`/v1/me/albums/${albumId}`).set(auth(alice.token)).expect(200);
    const s2 = (await ctx.http.get('/v1/sync/state').set(auth(alice.token))).body;
    const b2 = (await ctx.http.get('/v1/sync/state').set(auth(bob.token))).body;
    expect(s2.libraryVersion).not.toBe(s1.libraryVersion);
    expect(b2.libraryVersion).not.toBe(b1.libraryVersion);
    expect(s2.catalogVersion).toBe(s1.catalogVersion);
    await ctx.db.query(`INSERT INTO tracks (title, artist_id, duration_ms, status) VALUES ('Brand New', $1, 1000, 'ready')`, [artistId]);
    const s3 = (await ctx.http.get('/v1/sync/state').set(auth(alice.token))).body;
    expect(s3.catalogVersion).not.toBe(s2.catalogVersion);
  });
});

describe('offline downloads', () => {
  it('grants downloads only for eligible tracks and revokes on catalog changes', async () => {
    const admin = await registerUser(ctx, 'admin');
    const mp3 = makeFixture('dl.mp3', ['-f', 'lavfi', '-i', 'sine=frequency=300:duration=3', '-c:a', 'libmp3lame', '-b:a', '192k']);
    const up = await uploadFile(ctx, admin.token, readFileSync(mp3), 'Offline Song.mp3', 'media');
    await ctx.runner.run(up.job.id);
    const job = await ctx.db.one('SELECT result FROM ingestion_jobs WHERE id = $1', [up.job.id]);
    const trackId = job.result.trackId;

    const grant = await ctx.http.post('/v1/me/downloads').set(auth(alice.token)).send({ trackId, profile: 'high' }).expect(201);
    expect(grant.body).toMatchObject({ trackId, profile: 'high', lossless: false });
    expect(grant.body.checksumSha256 === null || typeof grant.body.checksumSha256 === 'string').toBe(true);
    const file = await ctx.http.get(new URL(grant.body.url).pathname).buffer(true).expect(200);
    expect(file.body.length).toBe(grant.body.sizeBytes);

    const v1 = await ctx.http.post('/v1/me/downloads/validate').set(auth(alice.token)).send({ grantIds: [grant.body.grantId] }).expect(200);
    expect(v1.body.valid[0].grantId).toBe(grant.body.grantId);
    // Bob cannot validate Alice's grant.
    const vb = await ctx.http.post('/v1/me/downloads/validate').set(auth(bob.token)).send({ grantIds: [grant.body.grantId] }).expect(200);
    expect(vb.body.revoked).toEqual([grant.body.grantId]);

    await ctx.http.patch(`/v1/admin/tracks/${trackId}`).set(auth(admin.token)).send({ downloadable: false }).expect(200);
    const v2 = await ctx.http.post('/v1/me/downloads/validate').set(auth(alice.token)).send({ grantIds: [grant.body.grantId] }).expect(200);
    expect(v2.body.revoked).toEqual([grant.body.grantId]);
    const denied = await ctx.http.post('/v1/me/downloads').set(auth(alice.token)).send({ trackId }).expect(403);
    expect(denied.body.error.code).toBe('not_downloadable');
  });
});
