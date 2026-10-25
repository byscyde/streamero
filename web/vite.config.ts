import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

// The web player is served at the site root. In development /v1 is proxied to the API (no CORS needed).
export default defineConfig({
  base: '/',
  plugins: [react()],
  server: { port: 5174, proxy: { '/v1': process.env.STREAMERO_API ?? 'http://localhost:8080' } },
  build: { sourcemap: false, chunkSizeWarningLimit: 900 },
  test: { environment: 'jsdom', include: ['src/**/*.test.ts?(x)'] },
});
