import { ApiPropertyOptional } from '@nestjs/swagger';
import { Type } from 'class-transformer';
import { IsInt, IsOptional, Max, Min } from 'class-validator';

export class PageQuery {
  @ApiPropertyOptional({ minimum: 1, maximum: 100, default: 30 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(1)
  @Max(100)
  limit: number = 30;

  @ApiPropertyOptional({ minimum: 0, default: 0 })
  @IsOptional()
  @Type(() => Number)
  @IsInt()
  @Min(0)
  @Max(100_000)
  offset: number = 0;
}

export interface Page<T> {
  items: T[];
  limit: number;
  offset: number;
  total?: number;
  nextOffset: number | null;
}

/** Builds a page from rows fetched with `LIMIT limit + 1`, which avoids an extra COUNT query. */
export function toPage<T>(rows: T[], q: { limit: number; offset: number }, total?: number): Page<T> {
  const hasMore = rows.length > q.limit;
  return {
    items: hasMore ? rows.slice(0, q.limit) : rows,
    limit: q.limit,
    offset: q.offset,
    ...(total !== undefined ? { total } : {}),
    nextOffset: hasMore ? q.offset + q.limit : null,
  };
}
