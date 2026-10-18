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
    this.transport = config.SMTP_URL ? nodemailer.createTransport(config.SMTP_URL) : null;
    if (!this.transport && config.NODE_ENV === 'production') {
      this.logger.warn('SMTP_URL is not configured: verification and password-reset emails cannot be delivered');
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
