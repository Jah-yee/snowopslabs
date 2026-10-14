// SPDX-License-Identifier: Apache-2.0

import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { LogPanel } from './LogPanel'
import type { LogEntry } from '../types'

function entries(n: number): LogEntry[] {
  return Array.from({ length: n }, (_, i): LogEntry => ({
    id: i + 1,
    ts: `10:00:0${i}`,
    level: 'output',
    text: `line ${i + 1}`,
  }))
}

const toggle = () => screen.getByRole('button', { name: /output panel/i })
const heightVar = () => document.documentElement.style.getPropertyValue('--log-h')

describe('LogPanel', () => {
  it('starts collapsed and reserves only the header height', () => {
    render(<LogPanel entries={[]} onClear={vi.fn()} />)

    expect(toggle()).toHaveAttribute('aria-expanded', 'false')
    expect(toggle()).toHaveAccessibleName('Expand output panel')
    expect(screen.getByText('Command Output')).toBeInTheDocument()
    expect(heightVar()).toBe('40px')
  })

  it('opens when output starts and shows every line with its count', () => {
    const { rerender } = render(<LogPanel entries={[]} onClear={vi.fn()} />)

    rerender(<LogPanel entries={entries(2)} onClear={vi.fn()} />)

    expect(toggle()).toHaveAttribute('aria-expanded', 'true')
    expect(screen.getByText('Command Output (2)')).toBeInTheDocument()
    expect(screen.getByText('line 1')).toBeInTheDocument()
    expect(screen.getByText('line 2')).toBeInTheDocument()
    expect(heightVar()).toBe('260px')
  })

  it('stays collapsed once the user collapses it, even as more output arrives', async () => {
    const user = userEvent.setup()
    const { rerender } = render(<LogPanel entries={entries(1)} onClear={vi.fn()} />)
    expect(toggle()).toHaveAttribute('aria-expanded', 'true')

    await user.click(toggle())
    expect(toggle()).toHaveAttribute('aria-expanded', 'false')
    expect(screen.queryByText('line 1')).not.toBeInTheDocument()
    expect(heightVar()).toBe('40px')

    rerender(<LogPanel entries={entries(3)} onClear={vi.fn()} />)
    expect(toggle()).toHaveAttribute('aria-expanded', 'false')
    expect(screen.getByText('Command Output (3)')).toBeInTheDocument()
  })

  it('opens again for the first output after the panel is cleared', async () => {
    const user = userEvent.setup()
    const { rerender } = render(<LogPanel entries={entries(1)} onClear={vi.fn()} />)
    await user.click(toggle())

    rerender(<LogPanel entries={[]} onClear={vi.fn()} />)
    expect(toggle()).toHaveAttribute('aria-expanded', 'false')

    rerender(<LogPanel entries={entries(1)} onClear={vi.fn()} />)
    expect(toggle()).toHaveAttribute('aria-expanded', 'true')
  })

  it('toggles from the title as well as the chevron', async () => {
    const user = userEvent.setup()
    render(<LogPanel entries={[]} onClear={vi.fn()} />)
    const title = screen.getByRole('button', { name: /command output/i })

    await user.click(title)
    expect(title).toHaveAttribute('aria-expanded', 'true')
    await user.click(title)
    expect(title).toHaveAttribute('aria-expanded', 'false')
  })

  it('clears through the callback and reports the auto-scroll state', async () => {
    const user = userEvent.setup()
    const onClear = vi.fn()
    render(<LogPanel entries={entries(1)} onClear={onClear} />)

    await user.click(screen.getByRole('button', { name: 'Clear' }))
    expect(onClear).toHaveBeenCalledTimes(1)

    const autoScroll = screen.getByRole('button', { name: 'Auto-scroll' })
    expect(autoScroll).toHaveAttribute('aria-pressed', 'true')
    await user.click(autoScroll)
    expect(autoScroll).toHaveAttribute('aria-pressed', 'false')
  })
})

describe('LogPanel keyboard access', () => {
  // The output scrolls, so a keyboard user must be able to reach it to scroll.
  it('makes the output a focusable, named region', () => {
    render(<LogPanel entries={entries(3)} onClear={vi.fn()} />)
    const output = screen.getByRole('log', { name: 'Command output' })
    expect(output).toHaveAttribute('tabindex', '0')
    output.focus()
    expect(output).toHaveFocus()
  })
})
