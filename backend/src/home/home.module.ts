import { Controller, Get, Module } from '@nestjs/common';
import { ApiBearerAuth, ApiTags } from '@nestjs/swagger';
import type { AuthUser } from '../common/auth-user.js';
import { CurrentUser } from '../common/decorators.js';
import { PlaybackModule } from '../playback/playback.module.js';
import { PlaylistsModule } from '../playlists/playlists.module.js';
import { RecommendationsModule } from '../recommendations/recommendations.module.js';
import { HomeService } from './home.service.js';

@ApiTags('discovery')
@ApiBearerAuth()
@Controller('v1/home')
export class HomeController {
  constructor(private readonly home: HomeService) {}

  @Get()
  feed(@CurrentUser() user: AuthUser) {
    return this.home.feed(user.id);
  }
}

@Module({
  imports: [RecommendationsModule, PlaybackModule, PlaylistsModule],
  controllers: [HomeController],
  providers: [HomeService],
})
export class HomeModule {}
