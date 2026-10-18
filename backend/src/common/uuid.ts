import { ParseUUIDPipe } from '@nestjs/common';
import { badRequest } from './errors.js';

export const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export const uuidPipe = new ParseUUIDPipe({
  exceptionFactory: () => badRequest('invalid_identifier', 'Identifier must be a UUID'),
});
