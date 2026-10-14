// SPDX-License-Identifier: Apache-2.0
import { act, renderHook, waitFor } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'
import { completeJob } from '../lib/jobs'
import type { ActionAccepted } from '../types'
import { useJobRunner } from './useJobRunner'

const accepted = (jobId: string): Promise<ActionAccepted> => Promise.resolve({ jobId, status: 'accepted' })

describe('useJobRunner', () => {
  it('keeps the key busy until the job ends, then reports success', async () => {
    const notify = vi.fn()
    const onDone = vi.fn()
    const { result } = renderHook(() => useJobRunner(notify))

    await act(() => result.current.run('deploy:api', 'Deploy api', () => accepted('job-ok'), onDone))
    expect(result.current.busy['deploy:api']).toBe(true)
    expect(notify).toHaveBeenCalledWith('info', 'Deploy api started', expect.any(String))

    act(() => completeJob('job-ok', true))
    expect(result.current.busy['deploy:api']).toBe(false)
    expect(notify).toHaveBeenCalledWith('success', 'Deploy api completed')
    expect(onDone).toHaveBeenCalledWith(true)
  })

  it('reports a job that fails, with the reason the server gave', async () => {
    const notify = vi.fn()
    const onDone = vi.fn()
    const { result } = renderHook(() => useJobRunner(notify))

    await act(() => result.current.run('deploy:api', 'Deploy api', () => accepted('job-bad'), onDone))
    act(() => completeJob('job-bad', false, 'helm upgrade timed out'))

    expect(result.current.busy['deploy:api']).toBe(false)
    expect(notify).toHaveBeenCalledWith('error', 'Deploy api failed', 'helm upgrade timed out')
    expect(onDone).toHaveBeenCalledWith(false)
  })

  it('points at the output panel when a failed job gives no reason', async () => {
    const notify = vi.fn()
    const { result } = renderHook(() => useJobRunner(notify))

    await act(() => result.current.run('k', 'Install', () => accepted('job-silent')))
    act(() => completeJob('job-silent', false))

    expect(notify).toHaveBeenCalledWith('error', 'Install failed', 'See the command output panel for details.')
  })

  it('reports a request the server refused and frees the key at once', async () => {
    const notify = vi.fn()
    const { result } = renderHook(() => useJobRunner(notify))

    await act(() => result.current.run('k', 'Install', () => Promise.reject(new Error('operator role required'))))

    expect(result.current.busy.k).toBe(false)
    expect(notify).toHaveBeenCalledWith('error', 'Install failed', 'operator role required')
    expect(notify).not.toHaveBeenCalledWith('info', expect.anything(), expect.anything())
  })

  it('ignores a second click on a key that is still busy', async () => {
    const notify = vi.fn()
    const start = vi.fn(() => accepted('job-once'))
    const { result } = renderHook(() => useJobRunner(notify))

    await act(() => result.current.run('k', 'Install', start))
    await act(() => result.current.run('k', 'Install', start))
    expect(start).toHaveBeenCalledTimes(1)

    act(() => completeJob('job-once', true))
    await act(() => result.current.run('k', 'Install', () => accepted('job-twice')))
    expect(result.current.busy.k).toBe(true)
    act(() => completeJob('job-twice', true))
  })

  it('still reports a job that ends after the view was left', async () => {
    const notify = vi.fn()
    const { result, unmount } = renderHook(() => useJobRunner(notify))

    await act(() => result.current.run('k', 'Install', () => accepted('job-late')))
    unmount()
    act(() => completeJob('job-late', true))

    await waitFor(() => expect(notify).toHaveBeenCalledWith('success', 'Install completed'))
  })
})
