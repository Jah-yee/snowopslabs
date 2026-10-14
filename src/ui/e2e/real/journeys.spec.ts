// SPDX-License-Identifier: Apache-2.0
//
// Journeys against the real labctl server.
//
// These drive a browser against the `labctl ui` that e2e/real/start-lab.sh
// starts: the real binary and the real SPA, over the fixture lab, with the
// stand-in kubectl, helm and docker on its PATH. Nothing is stubbed in the
// browser, so a journey passes only if the UI, the API and the scripts they
// run agree with each other. The server keeps its state between tests, so
// they run in order and each leaves the lab as it found it.
import { spawn, type ChildProcess } from 'node:child_process'
import { rmSync, writeFileSync } from 'node:fs'
import { createRequire } from 'node:module'
import { expect, test, type Page } from '@playwright/test'

/** axe-core's browser bundle, injected into each page that is scanned. It is
 *  the copy jest-axe depends on, so both accessibility layers run one engine. */
const require = createRequire(import.meta.url)
const axePath = createRequire(require.resolve('jest-axe')).resolve('axe-core/axe.min.js')

interface AxeViolation {
  id: string
  nodes: { target: string[] }[]
}

/** Requests that failed, so a journey can assert the page made none. */
function watchForServerErrors(page: Page) {
  const failed: string[] = []
  page.on('response', res => {
    if (res.status() >= 500) failed.push(`${res.status()} ${res.request().method()} ${res.url()}`)
  })
  return failed
}

// The server keeps its state between tests, so the journeys run in order.
test.describe('journeys', () => {
  test.describe.configure({ mode: 'serial' })

  test('the dashboard shows the lab the server sees', async ({ page }) => {
    const failed = watchForServerErrors(page)
    await page.goto('/')
    await expect(page).toHaveURL(/\/dashboard$/)
    await expect(page.getByText('k3d-contract')).toBeVisible()
    await expect(page.getByText('v1.33.6+k3s1')).toBeVisible()
    await expect(page.getByText('demo-app').first()).toBeVisible()
    await expect(page.getByText('go-api').first()).toBeVisible()
    expect(failed).toEqual([])
  })

  test('a deep link survives a reload', async ({ page }) => {
    await page.goto('/incidents')
    await expect(page.getByText('Demo fault')).toBeVisible()
    await page.reload()
    await expect(page).toHaveURL(/\/incidents$/)
    await expect(page.getByText('Demo fault')).toBeVisible()
  })

  test('a path that is not a page shows the app, and one under the API is a JSON problem', async ({ page, request }) => {
    const missing = await request.get('/api/v2/no-such-route')
    expect(missing.status()).toBe(404)
    expect(missing.headers()['content-type']).toContain('application/problem+json')

    await page.goto('/no-such-page')
    await expect(page.getByRole('navigation')).toBeVisible()
  })

  test('activate a scenario, verify it, and deactivate it', async ({ page }) => {
    const failed = watchForServerErrors(page)
    await page.goto('/scenarios')
    const row = page.locator('.scenario-row', { hasText: 'Demo scenario' })
    await expect(row.getByText('Inactive')).toBeVisible()

    await row.getByRole('button', { name: 'Activate', exact: true }).click()
    const confirm = page.getByRole('alertdialog')
    await expect(confirm).toContainText('Demo scenario')
    await confirm.getByRole('button', { name: 'Activate', exact: true }).click()
    await expect(row.getByText('Active', { exact: true })).toBeVisible({ timeout: 15_000 })

    await row.getByRole('button', { name: 'Verify' }).click()
    await expect(page.getByText('marker-present')).toBeVisible({ timeout: 15_000 })

    await row.getByRole('button', { name: 'Deactivate' }).click()
    await page.getByRole('alertdialog').getByRole('button', { name: 'Deactivate' }).click()
    await expect(row.getByText('Inactive')).toBeVisible({ timeout: 15_000 })
    expect(failed).toEqual([])
  })

  test('inject an incident, see it is not resolved, and resolve it', async ({ page }) => {
    const failed = watchForServerErrors(page)
    await page.goto('/incidents')
    await expect(page.getByText('No active incident')).toBeVisible()

    await page.locator('.scenario-row', { hasText: 'Demo fault' }).getByRole('button', { name: 'Inject', exact: true }).click()
    await page.getByRole('alertdialog').getByRole('button', { name: 'Inject', exact: true }).click()
    await expect(page.getByText(/Active: Demo fault/)).toBeVisible({ timeout: 15_000 })

    await page.getByRole('button', { name: /check/i }).first().click()
    await expect(page.getByText(/not resolved/i).first()).toBeVisible({ timeout: 15_000 })

    await page.getByRole('button', { name: /^Resolve/ }).first().click()
    await page.getByRole('alertdialog').getByRole('button', { name: 'Resolve' }).click()
    await expect(page.getByText('No active incident')).toBeVisible({ timeout: 15_000 })
    expect(failed).toEqual([])
  })

  test('start a learning path and complete its module', async ({ page }) => {
    const failed = watchForServerErrors(page)
    await page.goto('/learn')
    const card = page.locator('.scenario-row, .card', { hasText: 'Demo path' }).first()
    await expect(card).toContainText('0/1 completed')

    await page.getByRole('button', { name: 'Details' }).first().click()
    const dialog = page.getByRole('dialog', { name: 'Learning path details' })
    await dialog.getByRole('button', { name: 'Start Path' }).click()
    await dialog.getByRole('button', { name: 'Check', exact: true }).click()
    await expect(dialog.getByText('Path complete').first()).toBeVisible({ timeout: 15_000 })
    await dialog.getByRole('button', { name: 'Close', exact: true }).last().click()
    await expect(page.getByText('1/1 completed')).toBeVisible()
    expect(failed).toEqual([])
  })

  test('what was done shows up in the results and on the leaderboard', async ({ page }) => {
    await page.goto('/results')
    await expect(page.getByText('demo-fault').first()).toBeVisible()
    await expect(page.getByText('demo-path/step-one').first()).toBeVisible()

    await page.goto('/leaderboard')
    await expect(page.getByText(/Leaderboard \(1\)/)).toBeVisible()
  })
  test('a run in flight keeps streaming after its connection drops', async ({ page }) => {
    const run = startHeldInject()
    try {
      await openRunningRun(page)
      await expect(page.locator('.run-output')).toContainText('breaking the demo app')

      await page.route('**/api/v2/runs/*/logs*', route => route.abort())
      await expect(page.getByRole('alert').filter({ hasText: /cannot reach/i })).toBeVisible({ timeout: 10_000 })
      await page.unroute('**/api/v2/runs/*/logs*')
    } finally {
      release()
    }

    await expect(page.locator('.run-output')).toContainText('the demo app is broken', { timeout: 15_000 })
    await expect(page.getByRole('alert').filter({ hasText: /cannot reach/i })).toHaveCount(0)
    expect((await page.locator('.run-output').innerText()).match(/breaking the demo app/g)).toHaveLength(1)
    expect(await exitOf(run)).toBe(0)
    expect(await exitOf(labctl(['incident', 'resolve']))).toBe(0)
  })

  test('cancel a run in flight', async ({ page, request }) => {
    const run = startHeldInject()
    try {
      await openRunningRun(page)
      await page.getByRole('button', { name: 'Cancel', exact: true }).click()
      await expect(page.getByText('Cancellation requested')).toBeVisible()
      await expect(page.getByRole('button', { name: 'Cancel', exact: true })).toHaveCount(0)

      // The process running the inject stops while the hold is still on.
      expect(await exitOf(run)).not.toBe(0)
    } finally {
      release()
    }
    const status = await (await request.get('/api/v2/incidents/status')).json()
    expect(status.active).toBeFalsy()
  })
})

