/**
 * Seed (and re-apply) the administrator account.
 *
 * Documenso has no first-user-becomes-admin rule and ships no seeding CLI in
 * the production image: `roles Role[] @default([USER])` in the schema and no
 * code path anywhere that promotes anybody. A stock self-hosted deployment
 * therefore has an unreachable admin panel unless the operator edits Postgres
 * by hand, and an empty user table that the first visitor can sign up into.
 *
 * This runs from the entrypoint before the server binds a port. It is
 * idempotent and re-applies the password on every boot, so rotating the
 * Railway variable and redeploying is a working password reset -- Documenso's
 * own reset flow needs email delivery the deployer may not have configured.
 */
import { hash } from '@node-rs/bcrypt';

const BUILD = '/app/apps/remix/build/server/hono/packages';

const { prisma } = await import(`${BUILD}/prisma/index.js`);
const { createUser } = await import(`${BUILD}/lib/server-only/user/create-user.js`);

const email = (process.env.DOCUMENSO_ADMIN_EMAIL || '').toLowerCase().trim();
const password = process.env.DOCUMENSO_ADMIN_PASSWORD || '';
const name = process.env.DOCUMENSO_ADMIN_NAME || 'Administrator';

if (!email || !password) {
  console.error('[seed-admin] DOCUMENSO_ADMIN_EMAIL / DOCUMENSO_ADMIN_PASSWORD are required');
  process.exit(1);
}

const existing = await prisma.user.findFirst({ where: { email } });

if (!existing) {
  // createUser also runs onCreateUserHook, which creates the personal
  // organisation every account needs to be usable.
  await createUser({ name, email, password, signature: null });
  console.log(`[seed-admin] created ${email}`);
} else {
  console.log(`[seed-admin] ${email} already exists; re-applying password and role`);
}

const hashed = await hash(password, 12);

const user = await prisma.user.update({
  where: { email },
  data: {
    password: hashed,
    roles: ['ADMIN'],
    // Login is refused with "Unverified email" while emailVerified is null,
    // and the verification mail needs SMTP the deployer may not have.
    emailVerified: new Date(),
    disabled: false,
  },
  select: { id: true, email: true, roles: true, emailVerified: true },
});

console.log(
  `[seed-admin] ready: id=${user.id} roles=${user.roles.join(',')} verified=${Boolean(
    user.emailVerified,
  )}`,
);

await prisma.$disconnect();
