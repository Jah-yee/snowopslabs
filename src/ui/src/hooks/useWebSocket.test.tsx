// SPDX-License-Identifier: Apache-2.0
import { act, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { useWebSocket } from './useWebSocket'

/** A WebSocket the test drives: it records every socket opened and lets the
 *  test deliver the events a server or a broken network would. */
class FakeSocket {
  static opened: FakeSocket[] = []
  static failToConstruct = false
  onopen: (() => void) | null = null
  onmessage: ((e: { data: string }) => void) | null = null
  onclose: (() => void) | null = null
  onerror: (() => void) | null = null
  closed = false
  constructor(public url: string) {
    if (FakeSocket.failToConstruct) throw new Error('blocked')
    FakeSocket.opened.push(this)
  }
  close() {
    if (this.closed) return
    this.closed = true
    this.onclose?.()
  }
}

function mount() {
  const onActionEvent = vi.fn()
  const onStatusChange = vi.fn()
  const onClusterStatus = vi.fn()
  const hook = renderHook(() => useWebSocket({ onActionEvent, onStatusChange, onClusterStatus }))
  return { onActionEvent, onStatusChange, onClusterStatus, ...hook }
}

const latest = () => FakeSocket.opened[FakeSocket.opened.length - 1]

describe('useWebSocket', () => {
  beforeEach(() => {
    FakeSocket.opened = []
    FakeSocket.failToConstruct = false
    vi.stubGlobal('WebSocket', FakeSocket)
    vi.useFakeTimers()
    vi.spyOn(Math, 'random').mockReturnValue(0)
  })
  afterEach(() => {
    vi.useRealTimers()
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  it('connects to the API socket and reports the connection', () => {
    const { onStatusChange } = mount()
    expect(onStatusChange).toHaveBeenCalledWith('connecting')
    expect(latest().url).toBe(`ws://${location.host}/api/v2/ws`)

    act(() => latest().onopen?.())
    expect(onStatusChange).toHaveBeenLastCalledWith('connected')
  })

  it('delivers action events and cluster status frames', () => {
    const { onActionEvent, onClusterStatus } = mount()
    act(() => latest().onopen?.())

    act(() => latest().onmessage?.({ data: JSON.stringify({ type: 'action', data: { id: 'j1', type: 'action_end' } }) }))
    expect(onActionEvent).toHaveBeenCalledWith({ id: 'j1', type: 'action_end' })

    act(() => latest().onmessage?.({ data: JSON.stringify({ type: 'status', data: { context: 'k3d-lab', connected: true } }) }))
    expect(onClusterStatus).toHaveBeenCalledWith({ context: 'k3d-lab', connected: true })

    act(() => latest().onmessage?.({ data: JSON.stringify({ type: 'status', data: null }) }))
    expect(onClusterStatus).toHaveBeenLastCalledWith(null)
  })

  it('ignores a frame that is not JSON, an action with no data and an unknown type', () => {
    const { onActionEvent, onClusterStatus } = mount()
    for (const data of ['{not json', JSON.stringify({ type: 'action' }), JSON.stringify({ type: 'banner', data: {} })]) {
      act(() => latest().onmessage?.({ data }))
    }
    expect(onActionEvent).not.toHaveBeenCalled()
    expect(onClusterStatus).not.toHaveBeenCalled()
  })

  it('reconnects with a growing delay, and starts over after a good connection', () => {
    const { onStatusChange } = mount()

    act(() => latest().close())
    expect(onStatusChange).toHaveBeenLastCalledWith('disconnected')
    expect(FakeSocket.opened).toHaveLength(1)
    act(() => { vi.advanceTimersByTime(999) })
    expect(FakeSocket.opened).toHaveLength(1)
    act(() => { vi.advanceTimersByTime(1) })
    expect(FakeSocket.opened).toHaveLength(2)

    // The second failure in a row waits twice as long.
    act(() => latest().close())
    act(() => { vi.advanceTimersByTime(1999) })
    expect(FakeSocket.opened).toHaveLength(2)
    act(() => { vi.advanceTimersByTime(1) })
    expect(FakeSocket.opened).toHaveLength(3)

    // A connection that opens resets the delay to one second.
    act(() => latest().onopen?.())
    act(() => latest().close())
    act(() => { vi.advanceTimersByTime(1000) })
    expect(FakeSocket.opened).toHaveLength(4)
  })

  it('never waits longer than fifteen seconds between attempts', () => {
    mount()
    for (let i = 0; i < 8; i++) {
      act(() => latest().close())
      act(() => { vi.advanceTimersByTime(15_000) })
    }
    expect(FakeSocket.opened).toHaveLength(9)
  })

  it('treats a socket error as a lost connection', () => {
    const { onStatusChange } = mount()
    act(() => latest().onerror?.())
    expect(latest().closed).toBe(true)
    expect(onStatusChange).toHaveBeenLastCalledWith('disconnected')
  })

  it('retries when the browser refuses to open the socket', () => {
    FakeSocket.failToConstruct = true
    const { onStatusChange } = mount()
    expect(onStatusChange).toHaveBeenLastCalledWith('disconnected')

    FakeSocket.failToConstruct = false
    act(() => { vi.advanceTimersByTime(1000) })
    expect(FakeSocket.opened).toHaveLength(1)
  })

  it('closes the socket and stops reconnecting when the app is left', () => {
    const { unmount, onStatusChange } = mount()
    const socket = latest()
    unmount()
    expect(socket.closed).toBe(true)

    const calls = onStatusChange.mock.calls.length
    act(() => { vi.advanceTimersByTime(60_000) })
    expect(FakeSocket.opened).toHaveLength(1)
    expect(onStatusChange).toHaveBeenCalledTimes(calls)
  })

  it('uses a secure socket on an https page', () => {
    vi.stubGlobal('location', { protocol: 'https:', host: 'lab.example' })
    mount()
    expect(latest().url).toBe('wss://lab.example/api/v2/ws')
  })
})
