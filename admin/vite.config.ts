import react from '@vitejs/plugin-react';
import { defineConfig } from 'vite';

// In development the dashboard proxies /v1 to the API so no CORS setup is needed.
export default defineConfig({
  plugins: [react()],
  server: { port: 5173, proxy: { '/v1': process.env.STREAMERO_API ?? 'http://localhost:8080' } },
  build: { sourcemap: false, chunkSizeWarningLimit: 800 },
  test: { environment: 'jsdom', include: ['src/**/*.test.ts?(x)'] },
});
