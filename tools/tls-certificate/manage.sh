#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$PROJECT_ROOT/tools/proxy-env.sh"
ENV_FILE="${MAXA_ENV_FILE:-$PROJECT_ROOT/.env}"
if [[ "$ENV_FILE" == '~/'* ]]; then ENV_FILE="$HOME/${ENV_FILE:2}"; fi

read_domain() {
  [[ -f "$ENV_FILE" ]] || return 0
  local line value="" quote
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*MAXA_CERT_DOMAIN[[:space:]]*=[[:space:]]*(.*)$ ]]; then
      value="${BASH_REMATCH[1]}"
      value="${value%"${value##*[![:space:]]}"}"
      quote="${value:0:1}"
      if [[ ${#value} -ge 2 && ( "$quote" == '"' || "$quote" == "'" ) && "${value: -1}" == "$quote" ]]; then
        value="${value:1:${#value}-2}"
      fi
    fi
  done < "$ENV_FILE"
  printf '%s' "$value"
}

DOMAIN="${MAXA_CERT_DOMAIN:-$(read_domain)}"
CERT_DIR="${MAXA_CERT_DIR:-$PROJECT_ROOT/certificates/$DOMAIN}"
ACME_DIR="$CERT_DIR/.acme"
LIVE_DIR="$ACME_DIR/live/$DOMAIN"
RENEW_BEFORE_DAYS="${MAXA_CERT_RENEW_BEFORE_DAYS:-30}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <status|renew|paths>

Manage the shared Let's Encrypt certificate for the configured DNS hostname using Cloudflare DNS-01.

Commands:
  status  Check certificate presence, subject, issuer, validity, and renewal need.
  renew   Issue/renew only when missing or expiring within $RENEW_BEFORE_DAYS days.
          Cloudflare API Token is read interactively without echo and is never saved.
  paths   Print the stable certificate paths consumed by local tools.

Stable paths:
  $CERT_DIR/fullchain.pem
  $CERT_DIR/cert.pem
  $CERT_DIR/chain.pem
  $CERT_DIR/privkey.pem

Environment overrides:
  MAXA_CERT_DOMAIN  Required domain; process environment overrides the selected local file.
  MAXA_ENV_FILE     Optional local file; defaults to the runtime root .env.
  MAXA_CERT_DIR
  MAXA_CERT_RENEW_BEFORE_DAYS
  ACME_EMAIL  Optional Let's Encrypt account email; prompted when omitted.
EOF
}

paths() {
  printf 'domain=%s\n' "$DOMAIN"
  printf 'cert_dir=%s\n' "$CERT_DIR"
  printf 'fullchain=%s\n' "$CERT_DIR/fullchain.pem"
  printf 'cert=%s\n' "$CERT_DIR/cert.pem"
  printf 'chain=%s\n' "$CERT_DIR/chain.pem"
  printf 'privkey=%s\n' "$CERT_DIR/privkey.pem"
}

has_current_certificate() {
  [[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" ]]
}

needs_renewal() {
  has_current_certificate || return 0
  local seconds=$((RENEW_BEFORE_DAYS * 24 * 60 * 60))
  ! openssl x509 -checkend "$seconds" -noout -in "$CERT_DIR/fullchain.pem" >/dev/null 2>&1
}

status() {
  paths
  if ! has_current_certificate; then
    echo "status=missing"
    return 1
  fi

  openssl x509 -noout -subject -issuer -dates -in "$CERT_DIR/fullchain.pem"
  openssl x509 -noout -checkhost "$DOMAIN" -in "$CERT_DIR/fullchain.pem" >/dev/null
  if needs_renewal; then
    echo "status=renewal-required"
    return 2
  fi
  echo "status=valid"
}

install_stable_files() {
  local name source temporary
  mkdir -p "$CERT_DIR"
  chmod 700 "$CERT_DIR"
  for name in fullchain.pem cert.pem chain.pem privkey.pem; do
    source="$LIVE_DIR/$name"
    [[ -s "$source" ]] || { echo "ERROR: certbot output missing: $source" >&2; return 1; }
    temporary="$CERT_DIR/.$name.tmp.$$"
    cp -L "$source" "$temporary"
    if [[ "$name" == "privkey.pem" ]]; then chmod 600 "$temporary"; else chmod 644 "$temporary"; fi
    mv -f "$temporary" "$CERT_DIR/$name"
  done
}

renew() {
  command -v openssl >/dev/null || { echo "ERROR: openssl is required" >&2; exit 1; }
  command -v uvx >/dev/null || { echo "ERROR: uvx is required" >&2; exit 1; }

  if ! needs_renewal; then
    echo "Certificate remains valid for more than $RENEW_BEFORE_DAYS days; renewal skipped."
    status
    return 0
  fi

  local token email credentials
  read -r -s -p "Cloudflare API Token for $DOMAIN (input hidden): " token
  echo
  [[ -n "$token" ]] || { echo "ERROR: Cloudflare API Token is required" >&2; exit 1; }

  email="${ACME_EMAIL:-}"
  if [[ -z "$email" ]]; then
    read -r -p "Let's Encrypt account email: " email
  fi
  [[ "$email" == *@*.* ]] || { echo "ERROR: a valid ACME account email is required" >&2; exit 1; }

  mkdir -p "$CERT_DIR" "$ACME_DIR" "$ACME_DIR/work" "$ACME_DIR/logs"
  chmod 700 "$CERT_DIR" "$ACME_DIR"
  credentials="$(mktemp "$CERT_DIR/.cloudflare-token.XXXXXX")"
  cleanup() {
    rm -f "$credentials"
    token=""
  }
  trap cleanup EXIT INT TERM
  chmod 600 "$credentials"
  printf 'dns_cloudflare_api_token = %s\n' "$token" > "$credentials"

  env -u ALL_PROXY -u all_proxy \
  HTTP_PROXY="$(maxa_proxy_value HTTP_PROXY)" \
  HTTPS_PROXY="$(maxa_proxy_value HTTPS_PROXY)" \
  http_proxy="${http_proxy:-$(maxa_proxy_value HTTP_PROXY)}" \
  https_proxy="${https_proxy:-$(maxa_proxy_value HTTPS_PROXY)}" \
  uvx --from certbot --with certbot-dns-cloudflare certbot certonly \
    --non-interactive \
    --agree-tos \
    --email "$email" \
    --preferred-challenges dns-01 \
    --authenticator dns-cloudflare \
    --dns-cloudflare-credentials "$credentials" \
    --dns-cloudflare-propagation-seconds 30 \
    --domain "$DOMAIN" \
    --cert-name "$DOMAIN" \
    --config-dir "$ACME_DIR" \
    --work-dir "$ACME_DIR/work" \
    --logs-dir "$ACME_DIR/logs" \
    --keep-until-expiring

  install_stable_files
  cleanup
  trap - EXIT INT TERM
  echo "Certificate ready."
  status
}

case "${1:-}" in
  -h|--help|help) usage; exit 0 ;;
  status|renew|paths) ;;
  *) usage >&2; exit 2 ;;
esac

if [[ -z "$DOMAIN" ]]; then
  echo "ERROR: MAXA_CERT_DOMAIN is required in process environment or $ENV_FILE" >&2
  exit 1
fi

case "$1" in
  status) status ;;
  renew) renew ;;
  paths) paths ;;
esac
