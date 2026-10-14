// SPDX-License-Identifier: Apache-2.0
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { NotificationList } from './Notification'
import type { Notification } from '../types'

const note = (id: number, level: Notification['level'], title: string, detail?: string): Notification =>
  ({ id, level, title, detail }) as Notification

describe('NotificationList', () => {
  it('renders nothing when there is nothing to say', () => {
    const { container } = render(<NotificationList items={[]} onDismiss={vi.fn()} />)
    expect(container).toBeEmptyDOMElement()
  })

  it('announces an error as an alert and anything else as a status', () => {
    render(<NotificationList items={[
      note(1, 'error', 'Install failed', 'helm timed out'),
      note(2, 'success', 'Installed'),
      note(3, 'info', 'Reconnected'),
    ]} onDismiss={vi.fn()} />)
    expect(screen.getByRole('alert')).toHaveTextContent('Install failed')
    expect(screen.getByRole('alert')).toHaveTextContent('helm timed out')
    expect(screen.getAllByRole('status').map(n => n.textContent)).toEqual(['Installed', 'Reconnected'])
  })

  it('dismisses the notification whose close button is pressed', async () => {
    const onDismiss = vi.fn()
    render(<NotificationList items={[note(7, 'info', 'First'), note(8, 'info', 'Second')]} onDismiss={onDismiss} />)
    await userEvent.setup().click(screen.getAllByRole('button', { name: 'Dismiss notification' })[1])
    expect(onDismiss).toHaveBeenCalledWith(8)
  })

  it.each([
    { count: 6, earlier: '+1 earlier notification' },
    { count: 8, earlier: '+3 earlier notifications' },
  ])('shows the newest five of $count and counts the rest', ({ count, earlier }) => {
    const items = Array.from({ length: count }, (_, i) => note(i + 1, 'info', `Note ${i + 1}`))
    render(<NotificationList items={items} onDismiss={vi.fn()} />)
    expect(screen.getAllByRole('status')).toHaveLength(5)
    expect(screen.getByText(`Note ${count}`)).toBeInTheDocument()
    expect(screen.queryByText('Note 1')).not.toBeInTheDocument()
    expect(screen.getByText(earlier)).toBeInTheDocument()
  })
})
