import 'reflect-metadata';
import { type INestApplication, ValidationPipe } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import type { NestExpressApplication } from '@nestjs/platform-express';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import express from 'express';
import helmet from 'helmet';
import { Logger } from 'nestjs-pino';
import { AppModule } from './app.module.js';
import { setPublicBaseUrl } from './catalog/presenters.js';
import { APP_CONFIG, type AppConfig } from './config/config.js';
import { httpDuration } from './health/metrics.js';

export function buildOpenApi(app: INestApplication) {
  const doc = new DocumentBuilder()
    .setTitle('STREAMERO API')
    .setDescription('Music & video streaming platform API. All endpoints are versioned under /v1. Errors use `{ error: { code, message, details? }, requestId }`.')
    .setVersion('1.0.0')
    .addBearerAuth()
    .build();
  return SwaggerModule.createDocument(app, doc);
}

export async function createApp(opts: { logger?: boolean } = {}): Promise<NestExpressApplication> {
  const app = await NestFactory.create<NestExpressApplication>(AppModule, { bufferLogs: true, bodyParser: false });
  const config = app.get<AppConfig>(APP_CONFIG);
  if (opts.logger !== false) app.useLogger(app.get(Logger));
  setPublicBaseUrl(config.PUBLIC_BASE_URL);

  app.set('trust proxy', 1); // behind the reverse proxy (infra/nginx.conf); used for client IPs in rate limiting/audit
  app.disable('x-powered-by');
  app.use(helmet({ crossOriginResourcePolicy: { policy: 'cross-origin' } }));
  app.enableCors({
    origin: (origin, cb) => cb(null, !origin || config.CORS_ORIGINS.includes(origin)),
    credentials: false,
    methods: ['GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE'],
    allowedHeaders: ['Authorization', 'Content-Type', 'X-Request-Id', 'Range'],
    exposedHeaders: ['X-Request-Id', 'Content-Range'],
    maxAge: 600,
  });
  // Upload chunks arrive as raw bytes; everything else is JSON with a modest size limit.
  app.use('/v1/admin/uploads', express.raw({ type: 'application/octet-stream', limit: '9mb' }));
  app.use(express.json({ limit: '1mb' }));
  app.use((req: express.Request, res: express.Response, next: express.NextFunction) => {
    const end = httpDuration.startTimer();
    res.on('finish', () => end({ method: req.method, route: (req as any).route?.path ?? 'unmatched', status: String(res.statusCode) }));
    next();
  });
  app.useGlobalPipes(new ValidationPipe({ whitelist: true, forbidNonWhitelisted: false, transform: true, transformOptions: { enableImplicitConversion: false } }));
  app.enableShutdownHooks();

  const document = buildOpenApi(app);
  SwaggerModule.setup('docs', app, document, { jsonDocumentUrl: 'openapi.json' });
  return app;
}
