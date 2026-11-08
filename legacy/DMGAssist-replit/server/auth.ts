/**
 * @module server/auth
 *
 * Authentication & authorisation facade. Re-exports the Replit OpenID Connect
 * authentication middleware and adds an admin-gating middleware that checks
 * the authenticated user's email against the `ADMIN_EMAILS` environment
 * variable (comma-separated list).
 *
 * Usage in route files:
 * ```ts
 * import { isAuthenticated, isAdmin } from "./auth";
 *
 * app.get("/api/protected", isAuthenticated, handler);
 * app.post("/api/admin-only", isAdmin, handler);
 * ```
 */

import type { Express, Request, Response, NextFunction } from "express";
import { setupAuth as setupReplitAuth, registerAuthRoutes, isAuthenticated } from "./replit_integrations/auth";

export { isAuthenticated };

/**
 * Normalised list of admin email addresses sourced from the `ADMIN_EMAILS`
 * environment variable. An empty array means every authenticated user is
 * treated as an admin (no email-based restriction).
 */
const ADMIN_EMAILS: string[] = (process.env.ADMIN_EMAILS || "")
  .split(",")
  .map((e) => e.trim().toLowerCase())
  .filter(Boolean);

/**
 * Initialises authentication on the Express application.
 *
 * Delegates to the Replit OIDC integration which sets up session handling,
 * Passport strategies, and the `/api/login`, `/api/callback`, `/api/logout`
 * routes.  Also registers the `/api/auth/user` introspection endpoint.
 *
 * @param app - The Express application instance.
 */
export async function setupAuth(app: Express): Promise<void> {
  await setupReplitAuth(app);
  registerAuthRoutes(app);
}

/**
 * Express middleware that enforces admin-level access.
 *
 * First verifies the request is authenticated (delegates to `isAuthenticated`),
 * then checks the user's email against `ADMIN_EMAILS`. If the list is
 * non-empty and the user's email is not included, responds with `403 Forbidden`.
 *
 * @param req  - Express request object (must contain `user.claims` after auth).
 * @param res  - Express response object.
 * @param next - Express next function.
 */
export function isAdmin(req: Request, res: Response, next: NextFunction): void {
  isAuthenticated(req, res, (err?: any) => {
    if (err) return next(err);
    if (res.headersSent) return;

    const user = (req as any).user;
    if (!user?.claims?.sub) {
      return res.status(401).json({ message: "Unauthorized" });
    }

    if (ADMIN_EMAILS.length > 0) {
      const email = (user.claims.email || "").toLowerCase();
      if (!ADMIN_EMAILS.includes(email)) {
        return res.status(403).json({ message: "Forbidden — not an admin" });
      }
    }

    next();
  });
}
