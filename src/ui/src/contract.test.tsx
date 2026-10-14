// SPDX-License-Identifier: Apache-2.0
//
// Every view, rendered against the server's real answers.
//
// The views are given the golden responses the Go contract suite records for
// the fixture lab (see test/contract.ts). Each must show what those responses
// hold and report no error. A Go change that renames, retypes or drops a field
// a view reads empties that view, and its row here fails.
import fs from 'node:fs'
import path from 'node:path'
import { render, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ReactElement } from 'react'
import { golden, serveContract } from './test/contract'
import { Apps } from './views/Apps'
import { Challenges } from './views/Challenges'
import { Compare } from './views/Compare'
import { Dashboard } from './views/Dashboard'
import { Incidents } from './views/Incidents'
import { Leaderboard } from './views/Leaderboard'
import { Learn } from './views/Learn'
import { Platform } from './views/Platform'
import { Results } from './views/Results'
import { Runs } from './views/Runs'
import { Scenarios } from './views/Scenarios'
import { Traffic } from './views/Traffic'

type Notify = (type: string, title: string, message?: string) => void

interface Row {
  view: string
  render: (notify: Notify) => ReactElement
  /** Text the view must show, taken from the fixture lab's answers. */
  shows: (string | RegExp)[]
}

const noConfirm = () => {}

const rows: Row[] = [
  { view: 'Dashboard', render: n => <Dashboard notify={n} liveCluster={null} lastStatusAt={null} requestConfirm={noConfirm} />,
    shows: ['k3d-contract', 'v1.33.6+k3s1', 'traefik', 'prometheus', 'demo-app', /replicas: 2 · ready: 2/] },
  { view: 'Scenarios', render: n => <Scenarios notify={n} requestConfirm={noConfirm} />,
    shows: ['Scenarios (1)', 'Demo scenario', 'reliability', 'Inactive'] },
  { view: 'Incidents', render: n => <Incidents notify={n} requestConfirm={noConfirm} />,
    shows: ['Incident library (1)', 'Demo fault', 'workload', 'low', 'No active incident'] },
  { view: 'Platform', render: n => <Platform notify={n} requestConfirm={noConfirm} />,
    shows: ['traefik', 'prometheus', 'grafana', 'Installed', 'Grafana'] },
  { view: 'Apps', render: n => <Apps notify={n} requestConfirm={noConfirm} />,
    shows: ['Applications (2)', 'demo-app', 'go-api', 'Deployed', /replicas: 2 · ready: 2/] },
  { view: 'Traffic', render: n => <Traffic notify={n} />,
    shows: ['steady', 'spike', 'http://go-api.go-api.svc.cluster.local:8080/'] },
  { view: 'Runs', render: n => <Runs notify={n} />,
    shows: ['Runs (1)', /lab\.up · k3d/, 'succeeded', 'run-1', 'line one'] },
  { view: 'Learn', render: n => <Learn notify={n} requestConfirm={noConfirm} />,
    shows: ['Learning Paths (1)', 'Demo path', 'A path with one module', '0/1 completed', 'Not Started'] },
  { view: 'Challenges', render: n => <Challenges notify={n} requestConfirm={noConfirm} />,
    shows: ['Challenges (1)', 'Demo challenge', 'Fix the demo fault', 'par 10m', 'labctl challenge start demo-challenge'] },
  { view: 'Results', render: n => <Results notify={n} />,
    shows: ['Run History (3)', 'demo-challenge', 'demo-path/step-one', 'demo-fault', 'learner'] },
  { view: 'Leaderboard', render: n => <Leaderboard notify={n} />,
    shows: ['Leaderboard (1)', 'learner', '100'] },
  { view: 'Compare', render: n => <Compare notify={n} />,
    shows: ['autoscaling-under-load', 'go-api', 'java-api'] },
]

afterEach(() => {
  vi.unstubAllGlobals()
})

function renderView(element: ReactElement) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter>{element}</MemoryRouter>
    </QueryClientProvider>,
  )
}

/** Waits until the page shows every expected text, and reports the first one
 *  it never did along with what the page did show. */
async function expectShown(shows: (string | RegExp)[]) {
  await waitFor(() => {
    const text = document.body.textContent ?? ''
    for (const want of shows) {
      const found = typeof want === 'string' ? text.includes(want) : want.test(text)
      if (!found) throw new Error(`the view does not show ${String(want)}. It shows:\n${text}`)
    }
  }, { timeout: 4000 })
}

describe('every view renders the server contract', () => {
  it.each(rows)('$view shows what the server answers', async ({ render: build, shows }) => {
    const server = serveContract()
    const notify = vi.fn()
    renderView(build(notify as unknown as Notify))

    await expectShown(shows)
    expect(server.unanswered, 'requests the contract has no answer for').toEqual([])
    expect(notify.mock.calls.filter(call => call[0] === 'error'), 'error notifications').toEqual([])
  })

  it('no view test stubs the API client: they all read the contract', () => {
    const dir = path.resolve(__dirname, 'views')
    const stubbing = fs.readdirSync(dir)
      .filter(f => f.endsWith('.test.tsx'))
      .filter(f => fs.readFileSync(path.join(dir, f), 'utf8').includes(`vi.mock('../api/client'`))
    expect(stubbing).toEqual([])
  })

  it('has a row for every view', () => {
    const files = fs.readdirSync(path.resolve(__dirname, 'views')).filter(f => f.endsWith('.tsx') && !f.includes('.test.'))
    expect(rows.map(r => `${r.view}.tsx`).sort()).toEqual(files.sort())
  })
})

// The suite above is only worth something if a changed response fails it.
describe('a change in a server response is noticed', () => {
  it('a renamed field empties the view that reads it', async () => {
    const server = serveContract()
    const scenarios = golden<{ items: Record<string, unknown>[] }>('GET', '/scenarios')
    server.override('GET', '/scenarios', 200, {
      items: scenarios.items.map(({ displayName, ...rest }) => ({ ...rest, display_name: displayName })),
    })
    renderView(<Scenarios notify={vi.fn()} requestConfirm={noConfirm} />)

    await expectShown(['Scenarios (1)'])
    expect(document.body.textContent).not.toContain('Demo scenario')
  })

  it('a list that stops being paginated is reported, not rendered empty', async () => {
    const server = serveContract()
    server.override('GET', '/scenarios', 200, golden<{ items: unknown[] }>('GET', '/scenarios').items)
    renderView(<Scenarios notify={vi.fn()} requestConfirm={noConfirm} />)

    await expectShown([/unexpected shape for \/scenarios/])
  })

  it('a problem answer shows its detail to the user', async () => {
    const server = serveContract()
    server.override('GET', '/learn/paths', 500, {
      type: 'internal_error', title: 'Internal Server Error', status: 500,
      detail: 'the server could not complete this request: its log has the cause',
    })
    renderView(<Learn notify={vi.fn()} requestConfirm={noConfirm} />)

    await expectShown(['the server could not complete this request'])
  })
})
