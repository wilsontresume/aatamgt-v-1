class_name BackendConfig
extends RefCounted
## Backend endpoint policy — the single place that decides which server
## the client talks to and which transports are acceptable.
##
## Security rules (Phase 3):
##  - HTTPS is mandatory for every host except loopback development.
##  - The base URL comes from the AATAMGT_API_URL environment variable
##    (set per build) or falls back to the local development backend.
##  - No credentials, tokens, or secrets are ever stored here; tokens
##    live only in the AuthService session file.

## Default: the Cloudflare tunnel to the hosted NestJS backend.
## Local development overrides via AATAMGT_API_URL (e.g. https://127.0.0.1:3443).
const DEFAULT_BASE_URL := "https://sent-cloth-trends-fit.trycloudflare.com"

const ENV_BASE_URL := "AATAMGT_API_URL"
const ENV_CA_CERT := "AATAMGT_CA_CERT"

const LOOPBACK_HOSTS := ["127.0.0.1", "localhost", "::1", "[::1]"]


## Resolved endpoint for this run: env override, else default.
static func resolve_base_url() -> String:
	var from_env := OS.get_environment(ENV_BASE_URL).strip_edges()
	return normalize(from_env) if not from_env.is_empty() else DEFAULT_BASE_URL


## Optional CA bundle for TLS verification (self-signed dev backends).
## Empty string = trust the platform certificate store.
##
## On device, OS.get_environment cannot be set per-app, so debug builds
## fall back to the bundled dev certificate (server/scripts/dev-cert.sh)
## — the same cert desktop e2e passes via AATAMGT_CA_CERT — but only
## when the resolved backend is a loopback dev server. Remote backends
## (Cloudflare tunnel, production) use the platform certificate store.
## Release builds never resolve a path here: they use the platform store only.
static func ca_cert_path() -> String:
	var from_env := OS.get_environment(ENV_CA_CERT).strip_edges()
	if not from_env.is_empty():
		return from_env
	if OS.is_debug_build() and _host(resolve_base_url()).to_lower() in LOOPBACK_HOSTS:
		const DEV_CERT := "res://server/dev-certs/dev-cert.pem"
		if FileAccess.file_exists(DEV_CERT):
			return DEV_CERT
	return ""


## Returns the normalized URL (no trailing slash) when the URL satisfies
## the transport policy, or "" when it is rejected. Plain HTTP is only
## tolerated for loopback addresses (local development).
static func validate_url(url: String) -> String:
	var candidate := normalize(url)
	if candidate.is_empty():
		return ""
	var scheme := _scheme(candidate)
	if scheme == "https":
		return candidate if _host(candidate) != "" else ""
	if scheme == "http":
		var host := _host(candidate).to_lower()
		if host in LOOPBACK_HOSTS:
			return candidate
	return ""


static func normalize(url: String) -> String:
	var trimmed := url.strip_edges()
	while trimmed.ends_with("/"):
		trimmed = trimmed.substr(0, trimmed.length() - 1)
	return trimmed


static func _scheme(url: String) -> String:
	var idx := url.find("://")
	if idx <= 0:
		return ""
	return url.substr(0, idx).to_lower()


static func _host(url: String) -> String:
	var scheme_end := url.find("://")
	if scheme_end < 0:
		return ""
	var rest := url.substr(scheme_end + 3)
	rest = rest.split("/")[0]
	rest = rest.split("?")[0]
	# Strip credentials and port, keep bracketed IPv6 hosts intact.
	var at := rest.rfind("@")
	if at >= 0:
		rest = rest.substr(at + 1)
	if rest.begins_with("["):
		var close := rest.find("]")
		return "" if close < 0 else rest.substr(0, close + 1)
	return rest.split(":")[0]
