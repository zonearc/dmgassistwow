/**
 * @module server/db
 *
 * Database connection module. Creates a PostgreSQL connection pool using the
 * `DATABASE_URL` environment variable and exports a Drizzle ORM instance
 * for type-safe query building throughout the server layer.
 *
 * This is the single source of truth for database access — all storage
 * operations should go through the exported `db` object rather than
 * creating additional pools.
 */

import { drizzle } from "drizzle-orm/node-postgres";
import pg from "pg";

/** Shared PostgreSQL connection pool backed by `DATABASE_URL`. */
const pool = new pg.Pool({
  connectionString: process.env.DATABASE_URL,
});

/**
 * Drizzle ORM database instance.
 *
 * Provides type-safe SQL query building and execution against the
 * PostgreSQL database. Used by the storage layer (`server/storage.ts`)
 * and auth storage (`server/replit_integrations/auth/storage.ts`).
 */
export const db = drizzle(pool);
