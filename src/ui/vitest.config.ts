import { defineConfig } from 'vitest/config'
import react from '@vitejs/plugin-react'

// Component-layer test config (test layer 4a — see docs/TESTING.md).
//
// API calls are mocked at the network layer with MSW, never by stubbing
// modules, so tests exercise the real fetch path and catch serialisation
// mistakes that module stubbing would hide.
export default defineConfig({
  plugins: [react()],
  test: {
    environment: 'jsdom',
    globals: true,
    setupFiles: ['./src/test/setup.ts'],
    // Playwright specs live in e2e/ and are driven by playwright.config.ts.
    exclude: ['node_modules/**', 'dist/**', 'e2e/**'],
    coverage: {
      provider: 'v8',
      reporter: ['text', 'lcov'],
      include: ['src/**/*.{ts,tsx}'],
      exclude: [
        'src/main.tsx',
        'src/test/**',
        'src/**/*.test.{ts,tsx}',
        'src/types/**', // type-only declarations carry no statements
      ],
      // Nothing is excluded from the gate. The first block is the floor for
      // the whole UI; each path below it has its own floor at the level its
      // tests reach today, so no part can regress. Raise a number when tests
      // raise the coverage, never lower one. New and edited lines are held to
      // 85% separately by `make changed-lines-ui`.
      thresholds: {
        statements: 78,
        branches: 72,
        functions: 72,
        lines: 78,
        'src/api/**': { statements: 94, branches: 90, functions: 95, lines: 94 },
        'src/components/**': { statements: 86, branches: 85, functions: 88, lines: 86 },
        'src/hooks/**': { statements: 100, branches: 90, functions: 100, lines: 100 },
        'src/lib/**': { statements: 100, branches: 90, functions: 100, lines: 100 },
        'src/views/**': { statements: 76, branches: 64, functions: 66, lines: 76 },
        'src/App.tsx': { statements: 58, branches: 66, functions: 24, lines: 58 },
      },
    },
  },
})
