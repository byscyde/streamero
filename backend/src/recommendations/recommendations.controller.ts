import { Controller, Get, Param } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import type { AuthUser } from '../common/auth-user.js';
import { CurrentUser } from '../common/decorators.js';
import { badRequest } from '../common/errors.js';
import { RecommendationsService } from './recommendations.service.js';

@ApiTags('discovery')
@ApiBearerAuth()
@Controller('v1')
export class RecommendationsController {
  constructor(private readonly recs: RecommendationsService) {}

  @Get('mixes')
  mixes(@CurrentUser() user: AuthUser) {
    return this.recs.mixes(user.id).then((items) => ({ items }));
  }

  @Get('mixes/:id')
  mix(@CurrentUser() user: AuthUser, @Param('id') id: string) {
    if (id.length > 120) throw badRequest('invalid_mix', 'Invalid mix id');
    return this.recs.mix(user.id, id);
  }

  @Get('recommendations/albums')
  albums(@CurrentUser() user: AuthUser) {
    return this.recs.albumRecommendations(user.id).then((items) => ({ items }));
  }

  @Get('charts/trending')
  trending(@CurrentUser() user: AuthUser) {
    return this.recs.trending(user.id, 50).then((items) => ({ items }));
  }
}
