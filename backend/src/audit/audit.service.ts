import { Injectable, Logger } from '@nestjs/common';
import { DbService, type Queryable } from '../db/db.service.js';

export interface AuditEntry {
  actorId?: string | null;
  action: string;
  targetType?: string;
  targetId?: string;
  metadata?: Record<string, unknown>;
  ip?: string | null;
}

@Injectable()
export class AuditService {
  private readonly logger = new Logger(AuditService.name);
  constructor(private readonly db: DbService) {}

  async record(entry: AuditEntry, client?: Queryable) {
    try {
      await this.db.query(
        `INSERT INTO audit_logs (actor_id, action, target_type, target_id, metadata, ip)
         VALUES ($1, $2, $3, $4, $5, $6::inet)`,
        [
          entry.actorId ?? null,
          entry.action,
          entry.targetType ?? null,
          entry.targetId ?? null,
          JSON.stringify(entry.metadata ?? {}),
          normaliseIp(entry.ip),
        ],
        client,
      );
    } catch (err) {
      // Audit failures must not break the user-facing operation, but they must be visible.
      this.logger.error({ err, action: entry.action }, 'Failed to write audit log');
      if (client) throw err;
    }
  }
}

function normaliseIp(ip?: string | null): string | null {
  if (!ip) return null;
  const v = ip.startsWith('::ffff:') ? ip.slice(7) : ip;
  return /^[0-9a-f:.]+$/i.test(v) ? v : null;
}
