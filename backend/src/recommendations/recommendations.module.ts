import { Module } from '@nestjs/common';
import { RecommendationsController } from './recommendations.controller.js';
import { RecommendationsService } from './recommendations.service.js';

@Module({ controllers: [RecommendationsController], providers: [RecommendationsService], exports: [RecommendationsService] })
export class RecommendationsModule {}
