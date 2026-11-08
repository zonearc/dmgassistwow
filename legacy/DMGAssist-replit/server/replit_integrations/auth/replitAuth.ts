/**
 * @module server/replit_integrations/auth/replitAuth
 *
 * Replit OpenID Connect (OIDC) authentication integration.
 *
 * Implements the full OIDC authorization-code flow via Passport.js:
 *  - Discovery of the Replit OIDC provider configuration (memoised for 1 hour)
 *  - Session management backed by PostgreSQL (`connect-pg-simple`)
 *  - Dynamic Passport strategy registration per hostname (supports custom domains)
 *  - Token refresh when the access token has expired
 *  - User upsert into the application database on each login
 *
 * Exposed routes:
 *  - `GET /api/login`    — Initiates the OIDC login flow
 *  - `GET /api/callback` — Handles the OIDC provider redirect
 *  - `GET /api/logout`   — Logs the user out and redirects to the provider's end-session endpoint
 */

import * as client from "openid-client";
import { Strategy, type VerifyFunction } from "openid-client/passport";

import passport from "passport";
import session from "express-session";
import type { Express, RequestHandler } from "express";
import memoize from "memoizee";
import connectPg from "connect-pg-simple";
import { authStorage } from "./storage";

/**
 * Fetches and caches the OIDC provider configuration from the Replit issuer.
 *
 * The result is memoised for one hour to avoid redundant network calls
 * on every authentication attempt.
 *
 * @returns The OpenID Connect server configuration and client metadata.
 */
const getOidcConfig = memoize(
  async () => {
    return await client.discovery(
      new URL(process.env.ISSUER_URL ?? "https://replit.com/oidc"),
      process.env.REPL_ID!
    );
  },
  { maxAge: 3600 * 1000 }
);

/**
 * Creates and returns the Express session middleware.
 *
 * Sessions are stored in PostgreSQL via `connect-pg-simple` with a
 * one-week TTL.  Cookies are set as HTTP-only and secure.
 *
 * @returns Configured `express-session` middleware.
 */
export function getSession(): ReturnType<typeof session> {
  const sessionTtl = 7 * 24 * 60 * 60 * 1000; // 1 week
  const pgStore = connectPg(session);
  const sessionStore = new pgStore({
    conString: process.env.DATABASE_URL,
    createTableIfMissing: false,
    ttl: sessionTtl,
    tableName: "sessions",
  });
  return session({
    secret: process.env.SESSION_SECRET!,
    store: sessionStore,
    resave: false,
    saveUninitialized: false,
    cookie: {
      httpOnly: true,
      secure: true,
      maxAge: sessionTtl,
    },
  });
}

/**
 * Hydrates the in-memory user object with token data from the OIDC provider.
 *
 * Called after initial login and after a successful token refresh to keep
 * the session's token state up to date.
 *
 * @param user   - The session user object to mutate.
 * @param tokens - Token endpoint response containing claims and tokens.
 */
function updateUserSession(
  user: any,
  tokens: client.TokenEndpointResponse & client.TokenEndpointResponseHelpers
): void {
  user.claims = tokens.claims();
  user.access_token = tokens.access_token;
  user.refresh_token = tokens.refresh_token;
  user.expires_at = user.claims?.exp;
}

/**
 * Persists or updates the user record in the application database.
 *
 * Extracts standard OIDC claims and delegates to the auth storage layer.
 *
 * @param claims - Decoded ID-token claims from the OIDC provider.
 */
async function upsertUser(claims: any): Promise<void> {
  await authStorage.upsertUser({
    id: claims["sub"],
    email: claims["email"],
    firstName: claims["first_name"],
    lastName: claims["last_name"],
    profileImageUrl: claims["profile_image_url"],
  });
}

/**
 * Configures the Express application with OIDC-based authentication.
 *
 * Sets up session handling, Passport initialisation, and registers the
 * login / callback / logout routes. A per-hostname Passport strategy is
 * created lazily so that custom domains are supported without upfront
 * configuration.
 *
 * @param app - The Express application instance.
 */
