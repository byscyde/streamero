import { describe, expect, it } from 'vitest';
import { loadConfig } from '../../src/config/config.js';
import { isSmtpUrl, MailService } from '../../src/mail/mail.service.js';

describe('SMTP_URL handling', () => {
  it('accepts only smtp:// and smtps:// URLs with a host', () => {
    expect(isSmtpUrl('smtps://no-reply%40scyde.dev:secret@mail.scyde.dev:465')).toBe(true);
    expect(isSmtpUrl('smtp://user:pw@mail.example.com:587')).toBe(true);
    expect(isSmtpUrl('mail.scyde.dev')).toBe(false);
    expect(isSmtpUrl('https://mail.scyde.dev')).toBe(false);
    expect(isSmtpUrl('')).toBe(false);
  });

  it('disables email instead of crashing when SMTP_URL is a bare host name', () => {
    const config = loadConfig({ ...process.env, NODE_ENV: 'development', SMTP_URL: 'mail.scyde.dev' });
    expect(() => new MailService(config)).not.toThrow();
  });
});
