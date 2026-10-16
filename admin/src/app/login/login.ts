import { Component, signal } from '@angular/core';
import { FormsModule } from '@angular/forms';
import { Router } from '@angular/router';
import { AuthService } from '../core/auth.service';

@Component({
  selector: 'app-login',
  standalone: true,
  imports: [FormsModule],
  templateUrl: './login.html',
  styleUrl: './login.scss',
})
export class LoginPage {
  username = '';
  password = '';
  readonly error = signal<string | null>(null);
  readonly busy = signal(false);

  constructor(
    private readonly auth: AuthService,
    private readonly router: Router,
  ) {}

  async submit(): Promise<void> {
    if (!this.username || !this.password) {
      this.error.set('Enter your username and password.');
      return;
    }
    this.busy.set(true);
    this.error.set(null);
    try {
      const user = await this.auth.login(this.username.trim(), this.password);
      const target = user.role === 'USER' ? '/access' : '/dashboard';
      void this.router.navigate([target]);
    } catch {
      this.error.set('Sign-in failed. Check your credentials and try again.');
    } finally {
      this.busy.set(false);
    }
  }
}
