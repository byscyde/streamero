import { createHmac, timingSafeEqual } from 'node:crypto';

export interface MediaGrant {
  /** Storage key of a single object, or a key prefix ending in "/" granting access to everything below it. */
  k: string;
  /** Expiry, unix seconds. */
  e: number;
  /** Viewer id, for audit/analytics. */
  u?: string;
  /** Video id for HLS grants (enables subtitle playlist injection). */
  v?: string;
  /** Content type hint. */
  t?: string;
}

/**
 * Stateless, expiring media grants: base64url(JSON) + "." + base64url(HMAC-SHA256).
 * Tokens are embedded in the URL path so that relative URLs inside HLS playlists inherit them.
 */
export class MediaSigner {
  constructor(private readonly secret: string) {}

  sign(grant: MediaGrant): string {
    const body = Buffer.from(JSON.stringify(grant)).toString('base64url');
    return `${body}.${this.mac(body)}`;
  }

  verify(token: string, now = Date.now()): MediaGrant | null {
    const dot = token.indexOf('.');
    if (dot <= 0 || token.length > 2048) return null;
    const body = token.slice(0, dot);
    const sig = Buffer.from(token.slice(dot + 1));
    const expected = Buffer.from(this.mac(body));
    if (sig.length !== expected.length || !timingSafeEqual(sig, expected)) return null;
    try {
      const grant = JSON.parse(Buffer.from(body, 'base64url').toString('utf8')) as MediaGrant;
      if (typeof grant.k !== 'string' || typeof grant.e !== 'number' || grant.e * 1000 < now) return null;
      return grant;
    } catch {
      return null;
    }
  }

  private mac(body: string) {
    return createHmac('sha256', this.secret).update(`streamero-media:${body}`).digest('base64url');
  }
}