const routes = ['dashboard', 'scenarios', 'incidents', 'platform', 'apps', 'runs', 'traffic', 'learn', 'challenges', 'results', 'leaderboard', 'compare']

/** Runs axe on the page and returns each violation as "rule: where". */
async function scan(page: Page, options: object): Promise<string[]> {
  await page.waitForLoadState('networkidle')
  await page.addScriptTag({ path: axePath })
  const violations = await page.evaluate(async opts => {
    const axe = (window as unknown as { axe: { run: (ctx: Document, o: object) => Promise<{ violations: AxeViolation[] }> } }).axe
    return (await axe.run(document, opts)).violations
  }, options)
  return violations.map(v => `${v.id}: ${v.nodes.map(n => n.target.join(' ')).join(', ')}`)
}

const wcagAA = { type: 'tag', values: ['wcag2a', 'wcag2aa'] }

test.describe('accessibility', () => {
  // Each route in both themes, colour contrast included: the light and dark
  // palettes each have their own text and badge colours.
  for (const scheme of ['light', 'dark'] as const) {
    for (const route of routes) {
      test(`/${route} has no accessibility violations in the ${scheme} theme`, async ({ browser, baseURL }) => {
        const context = await browser.newContext({ colorScheme: scheme, baseURL })
        const page = await context.newPage()
        await page.goto(`/${route}`)
        await expect(page.getByRole('navigation')).toBeVisible()
        const found = await scan(page, { runOnly: wcagAA })
        await context.close()
        expect(found).toEqual([])
      })
    }
  }
})

/** labctl for the server's lab, which start-lab.sh writes next to the hold file. */
function labctl(args: string[]): ChildProcess {
  return spawn(`${holdFile()}.labctl`, args, { stdio: 'ignore' })
}

function exitOf(child: ChildProcess): Promise<number | null> {
  if (child.exitCode !== null) return Promise.resolve(child.exitCode)
  return new Promise(resolve => child.on('exit', code => resolve(code)))
}

/** Injects the fixture fault from the CLI; its inject waits until release(). */
function startHeldInject(): ChildProcess {
  writeFileSync(holdFile(), '')
  return labctl(['incident', 'inject', 'demo-fault'])
}

function release() {
  rmSync(holdFile(), { force: true })
}

function holdFile(): string {
  const path = process.env.E2E_HOLD
  if (!path) throw new Error('E2E_HOLD is not set; playwright.config.ts sets it')
  return path
}

/** Opens the Runs view on the fixture fault's inject once it is running. */
async function openRunningRun(page: Page) {
  await page.goto('/runs')
  const row = page.getByRole('button', { name: /demo-fault.*running/ }).first()
  await expect(row).toBeVisible({ timeout: 10_000 })
  await row.click()
}
