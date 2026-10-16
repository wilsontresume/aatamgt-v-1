import { Routes } from '@angular/router';
import { Shell } from './layout/shell';
import { loginGuard, staffGuard } from './core/staff.guard';

export const routes: Routes = [
  {
    path: 'login',
    canActivate: [loginGuard],
    loadComponent: () => import('./login/login').then((m) => m.LoginPage),
  },
  {
    path: 'access',
    loadComponent: () => import('./login/access-denied').then((m) => m.AccessDeniedPage),
  },
  {
    path: '',
    component: Shell,
    canActivate: [staffGuard],
    children: [
      { path: '', pathMatch: 'full', redirectTo: 'dashboard' },
      {
        path: 'dashboard',
        loadComponent: () => import('./dashboard/dashboard').then((m) => m.DashboardPage),
      },
    ],
  },
  { path: '**', redirectTo: '' },
];
