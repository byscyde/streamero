import { Body, Controller, Get, HttpCode, Post, Put, Req, Res } from '@nestjs/common';
import { ApiBearerAuth, ApiBody, ApiHeader, ApiOkResponse, ApiOperation, ApiResponse, ApiTags } from '@nestjs/swagger';
import type { Request, Response } from 'express';
import { z } from 'zod';
import type { AuthUser } from '../common/auth-user.js';
import { CurrentUser, Public, RequireRole } from '../common/decorators.js';
import { appearanceDocumentSchema, appearancePatchSchema } from './appconfig.schema.js';
import { AppConfigService } from './appconfig.service.js';

/** OpenAPI schemas are generated from the same zod schemas that validate requests. */
const jsonSchema = (s: z.ZodType) => {
  const { $schema: _, ...rest } = z.toJSONSchema(s, { unrepresentable: 'any' }) as Record<string, any>;
  return rest;
};
const documentSchema = jsonSchema(appearanceDocumentSchema);
const patchSchema = jsonSchema(appearancePatchSchema);
const withDefaultsSchema = jsonSchema(appearanceDocumentSchema.extend({ defaults: appearanceDocumentSchema.omit({ version: true }) }));

/** Public remote configuration: used by every client, also before login (welcome screen). */
@ApiTags('app')
@Controller('v1/app')
export class AppConfigController {
  constructor(private readonly appConfig: AppConfigService) {}

  @Get('config')
  @Public()
  @ApiOperation({ summary: 'Remote app configuration (appearance, texts, feature flags), merged over defaults. Cacheable for 30 s; ETag = version.' })
  @ApiHeader({ name: 'If-None-Match', required: false, description: 'ETag from a previous response; 304 when unchanged' })
  @ApiOkResponse({ schema: documentSchema })
  @ApiResponse({ status: 304, description: 'Not modified' })
  async config(@Req() req: Request, @Res() res: Response) {
    const doc = await this.appConfig.get();
    const etag = `"${doc.version}"`;
    res.setHeader('Cache-Control', 'public, max-age=30');
    res.setHeader('ETag', etag);
    const inm = req.headers['if-none-match'];
    if (inm && inm.split(',').some((t) => t.trim().replace(/^W\//, '') === etag || t.trim() === '*')) {
      res.status(304).end();
      return;
    }
    res.status(200).json(doc);
  }
}

@ApiTags('admin')
@ApiBearerAuth()
@RequireRole('admin')
@Controller('v1/admin/appearance')
export class AppearanceAdminController {
  constructor(private readonly appConfig: AppConfigService) {}

  @Get()
  @ApiOperation({ summary: 'Current appearance document plus the built-in defaults' })
  @ApiOkResponse({ schema: withDefaultsSchema })
  get() {
    return this.appConfig.getWithDefaults();
  }

  @Put()
  @ApiOperation({ summary: 'Save a full or partial appearance document (validated; `version`/`defaults` are ignored)' })
  @ApiBody({ schema: patchSchema })
  @ApiOkResponse({ schema: documentSchema })
  update(@CurrentUser() user: AuthUser, @Body() body: unknown, @Req() req: Request) {
    return this.appConfig.update(user.id, body, req.ip);
  }

  @Post('reset')
  @HttpCode(200)
  @ApiOperation({ summary: 'Restore the default appearance' })
  @ApiOkResponse({ schema: documentSchema })
  reset(@CurrentUser() user: AuthUser, @Req() req: Request) {
    return this.appConfig.reset(user.id, req.ip);
  }
}
