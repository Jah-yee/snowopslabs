// SPDX-License-Identifier: Apache-2.0
import { act, renderHook } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { THEME_STORAGE_KEY } from '../lib/theme'
import { useTheme } from './useTheme'

/** A matchMedia the test controls: the OS prefers light or dark, and can flip. */
function stubSystem(prefersLight: boolean) {
  const listeners = new Set<() => void>()
  const mq = {
    matches: prefersLight,
    addEventListener: (_: string, fn: () => void) => listeners.add(fn),
    removeEventListener: (_: string, fn: () => void) => listeners.delete(fn),
  }
  vi.stubGlobal('matchMedia', () => mq)
  return {
    flip(nowLight: boolean) {
      mq.matches = nowLight
      listeners.forEach(fn => fn())
    },
    listening: () => listeners.size,
  }
}

const applied = () => document.documentElement.getAttribute('data-theme')

describe('useTheme', () => {
  beforeEach(() => {
    localStorage.clear()
    document.documentElement.removeAttribute('data-theme')
  })
  afterEach(() => {
    vi.unstubAllGlobals()
  })

  it('follows the system when nothing is stored', () => {
    stubSystem(true)
    const { result } = renderHook(() => useTheme())
    expect(result.current.theme).toBe('system')
    expect(result.current.resolved).toBe('light')
    expect(applied()).toBe('light')
  })

  it('uses the stored preference over the system', () => {
    stubSystem(true)
    localStorage.setItem(THEME_STORAGE_KEY, 'dark')
    const { result } = renderHook(() => useTheme())
    expect(result.current.theme).toBe('dark')
    expect(applied()).toBe('dark')
  })

  it('falls back to the system for a stored value that is not a theme', () => {
    stubSystem(false)
    localStorage.setItem(THEME_STORAGE_KEY, 'neon')
    const { result } = renderHook(() => useTheme())
    expect(result.current.theme).toBe('system')
    expect(result.current.resolved).toBe('dark')
  })

  it('applies and remembers a choice', () => {
    stubSystem(false)
    const { result } = renderHook(() => useTheme())
    act(() => result.current.setTheme('light'))

    expect(result.current.theme).toBe('light')
    expect(applied()).toBe('light')
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe('light')
  })

  it('follows the system live while set to system, and stops once a theme is chosen', () => {
    const system = stubSystem(false)
    const { result } = renderHook(() => useTheme())
    expect(applied()).toBe('dark')

    act(() => system.flip(true))
    expect(applied()).toBe('light')

    act(() => result.current.setTheme('dark'))
    expect(system.listening()).toBe(0)
    act(() => system.flip(true))
    expect(applied()).toBe('dark')
  })

  it('stops listening to the system when the app is left', () => {
    const system = stubSystem(false)
    const { unmount } = renderHook(() => useTheme())
    expect(system.listening()).toBe(1)
    unmount()
    expect(system.listening()).toBe(0)
  })
})
