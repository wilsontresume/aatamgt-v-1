# Social Login (Google / Facebook) & Guest Free Credits

Server API feature. No Godot buttons yet — the endpoints are ready for a
client that can obtain native SDK tokens.

## Guest free credits

`POST /api/v1/auth/guest` now grants every new guest account the same
server-computed bonus as normal registration (`coins.registration_bonus`,
default 1000, admin-editable in Economy → Config).

- Ledger type: `REGISTRATION_BONUS`, memo `Guest welcome bonus`
- Idempotency key: `guest-registration:<userId>` — never replayable, since
  guest login always creates a fresh account
- The client never asks for an amount; the amount is server-side only

## `POST /api/v1/auth/social`

Public route (throttled like login). Body:

```json
{ "provider": "google" | "facebook", "token": "<provider token>" }
```

- `google` token = an ID token from Google Sign-In
- `facebook` token = a user access token from the Facebook SDK

Response: `{ user, accessToken, refreshToken, expiresIn, upgraded }`

### Verification (server-side only)

The identity always comes from the provider, never from the client:

- **Google** — the ID token is checked against Google's `tokeninfo` endpoint
  and the `aud` claim must equal `GOOGLE_CLIENT_ID`.
- **Facebook** — the token is checked via `debug_token` with the app token
  (`APP_ID|APP_SECRET`), `app_id` must match `FACEBOOK_APP_ID`, then the
  identity is read from `/me` and the id must match `user_id`.

### Three flows

1. **Existing identity** → normal login of the linked account.
2. **Guest session present** (send the guest's `Authorization: Bearer …`
   header) → the social identity is attached to *that same account*:
   progress, coins and matches are kept, `isGuest` flips to `false`, and a
   `guest_conversion` analytics event is recorded. `upgraded: true`.
   If the identity is already linked to a *different* account the request
   fails with `409` — never a silent account switch.
3. **No session** → a brand-new registered account is created with the
   identity attached and the normal registration bonus.

### Configuration

All optional; an unset provider answers `403 "… sign-in is not configured"`.

| Env var | Purpose |
| --- | --- |
| `GOOGLE_CLIENT_ID` | Google OAuth client id (audience check) |
| `FACEBOOK_APP_ID` | Facebook app id (`debug_token` check) |
| `FACEBOOK_APP_SECRET` | Facebook app secret (builds the app token) |

## Data model

New table `SocialAccount` (migration `20261026072822_social_login`):

- `provider` + `subject` unique — one row per provider identity
- `userId` + `provider` unique — one identity per provider per user
- cascade-deleted with the user

## Tests

`server/test/integration/auth-social.spec.ts` (provider HTTP mocked, 8
cases) and the guest-bonus case in `auth-guest.spec.ts`.
