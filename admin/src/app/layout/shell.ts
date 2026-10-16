import { Component } from '@angular/core';
import { RouterLink, RouterOutlet } from '@angular/router';
import { AuthService } from '../core/auth.service';

@Component({
  selector: 'app-shell',
  standalone: true,
  imports: [RouterOutlet, RouterLink],
  templateUrl: './shell.html',
  styleUrl: './shell.scss',
})
export class Shell {
  constructor(readonly auth: AuthService) {}

  logout(): void {
    this.auth.logout();
    window.location.href = '/login';
  }
}
