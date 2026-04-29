# IDEKube Container Frontend

Web UI for the IDEKube container gateway. Provides a landing page that auto-detects and displays available container services, and an authentication page for token-based access control.

## Features

- Landing page with auto-detected service cards (VNC, Code Server, Jupyter, SSH, Agent, Terminal)
- Token-based authentication page (served on 401 responses)
- Service health detection via `/health` endpoint with fallback HTTP/WebSocket probes
- Dark and light theme with system preference detection
- Internationalization (English and Chinese)
- SSH ProxyCommand clipboard copy
- Responsive design for mobile and desktop
- Zero runtime dependencies beyond Vue 3

## Prerequisites

- Node.js (with npm)
- GNU Make (optional, for `make build`)

## Quick Start

```bash
# Install dependencies
npm install

# Start development server
npm run dev

# Build for production
npm run build

# Preview production build
npm run preview
```

Alternatively, use Make for incremental builds:

```bash
make build    # runs npm ci + npm run build (stamp-based, skips if up to date)
make clean    # removes dist/ and node_modules/
```

## Project Structure

```
index.html                    Landing page HTML shell
401.html                      Auth page HTML shell
vite.config.ts                Vite config with dual entry points
tsconfig.json                 TypeScript configuration
Makefile                      Build automation
package.json                  Dependencies and scripts

src/
  landing/                    Landing page SPA
    main.ts                     App bootstrap
    App.vue                     Root component (logo, subtitle, service list)
  auth/                       Auth page SPA
    main.ts                     App bootstrap
    App.vue                     Root component (lock icon, token form)
  components/
    ControlButtons.vue          Theme and language toggle buttons
    ServiceList.vue             Service grid with loading/empty states
    ServiceCard.vue             Service link card with status indicator
    TokenForm.vue               Access token input and submission
  composables/
    useServiceDetection.ts      Service availability polling
    useTheme.ts                 Dark/light theme management
    useLanguage.ts              Language toggle (en/zh)
    useNewTab.ts                New-tab link behavior from query param
  config/
    services.ts                 Service registry definitions
    translations.ts             i18n string tables
  styles/
    variables.css               CSS custom properties for theming
    base.css                    Global reset and layout
```

## Architecture

### Dual Entry Points

The application is built as two independent single-page applications sharing the same component and composable libraries:

- **`index.html`** -- Landing page that displays detected services
- **`401.html`** -- Authentication page shown when nginx returns a 401 status

Vite builds both entry points via `rollupOptions.input` in `vite.config.ts`. The output goes to `dist/`.

### Service Detection

The `useServiceDetection` composable handles automatic service discovery:

1. **Primary method**: Fetches `GET /health`, which returns a JSON response containing a map of services and their health status. Healthy services are displayed on the landing page.
2. **Fallback method**: If `/health` is unavailable, the composable probes each service individually using HTTP `GET` requests or WebSocket connection attempts, depending on the service type.
3. **Polling**: Detection runs immediately on mount and repeats every 10 seconds.

Each service is defined in `src/config/services.ts` with a path, icon, and detection method (`http` or `websocket`).

### Authentication Flow

The auth flow is managed by nginx and the frontend together:

1. Nginx intercepts requests and validates access via `auth_request`.
2. On a 401 response, nginx serves `401.html` (the auth SPA).
3. The user enters a token in `TokenForm.vue`.
4. The form redirects to the current URL with `?idekube-container-access-token=<token>` appended.
5. Nginx validates the token. On success, the user reaches the landing page. On failure, the 401 page is served again with the query param intact.
6. `TokenForm` detects the lingering query param on mount and displays an "invalid token" error, then cleans the URL via `history.replaceState`.

### SSH ProxyCommand Copy

The SSH service card does not navigate to a URL. Instead, clicking it copies an SSH ProxyCommand configuration to the clipboard:

```
Host <hostname>
    ProxyCommand websocat --binary wss://<host>/ssh/
    User idekube
```

This uses the Clipboard API with a `document.execCommand('copy')` fallback for non-secure contexts.

## Configuration

### Services

Services are defined in `src/config/services.ts`:

| Path       | Description                | Detection Method |
|------------|----------------------------|------------------|
| `vnc`      | Remote desktop via noVNC   | HTTP             |
| `coder`    | VS Code in the browser     | HTTP             |
| `jupyter`  | Jupyter Lab notebooks      | HTTP             |
| `ssh`      | SSH terminal (copy action) | WebSocket        |
| `agent`    | Agent gateway API and UI   | HTTP             |
| `terminal` | Browser-based terminal     | HTTP             |

To add a new service, add an entry to the `serviceConfigs` array in `services.ts` and corresponding translations in `translations.ts`.

### Theming

Themes are controlled via CSS custom properties defined in `src/styles/variables.css`. The `data-theme` attribute on the root `<html>` element switches between `light` and `dark` variable sets. Theme preference is persisted to `localStorage` and defaults to the user's system preference.

### Internationalization

Two languages are supported: English (`en`) and Chinese (`zh`). Chinese is the default. All user-facing strings are defined in `src/config/translations.ts`. Language preference is persisted to `localStorage`.

### New Tab Behavior

Append `?newtab=true` to the landing page URL to make service links open in a new browser tab instead of navigating in the current tab.

## Build and Deployment

### Production Build

```bash
npm run build
```

This runs `vue-tsc --noEmit` for type checking followed by `vite build`. Output is written to `dist/` with the following structure:

```
dist/
  index.html          Landing page
  401.html            Auth page
  assets/             JS and CSS bundles
```

### Deployment

The `dist/` directory contains static files intended to be served by nginx as part of the IDEKube container gateway. Nginx handles:

- Serving `index.html` as the default page
- Serving `401.html` on authentication failures (via `error_page 401`)
- Reverse-proxying service paths (`/vnc/`, `/coder/`, `/jupyter/`, etc.) to backend services
- Token validation via `auth_request`
