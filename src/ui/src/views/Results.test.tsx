// SPDX-License-Identifier: Apache-2.0
//
// Results view behaviour (W7-T04): summary stats, the MTTR/MTTD + score trend
// charts, and the per-check breakdown in the history table. Requests go
// through the real client to the contract server (test/contract.ts).
import { render, screen, within } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { axe, toHaveNoViolations } from 'jest-axe'
import { afterEach, describe, it, expect, vi } from 'vitest'
import { Results } from './Results'
import type { ResultRecord } from '../types'
import { serveContract } from '../test/contract'

expect.extend(toHaveNoViolations)

afterEach(() => {
  vi.unstubAllGlobals()
})

/** Serves the given history as GET /results. */
function serveResults(records: ResultRecord[]) {
  const server = serveContract()
  server.override('GET', '/results', 200, records)
  return server
}

function renderResults() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <Results notify={vi.fn()} />
    </QueryClientProvider>,
  )
}

const incident = (name: string, mttr: number, mttd: number, at: string): ResultRecord => ({
  kind: 'incident', name, startedAt: at, endedAt: at, elapsedSeconds: mttr,
  score: -1, outcome: 'resolved', meta: { detectSeconds: mttd },
})
const challenge = (name: string, score: number, at: string, passed = 3, total = 4): ResultRecord => ({
  kind: 'challenge', name, startedAt: at, endedAt: at, elapsedSeconds: 120,
  score, outcome: 'passed', hintsUsed: 1, meta: { checksPassed: passed, checksTotal: total },
})

describe('Results view', () => {
  it('shows the history the server records', async () => {
    serveContract()
    renderResults()
    const table = await screen.findByRole('table')
    for (const name of ['demo-challenge', 'demo-fault', 'demo-path/step-one']) {
      expect(within(table).getAllByText(name).length).toBeGreaterThan(0)
    }
  })

  it('shows a designed empty state with no runs', async () => {
    serveResults([])
    renderResults()
    expect(await screen.findByText(/no runs recorded yet/i)).toBeInTheDocument()
    // No charts when there's nothing to plot.
    expect(screen.queryByRole('img', { name: /trend/i })).not.toBeInTheDocument()
  })

  it('renders MTTR/MTTD and score trend charts and avg stats', async () => {
    serveResults([
      incident('oom-kill', 90, 20, '2026-08-20T10:00:00Z'),
      incident('oom-kill', 45, 10, '2026-08-21T10:00:00Z'),
      challenge('deploy-fix', 80, '2026-08-22T10:00:00Z'),
    ])
    renderResults()

    expect(await screen.findByRole('img', { name: /MTTR and MTTD trend/i })).toBeInTheDocument()
    expect(screen.getByRole('img', { name: /challenge score trend/i })).toBeInTheDocument()
    // Avg MTTR tile present (average of 90 and 45 = 67s -> "1m 7s").
    expect(screen.getByText('Avg MTTR')).toBeInTheDocument()
    expect(screen.getByText('Avg MTTD')).toBeInTheDocument()
  })

  it('shows the challenge check breakdown in the history table', async () => {
    serveResults([challenge('deploy-fix', 80, '2026-08-22T10:00:00Z', 3, 4)])
    renderResults()
    const table = await screen.findByRole('table')
    expect(within(table).getByText('3/4 checks')).toBeInTheDocument()
    expect(within(table).getByText(/1 hint/)).toBeInTheDocument()
  })

  it('has no accessibility violations with charts and a history table', async () => {
    serveResults([
      incident('oom-kill', 90, 20, '2026-08-20T10:00:00Z'),
      challenge('deploy-fix', 80, '2026-08-22T10:00:00Z'),
    ])
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const { container } = render(
      <QueryClientProvider client={client}>
        <Results notify={vi.fn()} />
      </QueryClientProvider>,
    )
    await screen.findByRole('table')
    expect(await axe(container)).toHaveNoViolations()
  })

  it('does not render the incident chart when only challenges exist', async () => {
    serveResults([challenge('deploy-fix', 70, '2026-08-22T10:00:00Z')])
    renderResults()
    expect(await screen.findByRole('img', { name: /challenge score trend/i })).toBeInTheDocument()
    expect(screen.queryByRole('img', { name: /MTTR and MTTD/i })).not.toBeInTheDocument()
  })
})
