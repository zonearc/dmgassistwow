/**
 * @module main
 * @description Application entry point. Mounts the root React component into the DOM
 * and imports global CSS styles. Uses React 18's `createRoot` API for concurrent rendering.
 */

import { createRoot } from "react-dom/client";
import App from "./App";
import "./index.css";

createRoot(document.getElementById("root")!).render(<App />);
