// SPDX-License-Identifier: Apache-2.0
//
// Traffic view behaviour. Requests go through the real client to the
// contract server (test/contract.ts); each test serves the answers it needs.
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, describe, it, expect, vi } from 'vitest'
import { serveContract, type ContractServer } from '../test/contract'
import { Traffic } from './Traffic'

afterEach(() => {
  vi.unstubAllGlobals()
})

// The traffic targets come from the apps API — each app's in-cluster address is
// the one it declares in its contract, not one the UI reconstructs.
const APPS = [
  { name: 'go-api', buildStrategy: 'docker', deployStrategy: 'helm', deployed: true,
    serviceUrl: 'http://go-api.go-api.svc.cluster.local:8080/' },
  { name: 'java-api', buildStrategy: 'docker', deployStrategy: 'helm', deployed: true,
    serviceUrl: 'http://java-api.team-a.svc.cluster.local:9090/' },
]

function renderTraffic() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const notify = vi.fn()
  render(
    <QueryClientProvider client={client}>
      <Traffic notify={notify} />
    </QueryClientProvider>,
  )
  return { notify }
}

/** A contract server answering GET /traffic with traffic and GET /apps with apps. */
function serveTraffic(traffic: object | Error, apps: unknown[] = APPS): ContractServer {
  const server = serveContract()
  if (traffic instanceof Error) {
    server.override('GET', '/traffic', 500, { type: 'internal_error', title: 'Internal Server Error', status: 500, detail: traffic.message })
  } else {
    server.override('GET', '/traffic', 200, traffic)
  }
  server.override('GET', '/apps', 200, apps)
  return server
}

/** The body of the one POST /traffic/start the view sent. */
function startBody(server: ContractServer) {
  return server.calls.find(c => c.method === 'POST' && c.path === '/traffic/start')?.body
}

describe('Traffic view', () => {
  it('reads the profiles and apps the server reports', async () => {
    serveContract()
    renderTraffic()
    expect(await screen.findByRole('option', { name: 'spike' })).toBeInTheDocument()
    expect(await screen.findByRole('option', { name: /demo-app/ })).toBeInTheDocument()
  })

  it('lists the k6 profiles and offers start/stop controls', async () => {
    serveTraffic({ profiles: ['steady', 'spike', 'soak'] })
    renderTraffic()

    const select = await screen.findByRole('combobox', { name: /traffic profile/i })
    expect(select).toHaveValue('steady') // defaults to the first profile
    expect(screen.getByRole('option', { name: 'spike' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /start traffic/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /stop traffic/i })).toBeInTheDocument()
  })

  it('starts the selected profile with the chosen rps', async () => {
    const server = serveTraffic({ profiles: ['steady', 'spike'] })

    const user = userEvent.setup()
    const { notify } = renderTraffic()

    await screen.findByRole('combobox', { name: /traffic profile/i })
    await screen.findByRole('option', { name: /go-api/ })
    await user.selectOptions(screen.getByRole('combobox', { name: /traffic profile/i }), 'spike')
    await user.click(screen.getByRole('button', { name: /start traffic/i }))

    await waitFor(() =>
      expect(startBody(server)).toEqual({
        profile: 'spike',
        rps: 50,
        target: 'http://go-api.go-api.svc.cluster.local:8080/',
      }))
    await waitFor(() =>
      expect(notify).toHaveBeenCalledWith('info', expect.stringMatching(/Traffic \(spike → go-api\) started/), expect.anything()))
  })

  it('stops traffic', async () => {
    const server = serveTraffic({ profiles: ['steady'] })

    const user = userEvent.setup()
    renderTraffic()
    await screen.findByRole('button', { name: /stop traffic/i })
    await user.click(screen.getByRole('button', { name: /stop traffic/i }))
    await waitFor(() => expect(server.requests).toContain('POST /traffic/stop'))
  })

  it('shows an empty state when no profiles exist', async () => {
    serveTraffic({ profiles: [] })
    renderTraffic()
    expect(await screen.findByText(/No traffic profiles found/)).toBeInTheDocument()
  })

  it('shows a designed error state when the profiles fail to load', async () => {
    serveTraffic(new Error('boom'))
    renderTraffic()
    expect(await screen.findByText(/Failed to load traffic profiles/)).toBeInTheDocument()
  })

  // A new app — or one on a non-default port — must appear as a target without
  // any UI change. The address is the app's own, never rebuilt by the client.
  it('offers every app the API reports, at its declared in-cluster address', async () => {
    const server = serveTraffic({ profiles: ['steady'] })

    const user = userEvent.setup()
    renderTraffic()

    const target = await screen.findByRole('combobox', { name: /traffic target/i })
    expect(await screen.findByRole('option', { name: /java-api/ })).toBeInTheDocument()

    await user.selectOptions(target, 'java-api')
    await user.click(screen.getByRole('button', { name: /start traffic/i }))

    await waitFor(() =>
      expect(startBody(server)).toEqual(expect.objectContaining({
        target: 'http://java-api.team-a.svc.cluster.local:9090/',
      })))
  })

  it('says so rather than silently targeting nothing when no app declares an address', async () => {
    serveTraffic({ profiles: ['steady'] }, [])
    renderTraffic()

    await screen.findByRole('combobox', { name: /traffic target/i })
    expect(await screen.findByText(/No app declares an in-cluster address/i)).toBeInTheDocument()
  })

  // Load aimed at a workload nobody is looking at is worse than no default, and
  // the first app alphabetically is not the one the lab is working on.
  it('preselects the bound workload rather than the first app', async () => {
    serveTraffic({
      profiles: ['steady'],
      workload: { app: 'go-api', namespace: 'go-api', service: 'go-api.go-api.svc.cluster.local', port: '8080', metric: 'm' },
    }, [
      { name: 'echo-server', buildStrategy: 'docker', deployStrategy: 'helm', deployed: true, serviceUrl: 'http://echo-server.echo-server.svc.cluster.local:8080/' },
      { name: 'go-api', buildStrategy: 'docker', deployStrategy: 'helm', deployed: true, serviceUrl: 'http://go-api.go-api.svc.cluster.local:8080/' },
    ])
    renderTraffic()

    const target = await screen.findByRole('combobox', { name: /traffic target/i }) as HTMLSelectElement
    await waitFor(() => expect(target.value).toBe('go-api'))
    expect(await screen.findByText('http://go-api.go-api.svc.cluster.local:8080/')).toBeInTheDocument()
  })
})