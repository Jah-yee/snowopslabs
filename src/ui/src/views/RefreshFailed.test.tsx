// SPDX-License-Identifier: Apache-2.0
//
// Every view keeps showing what it last loaded when a background refresh
// fails, under a banner that says so, instead of blanking the page.
import type { ReactElement } from 'react'
import { render, screen, waitFor } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { MemoryRouter } from 'react-router-dom'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { serveContract } from '../test/contract'
import { Apps } from './Apps'
import { Challenges } from './Challenges'
import { Compare } from './Compare'
import { Dashboard } from './Dashboard'
import { Incidents } from './Incidents'
import { Leaderboard } from './Leaderboard'
import { Learn } from './Learn'
import { Platform } from './Platform'
import { Results } from './Results'
import { Runs } from './Runs'
import { Scenarios } from './Scenarios'
import { Traffic } from './Traffic'

afterEach(() => {
  vi.unstubAllGlobals()
})

const notify = vi.fn()
const requestConfirm = vi.fn()

const views: [string, () => ReactElement][] = [
  ['Apps', () => <Apps notify={notify} requestConfirm={requestConfirm} />],
  ['Challenges', () => <Challenges notify={notify} requestConfirm={requestConfirm} />],
  ['Compare', () => <Compare notify={notify} />],
  ['Dashboard', () => <Dashboard notify={notify} requestConfirm={requestConfirm} liveCluster={null} lastStatusAt={null} />],
  ['Incidents', () => <Incidents notify={notify} requestConfirm={requestConfirm} />],
  ['Leaderboard', () => <Leaderboard notify={notify} />],
  ['Learn', () => <Learn notify={notify} requestConfirm={requestConfirm} />],
  ['Platform', () => <Platform notify={notify} requestConfirm={requestConfirm} />],
  ['Results', () => <Results notify={notify} />],
  ['Runs', () => <Runs notify={notify} />],
  ['Scenarios', () => <Scenarios notify={notify} requestConfirm={requestConfirm} />],
  ['Traffic', () => <Traffic notify={notify} />],
]

describe('a refresh that fails after a successful load', () => {
  it.each(views)('%s keeps its data and says the refresh failed', async (_name, view) => {
    serveContract()
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <MemoryRouter>{view()}</MemoryRouter>
      </QueryClientProvider>,
    )
    await waitFor(() => expect(client.isFetching()).toBe(0))

    vi.stubGlobal('fetch', async () =>
      new Response(JSON.stringify({ type: 'internal', title: 'Internal Server Error', status: 500, detail: 'store is locked' }), {
        status: 500,
        headers: { 'Content-Type': 'application/problem+json' },
      }),
    )
    await client.refetchQueries()

    expect(await screen.findByText(/^Refresh failed \(.+\) - showing last known data\.$/)).toBeInTheDocument()
  })
})
