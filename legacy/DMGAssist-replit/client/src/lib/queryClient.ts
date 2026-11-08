/**
 * @module queryClient
 * @description Configures and exports the TanStack React Query client used across
 * the application. Provides a shared `apiRequest` helper for mutations and a
 * configurable default query function factory (`getQueryFn`) with 401-handling strategies.
 *
 * Default query behaviour:
 * - No automatic refetching (staleTime = Infinity, refetchOnWindowFocus = false)
 * - No retries on failure
 * - 401 responses throw by default; use `getQueryFn({ on401: "returnNull" })` to
 *   silently return `null` instead (useful for auth-check queries).
 */

import { QueryClient, QueryFunction } from "@tanstack/react-query";

/**
 * Inspects a `Response` and throws a descriptive `Error` if the status is not OK.
 * The error message follows the format `"<status>: <body|statusText>"` which is
 * consumed by {@link isUnauthorizedError} in `auth-utils.ts`.
 *
 * @param res - The fetch `Response` to validate.
 * @throws {Error} When `res.ok` is `false`.
 */
async function throwIfResNotOk(res: Response) {
  if (!res.ok) {
    const text = (await res.text()) || res.statusText;
    throw new Error(`${res.status}: ${text}`);
  }
}

/**
 * Generic helper for making authenticated JSON API requests (POST, PATCH, DELETE, etc.).
 * Automatically serialises `data` to JSON and sets the `Content-Type` header.
 * Credentials are always included for session cookie auth.
 *
 * @param method - HTTP method (e.g. `"POST"`, `"PATCH"`, `"DELETE"`).
 * @param url    - API endpoint path (e.g. `"/api/admin/sync"`).
 * @param data   - Optional request body; will be JSON-stringified when provided.
 * @returns The raw `Response` on success.
 * @throws {Error} On non-OK HTTP responses (via {@link throwIfResNotOk}).
 */
export async function apiRequest(
  method: string,
  url: string,
  data?: unknown | undefined,
): Promise<Response> {
  const res = await fetch(url, {
    method,
    headers: data ? { "Content-Type": "application/json" } : {},
    body: data ? JSON.stringify(data) : undefined,
    credentials: "include",
  });

  await throwIfResNotOk(res);
  return res;
}

/**
 * Strategy for handling HTTP 401 responses in query functions.
 * - `"returnNull"` — Silently returns `null` (used for optional auth checks).
 * - `"throw"` — Throws an error so React Query marks the query as failed.
 */
type UnauthorizedBehavior = "returnNull" | "throw";

/**
 * Factory that produces a React Query `queryFn` with configurable 401 handling.
 * The query key segments are joined with `"/"` and used as the fetch URL,
 * enabling the convention of `queryKey: ["/api/specs"]` matching the API path.
 *
 * @typeParam T - The expected JSON response type.
 * @param options.on401 - How to handle 401 responses.
 * @returns A `QueryFunction<T>` suitable for React Query's `queryFn` option.
 */
export const getQueryFn: <T>(options: {
  on401: UnauthorizedBehavior;
}) => QueryFunction<T> =
  ({ on401: unauthorizedBehavior }) =>
  async ({ queryKey }) => {
    const res = await fetch(queryKey.join("/") as string, {
      credentials: "include",
    });

    if (unauthorizedBehavior === "returnNull" && res.status === 401) {
      return null;
    }

    await throwIfResNotOk(res);
    return await res.json();
  };

/**
 * Singleton React Query client instance shared across the application.
 *
 * Configuration:
 * - Queries use `getQueryFn({ on401: "throw" })` by default.
 * - Infinite stale time prevents automatic background refetching; components
 *   that need polling (e.g. AdminDashboard) override `refetchInterval` locally.
 * - Retries are disabled globally to surface errors immediately.
 */
export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      queryFn: getQueryFn({ on401: "throw" }),
      refetchInterval: false,
      refetchOnWindowFocus: false,
      staleTime: Infinity,
      retry: false,
    },
    mutations: {
      retry: false,
    },
  },
});
