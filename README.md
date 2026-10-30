# documenso-railway

[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/deploy/documenso-or-just-updated-docusign-alter?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

**Deploy on Railway:** [Documenso template](https://railway.com/deploy/documenso-or-just-updated-docusign-alter?referralCode=Z1xivh&utm_medium=integration&utm_source=template&utm_campaign=generic)

A thin wrapper over the official [Documenso](https://github.com/documenso/documenso) image
(`documenso/documenso:v2.16.0`) that makes a one-click Railway deploy actually usable.

Published image: `ghcr.io/bon5co/documenso-railway:2.16.0`

No application code is changed. The wrapper only supplies the things a Railway deployment needs
and that the templates on the marketplace do not provide.

## What it adds

### 1. A signing certificate, generated per deployment

Documenso seals signed PDFs with a PKCS#12 certificate. `packages/signing/transports/local.js`
resolves it like this:

```js
if (localFileContents) return Buffer.from(localFileContents, 'base64');
if (localFilePath) return fs.readFileSync(localFilePath);
if (env('NODE_ENV') !== 'production') return fs.readFileSync('./example/cert.p12');
throw new Error('No certificate found for local signing');
```

The published image ships **no** `example/cert.p12` and sets **no** `NODE_ENV`, so with none of
the signing variables set the signer throws
`ENOENT: no such file or directory, open './example/cert.p12'`.

Meanwhile `/api/certificate-status` returns `{"isAvailable":true}` and `/api/health` returns
`{"status":"ok", ... "certificate":{"status":"ok"}}` — those two endpoints call a *different*
`getCertificateStatus()` helper, which resolves the default path independently. The boot banner
prints `⚠️ Certificate not found or not readable` and then points the operator at the status
endpoint that disagrees with it.

The entrypoint generates a self-signed certificate with `openssl` on first boot, stores it on the
volume, and keeps it across redeploys so the certificate a deployment signs with does not change
underneath it. `NODE_ENV` is pinned to `production` and
`NEXT_PRIVATE_SIGNING_LOCAL_FILE_PATH` is set explicitly, so the status endpoints and the signer
resolve the same file.

Note on the alternative: baking a `.p12` into a template variable publishes one private key for
everybody who deploys it, and if the passphrase is a per-deploy random value the file cannot be
opened at all (`Failed to parse PKCS#12 file: Integrity for the PKCS#12 data is broken!`).

### 2. An administrator account, seeded before the server binds

`schema.prisma` declares `roles Role[] @default([USER])` and nothing in the application promotes
anybody: there is no first-user-becomes-admin rule, and the production image ships no seeding
script (`seed-database.ts` is not present). A stock deployment therefore has an admin area no
account can reach, and — until somebody signs up — an empty user table that the first visitor to
the public URL can claim.

`railway-seed-admin.mjs` runs from the entrypoint, before `node build/server/main.js` binds a
port. It calls Documenso's own `createUser()` (so the personal organisation every account needs
is created by upstream code), then sets `roles: ['ADMIN']` and `emailVerified`, which login
requires — `email-password.js` refuses an unverified account with `Unverified email`, and the
verification mail needs SMTP a deployer may not have configured.

It is idempotent and re-applies the password on **every** boot, so changing the Railway variable
and redeploying is a working password reset. Documenso's own reset flow needs email delivery.

The container refuses to start when `DOCUMENSO_ADMIN_PASSWORD`, `DOCUMENSO_ADMIN_EMAIL` or
`NEXT_PRIVATE_SIGNING_PASSPHRASE` is empty. Signup is disabled by default
(`NEXT_PUBLIC_DISABLE_SIGNUP=true`).

### 3. Volume ownership

Railway mounts volumes owned by uid 0 while the image runs as uid 1001 (`nodejs`). The entrypoint
runs as root, repairs the ownership of the data directory, and `su-exec`s down to 1001:65533 for
the migrations, the seed and the server.

## Environment

| Variable | Required | Notes |
|---|---|---|
| `NEXT_PRIVATE_DATABASE_URL` | yes | Postgres connection string. Also exported as `DATABASE_URL` for the prisma CLI. |
| `NEXT_PRIVATE_DIRECT_DATABASE_URL` | yes | Same value on Railway. |
| `NEXTAUTH_SECRET` | yes | Session signing key. |
| `NEXT_PRIVATE_ENCRYPTION_KEY` | yes | 32 characters. |
| `NEXT_PRIVATE_ENCRYPTION_SECONDARY_KEY` | yes | 32 characters. |
| `NEXT_PUBLIC_WEBAPP_URL` | yes | `https://<public domain>`. |
| `NEXT_PRIVATE_SIGNING_PASSPHRASE` | yes | Passphrase for the generated certificate. Keep it stable. |
| `DOCUMENSO_ADMIN_EMAIL` | yes | Seeded administrator. |
| `DOCUMENSO_ADMIN_PASSWORD` | yes | Re-applied on every boot. |
| `DOCUMENSO_ADMIN_NAME` | no | Defaults to `Administrator`. |
| `DOCUMENSO_DATA_DIR` | no | Defaults to `/opt/documenso`; mount the volume here. |
| `PORT` | injected | Honoured by `build/server/main.js`. |

Document bytes are stored in Postgres (`NEXT_PUBLIC_UPLOAD_TRANSPORT=database`), so the volume
holds only the signing certificate.

## Verified

Measured locally against `postgres:17-alpine`, and again on Railway:

- signer: `SIGNER OK P12Signer` here; `ENOENT ./example/cert.p12` on the leader's configuration;
  `Integrity for the PKCS#12 data is broken!` on a configuration that bakes a `.p12` and
  generates a random passphrase.
- certificate survives a container recreate on the same volume
  (`signing certificate present and opens with the configured passphrase`).
- password rotation on one database: new password `201`, previous password `500`
  (`INVALID_CREDENTIALS`).
- anonymous signup: `400 SIGNUP_DISABLED`.

## Licence

Documenso is licensed by its authors; this repository only contains the Railway packaging.
