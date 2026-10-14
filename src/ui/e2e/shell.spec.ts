// SPDX-License-Identifier: Apache-2.0
//
// App-shell journeys: the UI mounts and shows what the API answered, survives
// a backend that is down, surfaces a server error, and never renders a blank
// page.

import { expect, problem, stubApi, test } from './fixtures'

test('mounts and renders the app shell', async ({ page }) => {
  await page.goto('/')
  await expect(page.locator('body')).not.toBeEmpty()
  // The nav is the shell's load-bearing element: if it renders, view selection
  // and the auth gate both resolved.
  await expect(page.getByRole('link', { name: /dashboard/i })).toBeVisible()
  // The dashboard shows what the status endpoint answered, not a placeholder.
  await expect(page.getByText('k3d-e2e').first()).toBeVisible()
})

test('renders without a reachable backend instead of blanking', async ({ page }) => {
  // Every API call fails at the transport layer, the way it does when the
  // server has been stopped.
  await page.route('**/api/**', (route) => route.abort('failed'))
  await page.goto('/')

  await expect(page.locator('body')).not.toBeEmpty()
  // No unhandled render crash: the error boundary must not have taken over.
  await expect(page.getByText(/this view crashed/i)).toHaveCount(0)
})

test('surfaces a server-side error without crashing the view', async ({ page }) => {
  await stubApi(page, { '/status': problem(500, 'cluster status unavailable') })
  await page.goto('/')
  await expect(page.locator('body')).not.toBeEmpty()
  await expect(page.getByText('cluster status unavailable').first()).toBeVisible()
  await expect(page.getByText(/this view crashed/i)).toHaveCount(0)
})

test('has no horizontal overflow at a narrow viewport', async ({ page }) => {
  await page.setViewportSize({ width: 375, height: 800 })
  await page.goto('/')
  const overflows = await page.evaluate(
    () => document.documentElement.scrollWidth > document.documentElement.clientWidth + 1,
  )
  expect(overflows).toBe(false)
})
