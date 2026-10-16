import { HttpErrorResponse, HttpInterceptorFn } from '@angular/common/http';
import { inject } from '@angular/core';
import { Router } from '@angular/router';
import { catchError, from, switchMap, throwError } from 'rxjs';
import { AuthService } from './auth.service';

export const authInterceptor: HttpInterceptorFn = (req, next) => {
  const auth = inject(AuthService);
  const router = inject(Router);
  const session = auth.session();

  const withToken = (token: string) =>
    req.clone({ setHeaders: { Authorization: `Bearer ${token}` } });

  const send = session ? next(withToken(session.accessToken)) : next(req);

  return send.pipe(
    catchError((error: unknown) => {
      const isAuthRequest = req.url.includes('/auth/');
      if (!(error instanceof HttpErrorResponse) || error.status !== 401 || isAuthRequest) {
        return throwError(() => error);
      }
      // Refresh once (single-flight across concurrent 401s), then retry the original request.
      return from(auth.refreshTokens()).pipe(
        switchMap((refreshed) => {
          if (!refreshed) {
            router.navigate(['/login']);
            return throwError(() => error);
          }
          return next(withToken(refreshed.accessToken));
        }),
      );
    }),
  );
};
