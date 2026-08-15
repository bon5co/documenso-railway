# Documenso for Railway.
#
# Thin wrapper over the official image. It adds nothing to the application and
# changes no application code -- it only supplies the three things a Railway
# deploy needs and the published listings do not provide: a signing
# certificate, an administrator account, and a deterministic NODE_ENV.
FROM documenso/documenso:v2.16.0

USER root

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
COPY railway-seed-admin.mjs /app/railway-seed-admin.mjs

RUN apk add --no-cache su-exec && chmod +x /usr/local/bin/railway-entrypoint.sh

# Where the per-deployment signing certificate lives. Railway mounts the volume
# here; nothing built into the image is stored under this path, so the mount
# does not hide anything.
ENV DOCUMENSO_DATA_DIR=/opt/documenso \
    NODE_ENV=production \
    NEXT_PRIVATE_SIGNING_TRANSPORT=local \
    NEXT_PRIVATE_SIGNING_LOCAL_FILE_PATH=/opt/documenso/cert.p12 \
    NEXT_PUBLIC_UPLOAD_TRANSPORT=database \
    NEXT_PUBLIC_DISABLE_SIGNUP=true \
    DOCUMENSO_DISABLE_TELEMETRY=true \
    DOCUMENSO_ADMIN_NAME=Administrator

EXPOSE 3000

ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
