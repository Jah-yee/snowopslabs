// SPDX-License-Identifier: Apache-2.0
//
// Learn view behaviour against the server's real answers (test/contract.ts):
// a learner opens a path, starts it, and the server checks each module before
// recording it.
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { axe, toHaveNoViolations } from 'jest-axe'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { Learn } from './Learn'
import { golden, serveContract } from '../test/contract'
import type { LearnProgress } from '../types'

expect.extend(toHaveNoViolations)

afterEach(() => {
  vi.unstubAllGlobals()
})

function renderLearn() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const notify = vi.fn()
  const view = render(
    <QueryClientProvider client={client}>
      <Learn notify={notify} requestConfirm={vi.fn()} />
    </QueryClientProvider>,
  )
  return { notify, container: view.container }
}

async function openDetails() {
  const user = userEvent.setup()
  await user.click(await screen.findByRole('button', { name: /details/i }))
  return { user, dialog: await screen.findByRole('dialog', { name: 'Learning path details' }) }
}

const startedProgress = () => golden<LearnProgress>('POST', '/learn/paths/{name}/start')

describe('Learn view', () => {
  it('lists the paths with their progress', async () => {
    const server = serveContract()
    renderLearn()
    expect(await screen.findByText('Demo path')).toBeInTheDocument()
    expect(screen.getByText('0/1 completed')).toBeInTheDocument()
    expect(server.unanswered).toEqual([])
  })

  it('shows what each module asks the learner to do', async () => {
    serveContract()
    renderLearn()
    const { dialog } = await openDetails()
    expect(await within(dialog).findByText('Step one')).toBeInTheDocument()
    expect(within(dialog).getByText('command · labctl runtime up')).toBeInTheDocument()
  })

  it('starts a path', async () => {
    const server = serveContract()
    renderLearn()
    const { user, dialog } = await openDetails()
    await user.click(await within(dialog).findByRole('button', { name: 'Start Path' }))

    await waitFor(() => expect(server.requests).toContain('POST /learn/paths/demo-path/start'))
    expect(await within(dialog).findByRole('button', { name: 'Check' })).toBeInTheDocument()
  })

  it('records a module whose check passes, and reports the path finished', async () => {
    const server = serveContract()
    server.override('GET', '/learn/paths/demo-path/progress', 200, startedProgress())
    const { notify } = renderLearn()
    const { user, dialog } = await openDetails()
    await user.click(await within(dialog).findByRole('button', { name: 'Check' }))

    await waitFor(() => expect(notify).toHaveBeenCalledWith('success', 'Path complete', expect.any(String)))
    expect(within(dialog).getAllByText(/path complete/i).length).toBeGreaterThan(0)
  })

  it('says why a module is not done when its check fails, and records nothing', async () => {
    const server = serveContract()
    server.override('GET', '/learn/paths/demo-path/progress', 200, startedProgress())
    server.override('POST', '/learn/paths/demo-path/complete', 200, {
      ...startedProgress(),
      check: { name: 'cluster-up', type: 'script', pass: false, error: 'the cluster is not answering' },
    })
    const { notify } = renderLearn()
    const { user, dialog } = await openDetails()
    await user.click(await within(dialog).findByRole('button', { name: 'Check' }))

    await waitFor(() => expect(notify).toHaveBeenCalledWith('error', 'Not done yet', 'the cluster is not answering'))
    expect(notify).not.toHaveBeenCalledWith('success', expect.anything(), expect.anything())
    expect(within(dialog).getByRole('button', { name: 'Check' })).toBeEnabled()
  })

  it('reports a check the server could not run', async () => {
    const server = serveContract()
    server.override('GET', '/learn/paths/demo-path/progress', 200, startedProgress())
    server.override('POST', '/learn/paths/demo-path/complete', 500, {
      type: 'internal_error', title: 'Internal Server Error', status: 500, detail: 'the server could not complete this request',
    })
    const { notify } = renderLearn()
    const { user, dialog } = await openDetails()
    await user.click(await within(dialog).findByRole('button', { name: 'Check' }))

    await waitFor(() => expect(notify).toHaveBeenCalledWith('error', 'Could not check the module', 'the server could not complete this request'))
  })

  it('has no accessibility violations with the detail modal open', async () => {
    serveContract()
    const { container } = renderLearn()
    await openDetails()
    expect(await axe(container)).toHaveNoViolations()
  })
})
