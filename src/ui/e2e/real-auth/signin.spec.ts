// SPDX-License-Identifier: Apache-2.0
//
// Signing in to a server that requires it: the real labctl binary with
// LABCTL_AUTH=true (e2e/real/start-lab.sh with LAB_AUTH=on), one operator and
// one participant.
import { expect, test, type Page } from '@playwright/test'

async function signIn(page: Page, user: string, password: string) {
  await page.goto('/')
  await page.getByLabel('Username').fill(user)
  await page.getByLabel('Password').fill(password)
  await page.getByRole('button', { name: 'Sign in' }).click()
}

test('the app asks for a session before showing anything', async ({ page, request }) => {
  await page.goto('/dashboard')
  await expect(page.getByRole('form', { name: 'Sign in' })).toBeVisible()
  await expect(page.getByRole('navigation')).toHaveCount(0)

  const status = await request.get('/api/v2/status')
  expect(status.status()).toBe(401)
})

test('a wrong password is refused and says so', async ({ page }) => {
  await signIn(page, 'olive', 'not-the-password')
  await expect(page.getByRole('form', { name: 'Sign in' })).toBeVisible()
  await expect(page.getByText(/invalid|incorrect|wrong/i)).toBeVisible()
})

test('an operator signs in, sees the lab, and signs out', async ({ page }) => {
  await signIn(page, 'olive', 'e2e-password')
  await expect(page.getByRole('navigation')).toBeVisible()
  await expect(page.getByText('k3d-contract')).toBeVisible()

  await page.getByRole('button', { name: 'Log out' }).click()
  await expect(page.getByRole('form', { name: 'Sign in' })).toBeVisible()
  await page.goto('/dashboard')
  await expect(page.getByRole('form', { name: 'Sign in' })).toBeVisible()
})

test('a participant can work through a learning path but cannot change the platform', async ({ page }) => {
  await signIn(page, 'pat', 'e2e-password')
  await expect(page.getByRole('navigation')).toBeVisible()

  const forbidden = await page.request.post('/api/v2/platform/up')
  expect(forbidden.status()).toBe(403)
  expect((await forbidden.json()).type).toContain('forbidden_role')

  const allowed = await page.request.get('/api/v2/learn/paths')
  expect(allowed.status()).toBe(200)
})
