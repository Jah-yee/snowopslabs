import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { defineConfig, devices } from '@playwright/test'

// Journey-layer test config (test layer 4b — see docs/TESTING.md).
//
// Playwright drives a real browser in two projects. `chromium` runs against
// the built SPA served by `vite preview`, with backend responses stubbed by
// page.route() (e2e/fixtures.ts). `real` runs against the real labctl binary
// over the fixture lab (e2e/real/start-lab.sh), with nothing stubbed.
//
// Browser resolution: normally Playwright's own managed download. Environments
// that ship a browser (CI images, dev containers, air-gapped builds) can point
// at it with PLAYWRIGHT_CHROMIUM_EXECUTABLE instead of downloading a second
// copy. Unset, behaviour is stock Playwright.
const PORT = Number(process.env.PLAYWRIGHT_PORT ?? 4173)
// The real labctl server the `real` project's journeys run against.
const REAL_PORT = Number(process.env.PLAYWRIGHT_REAL_PORT ?? 4174)
// The same server with sign-in required, for the `real-auth` project.
const AUTH_PORT = Number(process.env.PLAYWRIGHT_AUTH_PORT ?? 4175)
const chromiumPath = process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE
// While this file exists the real server's fixture fault inject waits, so a
// journey can watch, drop and cancel a run in flight.
process.env.E2E_HOLD ??= join(tmpdir(), `labctl-e2e-hold-${REAL_PORT}`)

export default defineConfig({
  testDir: './e2e',
  // A journey that hangs is a failure, not something to wait out.
  timeout: 30_000,
  expect: { timeout: 5_000 },
  fullyParallel: true,
  // A test that only passes on a retry is flaky; fail the build instead of
  // hiding it. CI forbids .only sneaking in.
  retries: 0,
  forbidOnly: !!process.env.CI,
  reporter: process.env.CI ? [['list'], ['html', { open: 'never' }]] : 'list',
  use: {
    baseURL: `http://127.0.0.1:${PORT}`,
    trace: 'retain-on-failure',
    screenshot: 'only-on-failure',
  },
  projects: [
    {
      // The real binary over the fixture lab, with nothing stubbed in the
      // browser. Its server keeps state, so its tests run one at a time, and
      // so do the repeats of --repeat-each.
      name: 'real',
      testDir: './e2e/real',
      fullyParallel: false,
      workers: 1,
      use: {
        ...devices['Desktop Chrome'],
        baseURL: `http://127.0.0.1:${REAL_PORT}`,
        ...(chromiumPath
          ? { launchOptions: { executablePath: chromiumPath, args: ['--no-sandbox', '--disable-dev-shm-usage'] } }
          : {}),
      },
    },
    {
      name: 'real-auth',
      testDir: './e2e/real-auth',
      fullyParallel: false,
      workers: 1,
      use: {
        ...devices['Desktop Chrome'],
        baseURL: `http://127.0.0.1:${AUTH_PORT}`,
        ...(chromiumPath
          ? { launchOptions: { executablePath: chromiumPath, args: ['--no-sandbox', '--disable-dev-shm-usage'] } }
          : {}),
      },
    },
    {
      name: 'chromium',
      testIgnore: /e2e\/real(-auth)?\//,
      use: {
        ...devices['Desktop Chrome'],
        ...(chromiumPath
          ? {
              launchOptions: {
                executablePath: chromiumPath,
                // Containers commonly run as root, where the sandbox refuses
                // to start. Only relaxed for a supplied browser, never for a
                // developer's stock install.
                args: ['--no-sandbox', '--disable-dev-shm-usage'],
              },
            }
          : {}),
      },
    },
  ],
  webServer: [{
    // Bind the preview to 127.0.0.1 explicitly. Left to its default host,
    // `vite preview` binds `localhost`, which on macOS resolves to IPv6 `::1`
    // only — while `url`/`baseURL` below reach for IPv4 `127.0.0.1`, so the
    // health check never connects and the run times out. Pinning the host to
    // 127.0.0.1 keeps server and client on the same address on macOS and Linux
    // alike (golden rule 1).
    command: `npm run build && npx vite preview --port ${PORT} --strictPort --host 127.0.0.1`,
    url: `http://127.0.0.1:${PORT}`,
    reuseExistingServer: !process.env.CI,
    timeout: 120_000,
  }, {
    // The SPA it serves is the one the first server built. The health check
    // is an API route, so the journeys start only once the server answers.
    command: `E2E_HOLD=${process.env.E2E_HOLD} sh e2e/real/start-lab.sh ${REAL_PORT}`,
    url: `http://127.0.0.1:${REAL_PORT}/api/v2/auth/me`,
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
    // SIGTERM, not the default SIGKILL, so start-lab.sh removes its lab copy.
    gracefulShutdown: { signal: 'SIGTERM', timeout: 5_000 },
  }, {
    // Only the real project's lab answers to the hold file.
    command: `E2E_HOLD= LAB_AUTH=on sh e2e/real/start-lab.sh ${AUTH_PORT}`,
    url: `http://127.0.0.1:${AUTH_PORT}/api/v2/auth/me`,
    reuseExistingServer: !process.env.CI,
    timeout: 180_000,
    gracefulShutdown: { signal: 'SIGTERM', timeout: 5_000 },
  }],
})
