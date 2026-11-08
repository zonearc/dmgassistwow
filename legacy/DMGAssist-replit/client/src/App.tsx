/**
 * @module App
 * @description Root application component. Sets up global providers (React Query, Tooltip)
 * and defines client-side routing via `wouter`.
 *
 * Routes:
 * - `/`      — Public landing page ({@link Dashboard})
 * - `/admin` — Protected admin panel ({@link AdminDashboard})
 */

import { queryClient } from "./lib/queryClient";
import { QueryClientProvider } from "@tanstack/react-query";
import { Toaster } from "@/components/ui/toaster";
import { TooltipProvider } from "@/components/ui/tooltip";
import { Switch, Route } from "wouter";
import Dashboard from "@/pages/Dashboard";
import AdminDashboard from "@/pages/AdminDashboard";
import CurseForgeDescription from "@/pages/CurseForgeDescription";
import PrioritySimulator from "@/pages/PrioritySimulator";

/**
 * Root component that wraps the entire application with required providers
 * and renders the client-side router.
 *
 * Provider hierarchy:
 * 1. `QueryClientProvider` — TanStack React Query for data fetching / caching
 * 2. `TooltipProvider` — Radix tooltip context for shadcn tooltips
 * 3. `Toaster` — Global toast notification outlet
 */
export default function App() {
  return (
    <QueryClientProvider client={queryClient}>
      <TooltipProvider>
        <Switch>
          <Route path="/" component={Dashboard} />
          <Route path="/admin" component={AdminDashboard} />
          <Route path="/admin/curseforge" component={CurseForgeDescription} />
          <Route path="/admin/sim" component={PrioritySimulator} />
        </Switch>
        <Toaster />
      </TooltipProvider>
    </QueryClientProvider>
  );
}
