# CLAUDE.md

Vue 3 + TypeScript frontend for the IDEKube container gateway. Displays available container services (VNC, Code Server, Jupyter, SSH, Agent, Terminal) on a landing page and handles token-based authentication on a 401 page.

## Tech Stack

- Vue 3.5 with Composition API (`<script setup>`)
- TypeScript 5.7 (strict mode)
- Vite 6.2 (dev server and bundler)
- No runtime dependencies beyond Vue 3

## Commands

```bash
npm install          # install dependencies
npm run dev          # start Vite dev server
npm run build        # type-check (vue-tsc) then build to dist/
npm run preview      # preview production build locally
make build           # incremental build (npm ci + npm run build, stamp-based)
make clean           # remove dist/ and node_modules/
```

## Project Structure

```
index.html              # Landing page entry HTML
401.html                # Auth page entry HTML
src/
  landing/              # Landing page SPA (main.ts + App.vue)
  auth/                 # Auth page SPA (main.ts + App.vue)
  components/           # Shared Vue components
    ControlButtons.vue  #   Theme/language toggle buttons (top-right)
    ServiceList.vue     #   Service grid with loading state
    ServiceCard.vue     #   Individual service link/action card
    TokenForm.vue       #   Access token input form
  composables/          # Reusable composition functions
    useServiceDetection.ts  # Polls /health, falls back to HTTP/WS probes
    useTheme.ts             # Dark/light theme with localStorage persistence
    useLanguage.ts          # English/Chinese i18n toggle
    useNewTab.ts            # ?newtab=true query param handling
  config/
    services.ts         # Service registry (path, icon, detection method)
    translations.ts     # i18n strings for landing and auth pages
  styles/
    variables.css       # CSS custom properties (light + dark themes)
    base.css            # Global reset and body styles
vite.config.ts          # Dual entry points: index.html + 401.html
tsconfig.json           # TypeScript config (ES2020, strict, bundler resolution)
Makefile                # Build automation with stamp-based incremental builds
```

## Architecture

- **Dual SPA**: Two independent Vue apps share components/composables but have separate entry points. Vite builds both via `rollupOptions.input`.
- **Service detection**: `useServiceDetection` first tries `GET /health` with a 5-second timeout (returns a JSON map of services with health status). Unhealthy services stay visible as disabled cards. On failure, it falls back to parallel HTTP/WebSocket probes against each service path. Polls every 10 seconds until `/health` reports every service healthy.
- **Auth flow**: When nginx returns 401, the user is served `401.html`. The token form submits the token as `?idekube-container-access-token=<token>` query parameter. Nginx validates via `auth_request`. On invalid token, the query param persists and `TokenForm` detects it to show an error.
- **SSH special case**: The SSH service card copies an SSH ProxyCommand (using `websocat`) to the clipboard instead of navigating.
- **Theming**: CSS custom properties in `variables.css` toggled via `data-theme` attribute on `<html>`. Persisted to localStorage, defaults to system preference.
- **i18n**: Chinese default. Language state shared via module-level `ref` in `useLanguage`. Persisted to localStorage.

## Conventions

- All components use `<script setup lang="ts">` with no Options API
- Composables use module-level `ref` for singleton state sharing across components
- No Vue Router or Vuex/Pinia -- minimal dependency footprint
- CSS is scoped per component; global theming via CSS custom properties
- Service definitions live in `src/config/services.ts`; translations in `src/config/translations.ts`
- TypeScript strict mode with `noUnusedLocals` and `noUnusedParameters` enabled
