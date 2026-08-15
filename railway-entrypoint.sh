#!/bin/sh
# Railway entrypoint for Documenso.
#
# Runs as root so it can repair the volume's ownership, then drops back to the
# image's own uid before the server binds. Three things happen here that stock
# Documenso does not do on its own:
#
#   1. A signing certificate is generated per deployment and kept on the volume.
#      Without one, `createLocalSigner()` throws and no document can ever be
#      signed -- while /api/health and /api/certificate-status both report ok.
#   2. An administrator account is seeded before the server listens, so the
#      public URL is never served to a stranger with an empty user table, and
#      the account actually holds the ADMIN role (nothing in Documenso grants
#      it -- the first signup is a plain USER).
#   3. NODE_ENV is pinned to production, which is what makes the certificate
#      resolution deterministic instead of falling through to a bundled example
#      file that does not exist in the published image.
set -eu

DATA_DIR="${DOCUMENSO_DATA_DIR:-/opt/documenso}"
CERT_PATH="$DATA_DIR/cert.p12"
APP_UID=1001
APP_GID=65533

log() { printf '[railway-entrypoint] %s\n' "$*"; }

# --- required configuration -------------------------------------------------

if [ -z "${DOCUMENSO_ADMIN_EMAIL:-}" ]; then
  log "FATAL: DOCUMENSO_ADMIN_EMAIL is empty. Refusing to start."
  exit 1
fi

if [ -z "${DOCUMENSO_ADMIN_PASSWORD:-}" ]; then
  log "FATAL: DOCUMENSO_ADMIN_PASSWORD is empty. Refusing to start, because an"
  log "       instance with no account is claimable by whoever opens the URL."
  exit 1
fi

if [ -z "${NEXT_PRIVATE_SIGNING_PASSPHRASE:-}" ]; then
  log "FATAL: NEXT_PRIVATE_SIGNING_PASSPHRASE is empty. Refusing to start."
  exit 1
fi

# Documenso reads the database from NEXT_PRIVATE_DATABASE_URL; prisma's CLI
# reads DATABASE_URL. Keep them in step so migrations and the app agree.
if [ -n "${NEXT_PRIVATE_DATABASE_URL:-}" ]; then
  DATABASE_URL="$NEXT_PRIVATE_DATABASE_URL"
  export DATABASE_URL
fi

export NODE_ENV=production
export HOSTNAME=0.0.0.0
export NEXT_PRIVATE_SIGNING_TRANSPORT="${NEXT_PRIVATE_SIGNING_TRANSPORT:-local}"
export NEXT_PRIVATE_SIGNING_LOCAL_FILE_PATH="$CERT_PATH"

# --- volume ownership -------------------------------------------------------

mkdir -p "$DATA_DIR"
owner_before="$(stat -c %u:%g "$DATA_DIR")"
chown -R "$APP_UID:$APP_GID" "$DATA_DIR"
log "data dir $DATA_DIR owner ${owner_before} -> $(stat -c %u:%g "$DATA_DIR")"

# --- signing certificate ----------------------------------------------------
#
# Generated once and kept, so the certificate a deployment signs with does not
# change under it on the next redeploy. Regenerated only if the stored file
# cannot be opened with the configured passphrase.

cert_usable() {
  [ -s "$CERT_PATH" ] || return 1
  openssl pkcs12 -in "$CERT_PATH" -nodes -passin env:NEXT_PRIVATE_SIGNING_PASSPHRASE \
    >/dev/null 2>&1
}

if cert_usable; then
  log "signing certificate present and opens with the configured passphrase"
else
  if [ -s "$CERT_PATH" ]; then
    log "stored signing certificate does not open with the current passphrase; regenerating"
    mv "$CERT_PATH" "$CERT_PATH.$(date +%s).bak"
  fi
  log "generating a signing certificate for this deployment"
  subject="${DOCUMENSO_CERT_SUBJECT:-/CN=${NEXT_PUBLIC_WEBAPP_URL:-Documenso}/O=Documenso Self-Hosted}"
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$DATA_DIR/cert.key" -out "$DATA_DIR/cert.crt" \
    -subj "$subject" >/dev/null 2>&1
  openssl pkcs12 -export -out "$CERT_PATH" \
    -inkey "$DATA_DIR/cert.key" -in "$DATA_DIR/cert.crt" \
    -passout env:NEXT_PRIVATE_SIGNING_PASSPHRASE >/dev/null 2>&1
  rm -f "$DATA_DIR/cert.key" "$DATA_DIR/cert.crt"
  chown "$APP_UID:$APP_GID" "$CERT_PATH"
  cert_usable || { log "FATAL: generated certificate does not open. Refusing to start."; exit 1; }
  log "signing certificate written to $CERT_PATH ($(stat -c %s "$CERT_PATH") bytes)"
fi

chown -R "$APP_UID:$APP_GID" "$DATA_DIR"

# --- migrations -------------------------------------------------------------

cd /app/apps/remix
log "running database migrations"
su-exec "$APP_UID:$APP_GID" \
  npx prisma migrate deploy --schema ../../packages/prisma/schema.prisma

# --- administrator account --------------------------------------------------
#
# Runs to completion BEFORE the server binds a port, so the first request the
# public URL ever serves is against an instance that already has an owner.

log "seeding the administrator account"
su-exec "$APP_UID:$APP_GID" \
  node /app/railway-seed-admin.mjs

# --- hand over --------------------------------------------------------------

log "starting Documenso on port ${PORT:-3000}"
exec su-exec "$APP_UID:$APP_GID" \
  node build/server/main.js
