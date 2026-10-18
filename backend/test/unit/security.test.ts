import { describe, expect, it } from 'vitest';
import { hostAllowed, isPrivateAddress, validateImportUrl } from '../../src/ingestion/importers.js';
import { redact } from '../../src/ingestion/job-runner.js';
import { assertSafeKey } from '../../src/storage/storage.driver.js';
import { LocalStorageDriver } from '../../src/storage/local.driver.js';
import { MediaSigner } from '../../src/streaming/media-signer.js';
import { parseRange } from '../../src/streaming/streaming.controller.js';
import { toPrefixQuery } from '../../src/search/search.service.js';
import { sniffImage } from '../../src/users/users.service.js';

describe('media URL signing', () => {
  const signer = new MediaSigner('x'.repeat(40));
  it('round-trips and rejects tampering or expiry', () => {
    const exp = Math.floor(Date.now() / 1000) + 60;
    const token = signer.sign({ k: 'renditions/a.m4a', e: exp });
    expect(signer.verify(token)?.k).toBe('renditions/a.m4a');
    const [body, sig] = token.split('.');
    const forged = Buffer.from(JSON.stringify({ k: 'originals/secret.flac', e: exp })).toString('base64url');
    expect(signer.verify(`${forged}.${sig}`)).toBeNull();
    expect(signer.verify(`${body}.${sig.slice(0, -2)}xx`)).toBeNull();
    expect(signer.verify(signer.sign({ k: 'a', e: 1 }))).toBeNull();
    expect(new MediaSigner('y'.repeat(40)).verify(token)).toBeNull();
  });
});

describe('storage keys', () => {
  it('rejects traversal and odd characters', () => {
    expect(assertSafeKey('hls/abc/720p/seg_00001.ts')).toBeTruthy();
    expect(assertSafeKey('hls/abc/')).toBeTruthy();
    for (const bad of ['../etc/passwd', 'a/../../b', '/abs', 'a//b', 'a\\b', 'a/./b', '', '.multipart/x']) {
      expect(() => assertSafeKey(bad)).toThrow();
    }
  });

  it('local driver confines paths to its root', () => {
    const d = new LocalStorageDriver('/tmp/root-x');
    expect(d.resolve('a/b.txt')).toBe('/tmp/root-x/a/b.txt');
    expect(() => d.resolve('../x')).toThrow();
  });
});

describe('HTTP ranges', () => {
  it('parses standard, open and suffix ranges', () => {
    expect(parseRange(undefined, 100)).toBeUndefined();
    expect(parseRange('bytes=0-9', 100)).toEqual({ start: 0, end: 9 });
    expect(parseRange('bytes=90-', 100)).toEqual({ start: 90, end: 99 });
    expect(parseRange('bytes=-10', 100)).toEqual({ start: 90, end: 99 });
    expect(parseRange('bytes=95-500', 100)).toEqual({ start: 95, end: 99 });
    expect(parseRange('bytes=100-', 100)).toBe('invalid');
    expect(parseRange('bytes=5-1', 100)).toBe('invalid');
    expect(parseRange('items=0-1', 100)).toBe('invalid');
  });
});

describe('URL importer policy', () => {
  const opts = { allowedHosts: ['media.example.com', '.cdn.example.org'], allowPrivateNetworks: false };
  it('allows only https on allowlisted hosts', () => {
    expect(validateImportUrl('https://media.example.com/a.flac', opts).hostname).toBe('media.example.com');
    expect(validateImportUrl('https://eu.cdn.example.org/a.mp3', opts).hostname).toBe('eu.cdn.example.org');
    expect(() => validateImportUrl('http://media.example.com/a.flac', opts)).toThrow(/https/);
    expect(() => validateImportUrl('https://evil.com/a.flac', opts)).toThrow(/not in IMPORT_ALLOWED_HOSTS/);
    expect(() => validateImportUrl('https://user:pw@media.example.com/a', opts)).toThrow(/credentials/);
    expect(() => validateImportUrl('ftp://media.example.com/a', opts)).toThrow();
  });

  it('refuses YouTube downloads even if allowlisted', () => {
    const yt = { allowedHosts: ['www.youtube.com', 'youtu.be'], allowPrivateNetworks: false };
    expect(() => validateImportUrl('https://www.youtube.com/watch?v=abc', yt)).toThrow(/YouTube media cannot be downloaded/);
    expect(() => validateImportUrl('https://youtu.be/abc', yt)).toThrow(/YouTube/);
    expect(() => validateImportUrl('https://rr1---sn.googlevideo.com/videoplayback', { ...yt, allowedHosts: ['.googlevideo.com'] })).toThrow(/YouTube/);
  });

  it('classifies private addresses', () => {
    for (const ip of ['127.0.0.1', '10.1.2.3', '172.16.0.1', '192.168.1.1', '169.254.169.254', '::1', 'fd00::1', '::ffff:10.0.0.1', '0.0.0.0', '100.64.0.1']) {
      expect(isPrivateAddress(ip)).toBe(true);
    }
    for (const ip of ['8.8.8.8', '1.1.1.1', '2606:4700::1111']) expect(isPrivateAddress(ip)).toBe(false);
    expect(hostAllowed('MEDIA.example.com.', ['media.example.com'])).toBe(true);
  });

  it('redacts query strings from logged URLs', () => {
    expect(redact('https://a.com/f.mp3?token=secret')).toBe('https://a.com/f.mp3?…');
  });
});

describe('input hardening', () => {
  it('builds injection-free prefix tsqueries', () => {
    expect(toPrefixQuery("Daft Pun'k & | !")).toBe('daft:* & pun:* & k:*');
    expect(toPrefixQuery('   ')).toBeNull();
    expect(toPrefixQuery('Šuma Čarobna')).toBe('šuma:* & čarobna:*');
  });

  it('sniffs image types from magic bytes', () => {
    expect(sniffImage(Buffer.from([0xff, 0xd8, 0xff, 0xe0]))?.mime).toBe('image/jpeg');
    expect(sniffImage(Buffer.from('<svg onload=alert(1)>'))).toBeNull();
  });
});
