/**
 * @module auth-utils
 * @description Shared authentication utility helpers used across client components.
 * Provides error detection for 401 responses and a standardised redirect-to-login flow
 * with optional toast feedback.
 */

/**
 * Tests whether an Error represents an HTTP 401 Unauthorized response.
 * The error message format is expected to follow the pattern produced by
 * {@link throwIfResNotOk} in `queryClient.ts`: `"401: …Unauthorized"`.
 *
 * @param error - The error to inspect.
 * @returns `true` if the error message matches the 401 Unauthorized pattern.
 */
export function isUnauthorizedError(error: Error): boolean {
  return /^401: .*Unauthorized/.test(error.message);
}

/**
 * Redirects the browser to the login endpoint after an optional toast notification.
 * A 500 ms delay is applied so the toast is visible before navigation occurs.
 *
 * @param toast - Optional toast function (from `useToast`) to display a feedback message
 *               before redirecting. When omitted the redirect happens silently.
 */
export function redirectToLogin(toast?: (options: { title: string; description: string; variant: string }) => void) {
  if (toast) {
    toast({
      title: "Unauthorized",
      description: "You are logged out. Logging in again...",
      variant: "destructive",
    });
  }
  setTimeout(() => {
    window.location.href = "/api/login";
  }, 500);
}
