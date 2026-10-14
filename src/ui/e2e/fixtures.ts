// SPDX-License-Identifier: Apache-2.0
//
// Shared Playwright fixtures.
//
// `stubApi` answers every /api/** request so journeys run without a backend.
// A request with no stub is answered 404 and recorded, and the journey then
// fails naming it: a page that calls an endpoint the fixtures do not know is a
// gap in the fixtures, not a passing test.

import { expect, test as base, type Page } from '@playwright/test'
import type {
  AuthStatus, Capacity, JobInfo, PlatformProvidersMap, Runtime, Scenario, StatusResponse,
} from '../src/types'

export type ApiStubs = Record<string, unknown | ((url: URL) => unknown)>

const API = '/api/v2'

/** Answers a stubbed path with this HTTP status and a problem+json body. */
export function problem(status: number, title = 'stubbed failure') {
  return { __status: status, title }
}

/** Baseline responses: a healthy single-node cluster with nothing installed.
 *  Each is checked against the type the client reads it as. */
export const defaultStubs: ApiStubs = {
  '/auth/me': { authEnabled: false, authenticated: true } satisfies AuthStatus,
  '/status': {
    cluster: {
      context: 'k3d-e2e', server: 'https://127.0.0.1:6443', k8sVersion: 'v1.33.0',
      nodeCount: 1, connected: true,
    },
    platform: {},
    apps: [],
    domainSuffix: 'localhost',
  } satisfies StatusResponse,
  '/capacity': { cpus: 4, memoryMiB: 8192, usedMiB: 2048, usableMiB: 6144 } satisfies Capacity,
  '/platform': {} satisfies PlatformProvidersMap,
  '/runtimes': [{ name: 'k3d', active: true, current: true }] satisfies Runtime[],
  '/jobs': [] satisfies JobInfo[],
  '/scenarios': { items: [] satisfies Scenario[] },
}

/**
 * Routes /api/** through the stub table (paths are relative to /api/v2) and
 * returns the list of requests no stub answered.
 */
export async function stubApi(page: Page, stubs: ApiStubs = {}): Promise<string[]> {
  const table = { ...defaultStubs, ...stubs }
  const unstubbed: string[] = []
  await page.route('**/api/**', async (route) => {
    const url = new URL(route.request().url())
    const path = url.pathname.startsWith(API) ? url.pathname.slice(API.length) : url.pathname
    if (!(path in table)) {
      unstubbed.push(`${route.request().method()} ${url.pathname}`)
      await route.fulfill({ status: 404, json: { title: `unstubbed: ${url.pathname}` } })
      return
    }
    const stub = table[path]
    const body = typeof stub === 'function' ? (stub as (u: URL) => unknown)(url) : stub
    const status = (body as { __status?: number } | null)?.__status
    if (status) {
      await route.fulfill({
        status,
        contentType: 'application/problem+json',
        json: { type: 'about:blank', title: (body as { title: string }).title, status },
      })
      return
    }
    await route.fulfill({ json: body })
  })
  return unstubbed
}

/**
 * `test` with the API stubbed to the healthy baseline before each journey, and
 * a failure after it for any request the stubs did not answer.
 */
export const test = base.extend<{ stubbed: void }>({
  stubbed: [
    async ({ page }, use) => {
      const unstubbed = await stubApi(page)
      await use()
      expect([...new Set(unstubbed)], 'API requests with no stub in e2e/fixtures.ts').toEqual([])
    },
    { auto: true },
  ],
})

export { expect } from '@playwright/test'
