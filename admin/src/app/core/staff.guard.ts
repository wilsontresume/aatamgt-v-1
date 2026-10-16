import { inject } from '@angular/core';
import { CanActivateFn, Router } from '@angular/router';
import { AuthService } from './auth.service';

export const staffGuard: CanActivateFn = () => {
  const auth = inject(AuthService);
  const router = inject(Router);
  if (!auth.session()) return router.createUrlTree(['/login']);
  if (!auth.isStaff) return router.createUrlTree(['/access']);
  return true;
};

export const loginGuard: CanActivateFn = () => {
  const auth = inject(AuthService);
  const router = inject(Router);
  if (auth.session() && auth.isStaff) return router.createUrlTree(['/dashboard']);
  return true;
};
