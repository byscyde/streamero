import { Module } from '@nestjs/common';
import { ArtworkController, CatalogController } from './catalog.controller.js';
import { CatalogService } from './catalog.service.js';

@Module({ controllers: [CatalogController, ArtworkController], providers: [CatalogService], exports: [CatalogService] })
export class CatalogModule {}
