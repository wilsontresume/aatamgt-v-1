# Content Asset Storage (Phase E)

## Overview

Content assets (game backgrounds, board textures, piece art, tier art) are uploaded through the Content Studio, stored by a pluggable storage adapter, and served to clients via the published manifest.

- **Upload endpoint (ADMIN):** `POST /api/v1/admin/assets` (multipart form)
- **Replace (new immutable version):** `POST /api/v1/admin/assets/:id/replace`
- **Activate/deactivate:** `PATCH /api/v1/admin/assets/:id` with `{ "active": true|false }`
- **File download (PUBLIC):** `GET /api/v1/content/assets/:id/file`
- **Manifest (PUBLIC):** `GET /api/v1/content/manifest`

Every mutation writes an `AdminAuditLog` row (actor, action, target type, target id).

## Storage drivers

Configured via environment variables (names only — never commit values):

| Variable | Purpose |
|---|---|
| `ASSET_STORAGE_DRIVER` | `local` (default) or `s3` |
| `ASSET_STORAGE_LOCAL_ROOT` | Absolute path for the `local` driver, e.g. `/var/lib/aatamgt/assets` |
| `ASSET_MAX_UPLOAD_BYTES` | Per-file size cap (default `10485760` = 10 MiB) |
| `ASSET_S3_BUCKET` | S3 bucket name (driver `s3` only) |
| `ASSET_S3_REGION` | AWS region (driver `s3` only) |
| `ASSET_S3_ACCESS_KEY_ID` | Access key (driver `s3` only) |
| `ASSET_S3_SECRET_ACCESS_KEY` | Secret key (driver `s3` only) |
| `ASSET_S3_ENDPOINT` | Optional custom endpoint (MinIO, R2, etc.) |
| `ASSET_S3_FORCE_PATH_STYLE` | `true` for MinIO-style path URLs |

### Local driver

Writes under `ASSET_STORAGE_LOCAL_ROOT` using the deterministic key layout
`<first-two-hex>/<asset-id>-v<version>.<ext>`. The server serves files from this
root with `Cache-Control: public, max-age=31536000, immutable` and an `ETag`
derived from the stored checksum. No server-side thumbnails are generated (see
Limitations).

### S3 driver (deployment)

1. Create a private bucket. Enable versioning if you want server-side history as
   a second safety net (the database already stores per-version rows).
2. Grant the app credentials `s3:GetObject`, `s3:PutObject`, and
   `s3:DeleteObject` on `arn:aws:s3:::<bucket>/*` only.
3. Set the `ASSET_S3_*` variables above. Do **not** set
   `ASSET_STORAGE_LOCAL_ROOT` when using `s3`.
4. Optionally front the bucket with CloudFront or another CDN; point the public
   manifest `url` field at the CDN origin if you rewrite it at the edge.
5. The server still streams through `GET /api/v1/content/assets/:id/file` so the
   checksum verification and immutable cache headers stay under our control.

## Image validation

Uploads are signature-validated (magic bytes) — not just extension checks.
Accepted: PNG, JPEG, WebP, GIF. Minimum dimension 16 px, maximum 4096 px.
The stored SHA-256 checksum is what the Godot client verifies after download.

## Publish / rollback

`POST /api/v1/admin/content/publish` freezes a validated snapshot of the live
database (games + board themes + tiers + referenced assets) into an immutable
manifest row and returns its version + checksum. `POST /api/v1/admin/content/publications/:version/rollback`
re-publishes an old manifest verbatim (it does not rebuild from the live DB).
Clients pick up the new version on their next manifest poll; asset files are
content-addressed and never change under an existing checksum.

## Limitations

- **No server-side thumbnails.** Thumbnails would require a native image
  library (sharp) in the server process; that dependency is intentionally out of
  scope for Phase E. Clients download full-resolution assets. If thumbnail
  support is needed later, add a separate worker/service rather than coupling it
  to the API process.
- **Single-region storage.** The S3 driver has no replication or lifecycle
  policies configured; enable those on the bucket itself.
- **Manifest checksum is server-computed.** Clients treat the inner checksum as
  an opaque change-detection token (key order differs across implementations);
  asset downloads are still sha256-verified against the per-asset checksum.
