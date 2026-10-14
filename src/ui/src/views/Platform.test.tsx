// SPDX-License-Identifier: Apache-2.0
//
// The Platform view must not guess while the cluster is unreachable: every
// component would otherwise read "Not Installed" and invite a pointless
// install. Requests go through the real client to the contract server
// (test/contract.ts).
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { Platform } from './Platform'
import { serveContract, type ContractServer } from '../test/contract'
import type { ConfirmRequest } from '../components/ConfirmDialog'

afterEach(() => {
  vi.unstubAllGlobals()
})

function serveUninstalledIngress(): ContractServer {
  const server = serveContract()
  server.override('GET', '/platform', 200, {
    ingress: [{ name: 'traefik', category: 'ingress', installed: false, exclusive: true }],
  })
  return server
}

function renderPlatform(clusterDown: boolean) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  let confirm: ConfirmRequest | null = null
  const notify = vi.fn()
  render(
    <QueryClientProvider client={client}>
      <Platform notify={notify} requestConfirm={r => { confirm = r }} clusterDown={clusterDown} />
    </QueryClientProvider>,
  )
  return { notify, confirm: () => confirm }
}

describe('Platform view', () => {
  it('shows each installed component from the server', async () => {
    serveContract()
    renderPlatform(false)
    expect(await screen.findByText('traefik')).toBeInTheDocument()
    expect(screen.getAllByText('prometheus').length).toBeGreaterThan(0)
    expect(screen.getAllByText('Installed').length).toBeGreaterThan(0)
  })

  it('shows install state and an Install action when the cluster answers', async () => {
    serveUninstalledIngress()
    renderPlatform(false)
    expect(await screen.findByText('Not Installed')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Install' })).toBeEnabled()
  })

  it('installs a component through the API', async () => {
    const server = serveUninstalledIngress()
    const { notify } = renderPlatform(false)
    await userEvent.setup().click(await screen.findByRole('button', { name: 'Install' }))

    await waitFor(() => expect(server.requests).toContain('POST /platform/component/ingress/traefik/up'))
    await waitFor(() => expect(notify).toHaveBeenCalledWith('info', expect.stringContaining('started'), expect.any(String)))
  })

  it('shows Unknown and holds actions while the cluster is unreachable', async () => {
    serveUninstalledIngress()
    renderPlatform(true)
    expect(await screen.findByText('Unknown')).toBeInTheDocument()
    expect(screen.queryByText('Not Installed')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Install' })).toBeDisabled()
  })

  it('opens a component’s details and closes them on a click outside', async () => {
    const server = serveContract()
    renderPlatform(false)
    const user = userEvent.setup()
    await user.click((await screen.findAllByRole('button', { name: 'Details' }))[0])
    expect(await screen.findByRole('dialog')).toBeInTheDocument()
    expect(server.requests.some(r => r.startsWith('GET /platform/component/'))).toBe(true)
    await user.click(screen.getByRole('presentation'))
    await waitFor(() => expect(screen.queryByRole('dialog')).not.toBeInTheDocument())
  })

  it('reports a platform it cannot read', async () => {
    const server = serveContract()
    server.override('GET', '/platform', 500, { type: 'internal_error', title: 'Internal Server Error', status: 500, detail: 'the run store is not available' })
    renderPlatform(false)
    expect(await screen.findByText(/the run store is not available/)).toBeInTheDocument()
  })
})
