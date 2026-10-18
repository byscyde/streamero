import { Body, Controller, Delete, Get, HttpCode, Post, Query } from '@nestjs/common';
import { ApiBearerAuth, ApiProperty, ApiQuery, ApiTags } from '@nestjs/swagger';
import { IsString, Length } from 'class-validator';
import type { AuthUser } from '../common/auth-user.js';
import { CurrentUser } from '../common/decorators.js';
import { PageQuery } from '../common/pagination.js';
import { SEARCH_TYPES, SearchService, type SearchType } from './search.service.js';

class RecentSearchDto {
  @ApiProperty() @IsString() @Length(1, 200) query: string;
}

@ApiTags('search')
@ApiBearerAuth()
@Controller('v1')
export class SearchController {
  constructor(private readonly search: SearchService) {}

  @Get('search')
  @ApiQuery({ name: 'q' })
  @ApiQuery({ name: 'types', required: false, description: `Comma separated: ${SEARCH_TYPES.join(', ')}` })
  run(@CurrentUser() user: AuthUser, @Query('q') q: string, @Query() page: PageQuery, @Query('types') types?: string) {
    const requested = (types ?? '')
      .split(',')
      .map((t) => t.trim())
      .filter((t): t is SearchType => (SEARCH_TYPES as readonly string[]).includes(t));
    return this.search.search(q ?? '', requested.length ? requested : [...SEARCH_TYPES], user.id, page);
  }

  @Get('search/suggestions')
  suggest(@Query('q') q: string) {
    return this.search.suggest(q ?? '');
  }

  @Get('me/recent-searches')
  recent(@CurrentUser() user: AuthUser) {
    return this.search.recent(user.id);
  }

  @Post('me/recent-searches')
  @HttpCode(204)
  async add(@CurrentUser() user: AuthUser, @Body() dto: RecentSearchDto) {
    await this.search.addRecent(user.id, dto.query);
  }

  @Delete('me/recent-searches')
  @HttpCode(204)
  async clear(@CurrentUser() user: AuthUser, @Query('query') query?: string) {
    await this.search.clearRecent(user.id, query);
  }
}
