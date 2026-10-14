// SPDX-License-Identifier: Apache-2.0
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { describe, expect, it, vi } from 'vitest'
import { ConfirmDialog, type ConfirmRequest } from './ConfirmDialog'

const request = (onConfirm = vi.fn()): ConfirmRequest => ({ title: 'Reset the lab?', message: 'Everything goes.', confirmLabel: 'Reset', onConfirm })

describe('ConfirmDialog', () => {
  it('shows nothing without a request', () => {
    const { container } = render(<ConfirmDialog request={null} onClose={vi.fn()} />)
    expect(container).toBeEmptyDOMElement()
  })

  it('asks, with focus on Cancel, and confirms only on the confirm button', async () => {
    const onConfirm = vi.fn()
    const onClose = vi.fn()
    render(<ConfirmDialog request={request(onConfirm)} onClose={onClose} />)
    expect(screen.getByRole('alertdialog', { name: 'Reset the lab?' })).toHaveTextContent('Everything goes.')
    expect(screen.getByRole('button', { name: 'Cancel' })).toHaveFocus()

    await userEvent.setup().click(screen.getByRole('button', { name: 'Reset' }))
    expect(onClose).toHaveBeenCalled()
    expect(onConfirm).toHaveBeenCalled()
  })

  it.each([
    ['Cancel', async () => userEvent.setup().click(screen.getByRole('button', { name: 'Cancel' }))],
    ['Escape', async () => userEvent.setup().keyboard('{Escape}')],
    ['a click outside the dialog', async () => userEvent.setup().click(screen.getByRole('presentation'))],
  ])('closes without confirming on %s', async (_, act) => {
    const onConfirm = vi.fn()
    const onClose = vi.fn()
    render(<ConfirmDialog request={request(onConfirm)} onClose={onClose} />)
    await act()
    expect(onClose).toHaveBeenCalled()
    expect(onConfirm).not.toHaveBeenCalled()
  })

  it('does not close on a click inside the dialog', async () => {
    const onClose = vi.fn()
    render(<ConfirmDialog request={request()} onClose={onClose} />)
    await userEvent.setup().click(screen.getByText('Everything goes.'))
    expect(onClose).not.toHaveBeenCalled()
  })
})
