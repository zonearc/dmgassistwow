/**
 * @module server/index
 *
 * Application entry point. Bootstraps the Express server with:
 *  1. JSON / URL-encoded body parsing (with raw body capture for webhooks)
 *  2. API request logging middleware
 *  3. Application routes (auth, API, etc.)
 *  4. Global error handler
 *  5. Vite dev server (development) or static file serving (production)
 *
 * The server listens on the `PORT` environment variable (default 5000),
 * which is the only non-firewalled port on Replit. Both the API and the
 * client SPA are served from this single HTTP server instance.
 */

import express, { type Request, Response, NextFunction } from "express";
import { registerRoutes } from "./routes";
import { serveStatic } from "./static";
import { createServer } from "http";
import { startScheduler } from "./scheduler";

const app = express();
const httpServer = createServer(app);

declare module "http" {
  interface IncomingMessage {
    /** Raw request body buffer, captured during JSON parsing for webhook signature verification. */
    rawBody: unknown;
  }
}

app.use(
  express.json({
    verify: (req, _res, buf) => {
      req.rawBody = buf;
    },
  }),
);

app.use(express.urlencoded({ extended: false }));

/**
 * Logs a timestamped message to stdout.
 *
 * @param message - The message to log.
 * @param source  - Label for the log source (default: `"express"`).
 */
export function log(message: string, source = "express"): void {
  const formattedTime = new Date().toLocaleTimeString("en-US", {
    hour: "numeric",
    minute: "2-digit",
    second: "2-digit",
    hour12: true,
  });

  console.log(`${formattedTime} [${source}] ${message}`);
}

/**
 * Request-logging middleware.
 *
 * Intercepts `res.json()` to capture the response body, then logs
 * method, path, status code, duration, and (optionally) the JSON
 * response for every `/api` request on the `finish` event.
 */
app.use((req, res, next) => {
  const start = Date.now();
  const path = req.path;
  let capturedJsonResponse: Record<string, any> | undefined = undefined;

  const originalResJson = res.json;
  res.json = function (bodyJson, ...args) {
    capturedJsonResponse = bodyJson;
    return originalResJson.apply(res, [bodyJson, ...args]);
  };

  res.on("finish", () => {
    const duration = Date.now() - start;
    if (path.startsWith("/api")) {
      let logLine = `${req.method} ${path} ${res.statusCode} in ${duration}ms`;
      if (capturedJsonResponse) {
        logLine += ` :: ${JSON.stringify(capturedJsonResponse)}`;
      }

      log(logLine);
    }
  });

  next();
});

(async () => {
  await registerRoutes(httpServer, app);

  /**
   * Global error-handling middleware.
   *
   * Catches any errors thrown (or passed via `next(err)`) by route handlers
   * and returns a JSON error response. If headers have already been sent,
   * delegates to Express's default error handler to close the connection.
   */
  app.use((err: any, _req: Request, res: Response, next: NextFunction) => {
    const status = err.status || err.statusCode || 500;
    const message = err.message || "Internal Server Error";

    console.error("Internal Server Error:", err);

    if (res.headersSent) {
      return next(err);
    }

    return res.status(status).json({ message });
  });

  if (process.env.NODE_ENV === "production") {
    serveStatic(app);
  } else {
    const { setupVite } = await import("./vite");
    await setupVite(httpServer, app);
  }

  const port = parseInt(process.env.PORT || "5000", 10);
  httpServer.listen(
    {
      port,
      host: "0.0.0.0",
      reusePort: true,
    },
    () => {
      log(`serving on port ${port}`);
      startScheduler();
    },
  );
})();
