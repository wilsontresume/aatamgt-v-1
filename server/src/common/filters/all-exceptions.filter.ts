import {
  ArgumentsHost,
  Catch,
  ExceptionFilter,
  HttpException,
  HttpStatus,
  LoggerService,
} from '@nestjs/common';
import { Prisma } from '@prisma/client';
import { Request, Response } from 'express';

interface ErrorBody {
  statusCode: number;
  error: string;
  message: string;
  details?: unknown;
  timestamp: string;
  path: string;
  requestId?: string;
}

@Catch()
export class AllExceptionsFilter implements ExceptionFilter {
  constructor(private readonly logger: LoggerService) {}

  catch(exception: unknown, host: ArgumentsHost): void {
    const ctx = host.switchToHttp();
    const response = ctx.getResponse<Response>();
    const request = ctx.getRequest<Request & { id?: string }>();
    const { status, error, message, details } = this.resolve(exception);

    const body: ErrorBody = {
      statusCode: status,
      error,
      message,
      timestamp: new Date().toISOString(),
      path: request.url ?? '/',
      ...(details ? { details } : {}),
      ...(request.id ? { requestId: request.id } : {}),
    };

    if (status >= 500) {
      this.logger.error(
        exception instanceof Error ? exception : String(exception),
        exception instanceof Error ? exception.stack : undefined,
        'AllExceptionsFilter',
      );
    } else {
      this.logger.warn(
        `${status} ${message} ${request.method} ${request.url}`,
        'AllExceptionsFilter',
      );
    }

    response.status(status).json(body);
  }

  private resolve(exception: unknown): {
    status: number;
    error: string;
    message: string;
    details?: unknown;
  } {
    if (exception instanceof HttpException) {
      const status = exception.getStatus();
      const payload = exception.getResponse();
      if (typeof payload === 'string') {
        return { status, error: HttpStatus[status] ?? 'Error', message: payload };
      }
      const record = payload as Record<string, unknown>;
      const message = typeof record.message === 'string' ? record.message : exception.message;
      const details = Array.isArray(record.message) ? record.message : undefined;
      return {
        status,
        error: (record.error as string) ?? HttpStatus[status] ?? 'Error',
        message,
        ...(details ? { details } : {}),
      };
    }

    if (exception instanceof Prisma.PrismaClientKnownRequestError) {
      return this.mapPrisma(exception);
    }
    if (exception instanceof Prisma.PrismaClientValidationError) {
      return { status: 400, error: 'Bad Request', message: 'Invalid database operation payload' };
    }

    return { status: 500, error: 'Internal Server Error', message: 'Unexpected server error' };
  }

  private mapPrisma(exception: Prisma.PrismaClientKnownRequestError): {
    status: number;
    error: string;
    message: string;
    details?: unknown;
  } {
    switch (exception.code) {
      case 'P2002':
        return {
          status: 409,
          error: 'Conflict',
          message: 'Resource already exists',
          details: exception.meta,
        };
      case 'P2025':
        return { status: 404, error: 'Not Found', message: 'Resource not found' };
      case 'P2003':
        return {
          status: 422,
          error: 'Unprocessable Entity',
          message: 'Related resource constraint violated',
          details: exception.meta,
        };
      case 'P2023':
        return { status: 400, error: 'Bad Request', message: 'Malformed identifier' };
      case 'P2024':
      case 'P1017':
        return { status: 503, error: 'Service Unavailable', message: 'Database unavailable' };
      default:
        return { status: 500, error: 'Internal Server Error', message: 'Database error' };
    }
  }
}