export async function setupAuth(app: Express): Promise<void> {
  app.set("trust proxy", 1);
  app.use(getSession());
  app.use(passport.initialize());
  app.use(passport.session());

  const config = await getOidcConfig();

  /** Passport verify callback — updates session and upserts the user record. */
  const verify: VerifyFunction = async (
    tokens: client.TokenEndpointResponse & client.TokenEndpointResponseHelpers,
    verified: passport.AuthenticateCallback
  ) => {
    const user = {};
    updateUserSession(user, tokens);
    await upsertUser(tokens.claims());
    verified(null, user);
  };

  /** Set of strategy names already registered with Passport. */
  const registeredStrategies = new Set<string>();

  /**
   * Lazily registers a Passport OIDC strategy for the given hostname.
   *
   * This allows the same application to handle authentication across
   * multiple domains (e.g. `*.repl.co` and a custom domain) without
   * pre-registering every possible callback URL.
   *
   * @param domain - The hostname to create a strategy for.
   */
  const ensureStrategy = (domain: string): void => {
    const strategyName = `replitauth:${domain}`;
    if (!registeredStrategies.has(strategyName)) {
      const strategy = new Strategy(
        {
          name: strategyName,
          config,
          scope: "openid email profile offline_access",
          callbackURL: `https://${domain}/api/callback`,
        },
        verify
      );
      passport.use(strategy);
      registeredStrategies.add(strategyName);
    }
  };

  passport.serializeUser((user: Express.User, cb) => cb(null, user));
  passport.deserializeUser((user: Express.User, cb) => cb(null, user));

  /** Initiates the OIDC authorization-code flow with login + consent prompts. */
  app.get("/api/login", (req, res, next) => {
    const returnTo = req.query.returnTo as string;
    if (returnTo && req.session) {
      (req.session as any).returnTo = returnTo;
    }
    ensureStrategy(req.hostname);
    passport.authenticate(`replitauth:${req.hostname}`, {
      prompt: "login consent",
      scope: ["openid", "email", "profile", "offline_access"],
    })(req, res, next);
  });

  /** Handles the OIDC provider's redirect after user consent. */
  app.get("/api/callback", (req, res, next) => {
    ensureStrategy(req.hostname);
    const returnTo = (req.session as any)?.returnTo || "/";
    passport.authenticate(`replitauth:${req.hostname}`, {
      successReturnToOrRedirect: returnTo,
      failureRedirect: "/api/login",
    })(req, res, next);
  });

  /** Logs the user out and redirects to the OIDC end-session endpoint. */
  app.get("/api/logout", (req, res) => {
    req.logout(() => {
      res.redirect(
        client.buildEndSessionUrl(config, {
          client_id: process.env.REPL_ID!,
          post_logout_redirect_uri: `${req.protocol}://${req.hostname}`,
        }).href
      );
    });
  });
}

/**
 * Express middleware that ensures the request is authenticated.
 *
 * If the user's access token has expired but a refresh token is available,
 * the middleware transparently refreshes the token before allowing the
 * request to proceed.  Returns `401 Unauthorized` if the user is not
 * logged in or the refresh attempt fails.
 */
export const isAuthenticated: RequestHandler = async (req, res, next) => {
  const user = req.user as any;

  if (!req.isAuthenticated() || !user.expires_at) {
    return res.status(401).json({ message: "Unauthorized" });
  }

  const now = Math.floor(Date.now() / 1000);
  if (now <= user.expires_at) {
    return next();
  }

  const refreshToken = user.refresh_token;
  if (!refreshToken) {
    res.status(401).json({ message: "Unauthorized" });
    return;
  }

  try {
    const config = await getOidcConfig();
    const tokenResponse = await client.refreshTokenGrant(config, refreshToken);
    updateUserSession(user, tokenResponse);
    return next();
  } catch (error) {
    res.status(401).json({ message: "Unauthorized" });
    return;
  }
};
