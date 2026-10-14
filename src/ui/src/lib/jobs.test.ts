// SPDX-License-Identifier: Apache-2.0
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { JobInfo } from '../types'
import { completeJob, hasTrackedJobs, reconcileJobs, trackJob } from './jobs'

const job = (id: string, status: JobInfo['status'], error?: string) => ({ id, status, error }) as JobInfo

describe('job tracking', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('tells the caller once when the job ends', () => {
    const done = vi.fn()
    trackJob('j1', done)
    expect(hasTrackedJobs()).toBe(true)

    completeJob('j1', true)
    completeJob('j1', false, 'a second event for the same job')

    expect(done).toHaveBeenCalledTimes(1)
    expect(done).toHaveBeenCalledWith(true, undefined)
    expect(hasTrackedJobs()).toBe(false)
  })

  it('passes on why a job failed', () => {
    const done = vi.fn()
    trackJob('j2', done)
    completeJob('j2', false, 'exit status 1')
    expect(done).toHaveBeenCalledWith(false, 'exit status 1')
  })

  it('ignores an event for a job nobody is waiting on, or with no id', () => {
    const done = vi.fn()
    trackJob('', done)
    expect(hasTrackedJobs()).toBe(false)
    completeJob(undefined, true)
    completeJob('never-tracked', true)
    expect(done).not.toHaveBeenCalled()
  })

  // A fast job can end, and its event arrive, before the POST that started it
  // has returned and the caller has started tracking it.
  it('settles at once a job whose end arrived before it was tracked', () => {
    completeJob('early-ok', true)
    completeJob('early-fail', false, 'helm failed')
    const ok = vi.fn()
    const failed = vi.fn()
    trackJob('early-ok', ok)
    trackJob('early-fail', failed)
    expect(ok).toHaveBeenCalledWith(true, undefined)
    expect(failed).toHaveBeenCalledWith(false, 'helm failed')
    expect(hasTrackedJobs()).toBe(false)

    // The early result is used once: tracking the same id again waits.
    const again = vi.fn()
    trackJob('early-ok', again)
    expect(again).not.toHaveBeenCalled()
    completeJob('early-ok', true)
  })

  it('remembers only the most recent early endings', () => {
    for (let i = 0; i < 150; i++) completeJob(`burst-${i}`, true)
    const oldest = vi.fn()
    const newest = vi.fn()
    trackJob('burst-0', oldest)
    trackJob('burst-149', newest)
    expect(newest).toHaveBeenCalledWith(true, undefined)
    expect(oldest).not.toHaveBeenCalled()
    completeJob('burst-0', true)
  })

  it('gives up on a job whose end never arrives, and says where to look', () => {
    const done = vi.fn()
    trackJob('j3', done)

    vi.advanceTimersByTime(15 * 60_000 - 1)
    expect(done).not.toHaveBeenCalled()
    vi.advanceTimersByTime(1)

    expect(done).toHaveBeenCalledWith(false, expect.stringContaining('No completion event received'))
    expect(hasTrackedJobs()).toBe(false)
  })

  it('does not time out a job that already ended', () => {
    const done = vi.fn()
    trackJob('j4', done)
    completeJob('j4', true)
    vi.advanceTimersByTime(60 * 60_000)
    expect(done).toHaveBeenCalledTimes(1)
  })

  it('after a reconnect, settles the jobs that finished meanwhile and keeps the ones still running', () => {
    const ok = vi.fn()
    const failed = vi.fn()
    const running = vi.fn()
    trackJob('ok', ok)
    trackJob('failed', failed)
    trackJob('running', running)

    reconcileJobs([job('ok', 'succeeded'), job('failed', 'failed', 'helm timed out'), job('running', 'running'), job('unknown', 'succeeded')])

    expect(ok).toHaveBeenCalledWith(true, undefined)
    expect(failed).toHaveBeenCalledWith(false, 'helm timed out')
    expect(running).not.toHaveBeenCalled()
    expect(hasTrackedJobs()).toBe(true)
    completeJob('running', true)
  })
})
