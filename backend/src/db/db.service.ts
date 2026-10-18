import { Inject, Injectable, Logger, OnModuleDestroy } from '@nestjs/common';
import pg from 'pg';
import { APP_CONFIG, type AppConfig } from '../config/config.js';

// Return BIGINT (int8) values as JS numbers; counters in this schema stay far below 2^53.
pg.types.setTypeParser(20, (v) => Number(v));
// Keep DATE columns as ISO strings instead of local-time Date objects.
pg.types.setTypeParser(1082, (v) => v);

export type Queryable = Pick<pg.PoolClient, 'query'>;

@Injectable()
export class DbService implements OnModuleDestroy {
  private readonly logger = new Logger(DbService.name);
  readonly pool: pg.Pool;

  constructor(@Inject(APP_CONFIG) config: AppConfig) {
    this.pool = new pg.Pool({
      connectionString: config.DATABASE_URL,
      max: config.DATABASE_POOL_MAX,
      idleTimeoutMillis: 30_000,
      statement_timeout: 30_000,
      application_name: 'streamero',
    });
    this.pool.on('error', (err) => this.logger.error({ err }, 'Idle PostgreSQL client error'));
  }

  async query<T extends pg.QueryResultRow = any>(text: string, params: unknown[] = [], client?: Queryable): Promise<T[]> {
    const res = await (client ?? this.pool).query<T>(text, params as any[]);
    return res.rows;
  }

  async one<T extends pg.QueryResultRow = any>(text: string, params: unknown[] = [], client?: Queryable): Promise<T | null> {
    const rows = await this.query<T>(text, params, client);
    return rows[0] ?? null;
  }

  async tx<T>(fn: (client: pg.PoolClient) => Promise<T>): Promise<T> {
    const client = await this.pool.connect();
    try {
      await client.query('BEGIN');
      const result = await fn(client);
      await client.query('COMMIT');
      return result;
    } catch (err) {
      await client.query('ROLLBACK').catch(() => undefined);
      throw err;
    } finally {
      client.release();
    }
  }

  async ping(): Promise<boolean> {
    try {
      await this.pool.query('SELECT 1');
      return true;
    } catch {
      return false;
    }
  }

  async onModuleDestroy() {
    await this.pool.end();
  }
}
