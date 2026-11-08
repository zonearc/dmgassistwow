/**
 * @module shared/models/auth
 *
 * Drizzle ORM table definitions for Replit Auth integration.
 *
 * Defines the two PostgreSQL tables required by the Replit Auth middleware:
 * - `sessions` — server-side session storage used by `connect-pg-simple`.
 * - `users`    — user profile records upserted on first login via Replit OAuth.
 *
 * These tables are the **only** Drizzle-managed tables in the project; all other
 * domain data (APL entries, HUD configs, profiles, etc.) is persisted as JSON
 * files on disk by {@link server/storage}.
 *
 * **Important:** Both tables are mandatory for Replit Auth to function. Do not
 * drop or rename them without updating the auth middleware accordingly.
 */

import { sql } from "drizzle-orm";
import { boolean, index, integer, jsonb, pgTable, text, timestamp, varchar } from "drizzle-orm/pg-core";

/**
 * Server-side session storage table for `express-session` with `connect-pg-simple`.
 *
 * Each row represents an active user session. The session middleware handles
 * insert/update/delete operations automatically; application code should not
 * write to this table directly.
 *
 * @property sid    - Session ID string, used as the primary key and cookie value.
 * @property sess   - JSON blob containing the serialised session data (user info, CSRF tokens, etc.).
 * @property expire - Timestamp after which the session is considered expired;
 *                    `connect-pg-simple` periodically prunes expired rows.
 */
export const sessions = pgTable(
  "sessions",
  {
    sid: varchar("sid").primaryKey(),
    sess: jsonb("sess").notNull(),
    expire: timestamp("expire").notNull(),
  },
  (table) => [index("IDX_session_expire").on(table.expire)]
);

/**
 * User profile table populated by the Replit Auth OAuth callback.
 *
 * A row is upserted on every login, ensuring profile data stays current with
 * the user's Replit account. The `id` defaults to a random UUID if not
 * provided by the auth flow.
 *
 * @property id              - Primary key, defaults to `gen_random_uuid()`.
 * @property email           - Unique email address from Replit profile (nullable).
 * @property firstName       - User's first name (nullable).
 * @property lastName        - User's last name (nullable).
 * @property profileImageUrl - URL to the user's Replit avatar image (nullable).
 * @property createdAt       - Row creation timestamp, set automatically.
 * @property updatedAt       - Last-update timestamp, set automatically on insert
 *                             (application code should update this on profile changes).
 */
export const users = pgTable("users", {
  id: varchar("id").primaryKey().default(sql`gen_random_uuid()`),
  email: varchar("email").unique(),
  firstName: varchar("first_name"),
  lastName: varchar("last_name"),
  profileImageUrl: varchar("profile_image_url"),
  createdAt: timestamp("created_at").defaultNow(),
  updatedAt: timestamp("updated_at").defaultNow(),
});

/**
 * Insert/upsert type for the `users` table.
 * Inferred from the Drizzle table definition; includes all columns with
 * optional auto-defaulted fields (`id`, `createdAt`, `updatedAt`).
 */
export type UpsertUser = typeof users.$inferInsert;

/**
 * Select (read) type for the `users` table.
 * Represents a fully hydrated user row as returned by queries.
 */
export type User = typeof users.$inferSelect;

export const syncKv = pgTable("sync_kv", {
  key: varchar("key").primaryKey(),
  value: text("value").notNull(),
});

export const syncRuns = pgTable("sync_runs", {
  id: varchar("id").primaryKey(),
  startedAt: varchar("started_at").notNull(),
  completedAt: varchar("completed_at"),
  status: varchar("status", { length: 20 }).notNull(),
  simcSpecs: integer("simc_specs").notNull().default(0),
  fallbackSpecs: integer("fallback_specs").notNull().default(0),
  addonVersion: varchar("addon_version").notNull(),
  curseforgeUploaded: boolean("curseforge_uploaded").notNull().default(false),
  error: text("error"),
  triggeredBy: varchar("triggered_by", { length: 20 }).notNull(),
}, (table) => [index("IDX_sync_runs_started").on(table.startedAt)]);
