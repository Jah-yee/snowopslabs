// SPDX-License-Identifier: Apache-2.0
//
// Apps view behaviour against the contract server (test/contract.ts).
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { Apps } from './Apps'
import { serveContract } from '../test/contract'

afterEach(() => {
  vi.unstubAllGlobals()
})

function renderApps(clusterDown = false) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const notify = vi.fn()
  render(
    <QueryClientProvider client={client}>
      <Apps notify={notify} requestConfirm={r => { void r.onConfirm() }} clusterDown={clusterDown} />
    </QueryClientProvider>,
  )
  return { notify }
}

describe('Apps view', () => {
  it('lists the apps the server reports with their replicas', async () => {
    serveContract()
    renderApps()
    expect(await screen.findByText('Applications (2)')).toBeInTheDocument()
    expect(screen.getByText('demo-app')).toBeInTheDocument()
    expect(screen.getAllByText(/replicas: 2 · ready: 2/).length).toBe(2)
  })

  it('opens an app’s details and closes them on a click outside', async () => {
    const server = serveContract()
    renderApps()
    const user = userEvent.setup()
    await user.click((await screen.findAllByRole('button', { name: 'Details' }))[0])
    expect(await screen.findByRole('dialog', { name: 'demo-app details' })).toBeInTheDocument()
    expect(server.requests).toContain('GET /apps/demo-app/detail')

    await user.click(screen.getByRole('presentation'))
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
  })

  it('deploys an app through the API', async () => {
    const server = serveContract()
    const { notify } = renderApps()
    await userEvent.setup().click((await screen.findAllByRole('button', { name: 'Deploy' }))[0])
    await waitFor(() => expect(server.requests).toContain('POST /apps/demo-app/deploy'))
    await waitFor(() => expect(notify).toHaveBeenCalledWith('info', expect.stringContaining('started'), expect.any(String)))
  })
})
