import { Inject, Injectable, Logger } from '@nestjs/common';
import nodemailer, { type Transporter } from 'nodemailer';
import { APP_CONFIG, type AppConfig } from '../config/config.js';

export interface OutgoingMail {
  to: string;
  subject: string;
  text: string;
}

@Injectable()
export class MailService {
  private readonly logger = new Logger(MailService.name);
  private readonly transport: Transporter | null;
  /** In test mode messages are captured here instead of being sent. */
  readonly outbox: OutgoingMail[] = [];

  constructor(@Inject(APP_CONFIG) private readonly config: AppConfig) {
    this.transport = config.SMTP_URL ? this.createTransport(config.SMTP_URL) : null;
    if (!this.transport && !config.SMTP_URL && config.NODE_ENV === 'production') {
      this.logger.warn('SMTP_URL is not configured: verification and password-reset emails cannot be delivered');
    }
  }

  /** A malformed SMTP_URL disables email instead of taking the whole API down. */
  private createTransport(url: string): Transporter | null {
    if (!isSmtpUrl(url)) {
      this.logger.error(
        'SMTP_URL is invalid, email is disabled. Expected e.g. smtps://user%40example.com:password@mail.example.com:465 ' +
          '(or smtp://…:587); got a value without the smtp:// / smtps:// scheme.',
      );
      return null;
    }
    try {
      return nodemailer.createTransport(url);
    } catch (err) {
      this.logger.error(`SMTP_URL could not be used, email is disabled: ${(err as Error).message}`);
      return null;
    }
  }

  async send(mail: OutgoingMail) {
    if (this.config.NODE_ENV === 'test') {
      this.outbox.push(mail);
      return;
    }
    if (!this.transport) {
      if (this.config.NODE_ENV === 'development') {
        // Development convenience only; production never logs mail bodies (they contain one-time tokens).
        this.logger.log({ to: mail.to, subject: mail.subject, body: mail.text }, 'Email (SMTP not configured)');
      }
      return;
    }
    await this.transport.sendMail({ from: this.config.MAIL_FROM, to: mail.to, subject: mail.subject, text: mail.text });
  }
}

/** True for smtp:// and smtps:// URLs with a host; never logs the value (it contains the password). */
export function isSmtpUrl(value: string): boolean {
  try {
    const u = new URL(value);
    return (u.protocol === 'smtp:' || u.protocol === 'smtps:') && u.hostname.length > 0;
  } catch {
    return false;
  }
}
