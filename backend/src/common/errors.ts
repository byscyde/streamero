import { HttpException, HttpStatus } from '@nestjs/common';

/** Domain error with a stable machine-readable code. Clients switch on `code`, never on `message`. */
export class AppError extends HttpException {
  constructor(
    status: HttpStatus,
    readonly code: string,
    message: string,
    readonly details?: unknown,
  ) {
    super({ code, message, details }, status);
  }
}

export const notFound = (what: string) => new AppError(HttpStatus.NOT_FOUND, 'not_found', `${what} not found`);
export const forbidden = (message = 'You do not have access to this resource') =>
  new AppError(HttpStatus.FORBIDDEN, 'forbidden', message);
export const badRequest = (code: string, message: string, details?: unknown) =>
  new AppError(HttpStatus.BAD_REQUEST, code, message, details);
export const conflict = (code: string, message: string, details?: unknown) =>
  new AppError(HttpStatus.CONFLICT, code, message, details);
export const unauthorized = (code = 'unauthorized', message = 'Authentication required') =>
  new AppError(HttpStatus.UNAUTHORIZED, code, message);
