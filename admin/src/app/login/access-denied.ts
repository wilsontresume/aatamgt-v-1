import { Component } from '@angular/core';
import { Router } from '@angular/router';
import { AuthService } from '../core/auth.service';

@Component({
  selector: 'app-access-denied',
  standalone: true,
  template: `
    <div class="wrap">
      <div class="card">
        <h1>Staff access required</h1>
        <p>
          Your account does not have administrator or moderator privileges, so
          it cannot open the operations console.
        </p>
        <button class="primary" (click)="signOut()">Sign in with another account</button>
      </div>
    </div>
  `,
  styles: [
    `
      .wrap {
        min-height: 100vh;
        display: grid;
        place-items: center;
        background: #134e4a;
        padding: 24px;
      }
      .card {
        background: #fffdf7;
        border-radius: 16px;
        padding: 32px;
        max-width: 440px;
        text-align: center;
      }
      h1 {
        margin: 0 0 12px;
        color: #134e4a;
        font-size: 1.2rem;
      }
      p {
        color: #78716c;
        line-height: 1.5;
        margin: 0 0 20px;
      }
      button.primary {
        background: #0f766e;
        color: #fff;
        border: none;
        border-radius: 10px;
        padding: 12px 18px;
        font-weight: 700;
        cursor: pointer;
      }
    `,
  ],
})
export class AccessDeniedPage {
  constructor(
    private readonly auth: AuthService,
    private readonly router: Router,
  ) {}

  signOut(): void {
    this.auth.logout();
    void this.router.navigate(['/login']);
  }
}
