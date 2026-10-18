# Backup and recovery

What to protect, in order of importance:
1. **PostgreSQL** — users, library, playlists, catalog metadata, provenance.
2. **Object storage `originals/`** — the irreplaceable uploaded masters.
3. Everything else in the bucket (renditions, HLS, artwork, subtitles) can be regenerated with Admin › Reprocess,
   but backing it up makes recovery much faster.

Redis holds only queue state, rate-limit counters and caches; it does not need backups (failed/queued jobs can be
retried from the admin; job rows live in PostgreSQL).

## Backup

```bash
./scripts/backup.sh /backups/streamero-$(date +%F)
```

Produces `streamero.pgdump` (pg_dump custom format), `media/` (S3 mirror) and `SHA256SUMS`. Schedule it daily
(cron/systemd timer) and copy the result off-site (restic, rclone, Borg). For managed Postgres prefer PITR.

## Restore

```bash
./scripts/restore.sh /backups/streamero-2026-10-18     # asks for confirmation; replaces DB and bucket contents
```

## Verification (done for this release)

`backup.sh` was run against the running Compose stack; the dump was restored into a scratch database
(`restore_check`) and table counts were compared (tracks, videos, media assets, migrations), and the media
mirror contained every stored object. Repeat this restore drill regularly — an untested backup is not a backup.

## Disaster scenarios

| Scenario | Recovery |
| --- | --- |
| Lost renditions/HLS only | Admin › Tracks/Videos › bulk Reprocess (regenerates from originals) |
| Lost database, storage intact | Restore the latest dump; media referenced by keys is still in the bucket |
| Lost bucket, DB intact | Restore `media/` from backup; reprocess anything newer than the backup |
| Leaked `MEDIA_SIGNING_SECRET` | Rotate it and restart the API: all media links become invalid immediately |
| Leaked `JWT_ACCESS_SECRET` | Rotate and restart; access tokens die, refresh tokens keep users signed in |
