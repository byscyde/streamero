import { Injectable } from '@nestjs/common';
import { AuditService } from '../audit/audit.service.js';
import { badRequest } from '../common/errors.js';
import { DbService } from '../db/db.service.js';
import { appearancePatchSchema, DEFAULT_APPEARANCE, mergeAppearance, type AppearanceResponse } from './appconfig.schema.js';

export const APPEARANCE_KEY = 'appearance';

const isPlainObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

/** Section-wise merge of a validated patch into the stored (sparse) document. */
function mergeStored(stored: Record<string, unknown>, patch: Record<string, unknown>) {
  const out: Record<string, unknown> = { ...stored };
  for (const [section, value] of Object.entries(patch)) {
    if (value === undefined) continue;
    out[section] = { ...(isPlainObject(stored[section]) ? stored[section] : {}), ...(value as object) };
  }
  return out;
}

/** Remote app configuration (docs/APP_CONFIG.md §1): stored sparse, always served merged over defaults. */
@Injectable()
export class AppConfigService {
  constructor(
    private readonly db: DbService,
    private readonly audit: AuditService,
  ) {}

  private async stored(): Promise<Record<string, unknown>> {
    const row = await this.db.one<{ value: unknown }>('SELECT value FROM app_settings WHERE key = $1', [APPEARANCE_KEY]);
    return isPlainObject(row?.value) ? row.value : {};
  }

  async get(): Promise<AppearanceResponse> {
    return mergeAppearance(await this.stored());
  }

  async version(): Promise<string> {
    return (await this.get()).version;
  }

  async getWithDefaults() {
    return { ...(await this.get()), defaults: DEFAULT_APPEARANCE };
  }

  /** Accepts a full or partial document. `version` and `defaults` (echoed back from GET) are ignored. */
  async update(actorId: string, body: unknown, ip?: string): Promise<AppearanceResponse> {
    if (!isPlainObject(body)) throw badRequest('validation_failed', 'Body must be a JSON object');
    const { version: _v, defaults: _d, ...rest } = body;
    const parsed = appearancePatchSchema.safeParse(rest);
    if (!parsed.success) {
      throw badRequest(
        'validation_failed',
        'Appearance validation failed',
        parsed.error.issues.map((i) => ({ path: i.path.join('.'), message: i.message })),
      );
    }
    const patch = parsed.data as Record<string, unknown>;
    const before = await this.get();
    const next = await this.db.tx(async (client) => {
      const cur = await this.db.one<{ value: unknown }>('SELECT value FROM app_settings WHERE key = $1 FOR UPDATE', [APPEARANCE_KEY], client);
      const value = mergeStored(isPlainObject(cur?.value) ? cur.value : {}, patch);
      await this.db.query(
        `INSERT INTO app_settings (key, value, updated_at, updated_by) VALUES ($1, $2, now(), $3)
         ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, updated_at = now(), updated_by = EXCLUDED.updated_by`,
        [APPEARANCE_KEY, JSON.stringify(value), actorId],
        client,
      );
      const merged = mergeAppearance(value);
      const fields = Object.entries(patch).flatMap(([s, v]) => Object.keys(v as object).map((f) => `${s}.${f}`));
      await this.audit.record(
        { actorId, action: 'appearance.update', targetType: 'app_settings', targetId: APPEARANCE_KEY, metadata: { fields, from: before.version, to: merged.version }, ip },
        client,
      );
      return merged;
    });
    return next;
  }

  async reset(actorId: string, ip?: string): Promise<AppearanceResponse> {
    const before = await this.get();
    await this.db.query('DELETE FROM app_settings WHERE key = $1', [APPEARANCE_KEY]);
    const after = await this.get();
    await this.audit.record({ actorId, action: 'appearance.reset', targetType: 'app_settings', targetId: APPEARANCE_KEY, metadata: { from: before.version, to: after.version }, ip });
    return after;
  }
}
