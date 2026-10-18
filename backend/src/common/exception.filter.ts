import { ArgumentsHost, Catch, ExceptionFilter, HttpException, HttpStatus, Logger } from '@nestjs/common';
import type { Request, Response } from 'express';

const DEFAULT_CODES: Record<number, string> = {
  400: 'bad_request',
  401: 'unauthorized',
  403: 'forbidden',
  404: 'not_found',
  409: 'conflict',
  413: 'payload_too_large',
  415: 'unsupported_media_type',
  416: 'range_not_satisfiable',
  422: 'unprocessable',
  429: 'rate_limited',
};

/** Normalises every error to `{ error: { code, message, details? }, requestId }`. Internal errors never leak details. */
@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  private readonly logger = new Logger('Exceptions');

  catch(exception: unknown, host: ArgumentsHost) {
    const ctx = host.switchToHttp();
    const res = ctx.getResponse<Response>();
    const req = ctx.getRequest<Request & { id?: string }>();
    let status = HttpStatus.INTERNAL_SERVER_ERROR;
    let code = 'internal_error';
    let message = 'An unexpected error occurred';
    let details: unknown;

    if (exception instanceof HttpException) {
      status = exception.getStatus();
      const body = exception.getResponse() as any;
      code = (typeof body === 'object' && body?.code) || DEFAULT_CODES[status] || 'error';
      if (typeof body === 'string') message = body;
      else if (Array.isArray(body?.message)) {
        code = 'validation_failed';
        message = 'Request validation failed';
        details = body.message;
      } else message = body?.message ?? exception.message;
      if (body?.details !== undefined) details = body.details;
    } else if ((exception as any)?.code === '23505') {
      status = HttpStatus.CONFLICT;
      code = 'conflict';
      message = 'Resource already exists';
    } else if ((exception as any)?.code === '23503') {
      status = HttpStatus.CONFLICT;
      code = 'reference_conflict';
      message = 'Operation conflicts with a referenced resource';
    } else if ((exception as any)?.code === '22P02') {
      status = HttpStatus.BAD_REQUEST;
      code = 'invalid_identifier';
      message = 'Malformed identifier or value';
    }

    if (!(exception instanceof HttpException)) this.logger.error({ err: exception, path: req.path }, 'Unhandled error');
    if (res.headersSent) return;
    res.status(status).json({ error: { code, message, ...(details !== undefined ? { details } : {}) }, requestId: req.id });
  }
}
