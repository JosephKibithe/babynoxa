import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  server: { port: 4173 },
  preview: { port: 4173 },
  test: { environment: "jsdom", setupFiles: "./test/setup.ts", css: true, include:["test/**/*.test.{ts,tsx}"] },
});
