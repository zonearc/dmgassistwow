/**
 * @module use-auth
 * @description Custom React hook for Replit-based authentication state management.
 * Fetches the current user session from `/api/auth/user` and provides a logout action.
 * Auth state is cached for 5 minutes via React Query's `staleTime` to minimise
 * redundant network requests.
 */

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query";
import type { User } from "@shared/models/auth";

/**
 * Fetches the authenticated user from the server session endpoint.
 * Returns `null` when the session is expired or absent (HTTP 401).
 *
 * @returns The current {@link User} object or `null` if unauthenticated.
 * @throws {Error} On non-401 HTTP errors (network failures, server errors).
 */
async function fetchUser(): Promise<User | null> {
  const response = await fetch("/api/auth/user", {
    credentials: "include",
  });

  if (response.status === 401) {
    return null;
  }

  if (!response.ok) {
    throw new Error(`${response.status}: ${response.statusText}`);
  }

  return response.json();
}

/**
 * Triggers a full-page redirect to the server logout endpoint.
 * The server clears the session cookie and redirects back to the landing page.
 */
async function logout(): Promise<void> {
  window.location.href = "/api/logout";
}

/**
 * Provides authentication state and actions to React components.
 *
 * @returns An object containing:
 * - `user` — The authenticated {@link User} or `undefined` while loading / `null` if unauthenticated.
 * - `isLoading` — `true` while the initial auth check is in-flight.
 * - `isAuthenticated` — Convenience boolean derived from `!!user`.
 * - `logout` — Function to trigger the logout flow (redirects to `/api/logout`).
 * - `isLoggingOut` — `true` while the logout mutation is pending.
 *
 * @example
 * ```tsx
 * const { user, isAuthenticated, logout } = useAuth();
 * if (!isAuthenticated) return <LoginPrompt />;
 * ```
 */
export function useAuth() {
  const queryClient = useQueryClient();
  const { data: user, isLoading } = useQuery<User | null>({
    queryKey: ["/api/auth/user"],
    queryFn: fetchUser,
    retry: false,
    staleTime: 1000 * 60 * 5, // 5 minutes
  });

  const logoutMutation = useMutation({
    mutationFn: logout,
    onSuccess: () => {
      queryClient.setQueryData(["/api/auth/user"], null);
    },
  });

  return {
    user,
    isLoading,
    isAuthenticated: !!user,
    logout: logoutMutation.mutate,
    isLoggingOut: logoutMutation.isPending,
  };
}
