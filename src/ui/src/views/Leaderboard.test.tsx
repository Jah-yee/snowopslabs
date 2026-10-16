// SPDX-License-Identifier: Apache-2.0
//
// Leaderboard view against the contract server (test/contract.ts).
import { render, screen } from '@testing-library/react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { serveContract } from '../test/contract'
import { Leaderboard } from './Leaderboard'

afterEach(() => {
  vi.unstubAllGlobals()
})

describe('Leaderboard view', () => {
  it('tells a new lab how to get onto the board', async () => {
    const server = serveContract()
    server.override('GET', '/leaderboard', 200, [])
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    render(
      <QueryClientProvider client={client}>
        <Leaderboard notify={vi.fn()} />
      </QueryClientProvider>,
    )
    expect(await screen.findByText('No results yet - run a challenge or incident.')).toBeInTheDocument()
    expect(screen.getByText('Leaderboard (0)')).toBeInTheDocument()
  })
})
