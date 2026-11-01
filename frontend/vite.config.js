import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Dev only: forward /api to Django so the browser sees one origin (no CORS).
export default defineConfig({
  plugins: [react()],
  server: { proxy: { "/api": process.env.API_PROXY || "http://localhost:8000" } },
});
