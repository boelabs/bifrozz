import { drizzle } from "drizzle-orm/postgres-js";
import { env } from "#config/env.ts";
import postgres from "postgres";

/**
 * Does the URL request TLS? (sslmode=require|verify-*|prefer). Some hosts (e.g. Coolify) expose
 * Postgres with self-signed certificates whose SAN does not include the IP, so we use postgres-js's
 * `ssl: "require"`: it encrypts but does not verify the certificate. On an internal network (no
 * sslmode) the connection is plaintext.
 *
 * The explicit option matters: left to the URL, postgres-js reads `sslmode=verify-full` as verified
 * TLS, which Bun rejects against those certificates. SCRAM channel binding (`channel_binding`
 * defaults to `prefer`) works over the unverified connection — it hashes whatever certificate the
 * server presented. Adding `channel_binding=require` to the URL refuses to authenticate without it,
 * which is what stops a man in the middle when the certificate itself is not verified; it is left to
 * the URL because servers without TLS or SCRAM (and poolers such as PgBouncer) cannot offer it.
 */
const wantsSsl = /sslmode=(require|verify-full|verify-ca|prefer)/i.test(
	env.DATABASE_URL,
);

export const sql = postgres(env.DATABASE_URL, {
	max: env.DATABASE_POOL_MAX,
	onnotice: () => {
		/* intentionally empty */
	},
	ssl: wantsSsl ? "require" : false,
});

export const db = drizzle(sql);

/** Health ping: SELECT 1. */
export async function pingDb(): Promise<boolean> {
	try {
		await sql`select 1`;
		return true;
	} catch {
		return false;
	}
}

export async function closeDb(timeoutSeconds = 5): Promise<void> {
	await sql.end({ timeout: timeoutSeconds });
}
