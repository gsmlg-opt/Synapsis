import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import tailwindcss from "@tailwindcss/vite";

export default defineConfig({
  plugins: [react(), tailwindcss()],
  build: {
    outDir: "../synapsis_server/priv/static/assets",
    emptyOutDir: true,
    sourcemap: true,
  },
  server: {
    port: 3000,
    proxy: {
      "/api": "http://localhost:4000",
      "/socket": { target: "ws://localhost:4000", ws: true },
    },
  },
});
