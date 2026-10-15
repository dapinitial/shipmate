import { defineConfig } from 'vite';
// The app is loaded by the Even app's WebView (or the simulator) from this dev server.
export default defineConfig({ base: './', server: { port: 5173, strictPort: true } });
