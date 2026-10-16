/**
 * Extract the backend's human-readable message from an HttpClient error.
 * Angular's own `err.message` is the generic "Http failure response for …"
 * string; the server's `{"message": …}` body lives on `err.error`.
 */
export function serverMessage(err: unknown): string | null {
  if (!err || typeof err !== 'object') return null;
  const body = (err as { error?: unknown }).error;
  if (!body || typeof body !== 'object') return null;
  const message = (body as { message?: unknown }).message;
  return typeof message === 'string' && message ? message : null;
}
