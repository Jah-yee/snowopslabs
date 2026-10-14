// SPDX-License-Identifier: Apache-2.0
import { describe, expect, it } from 'vitest'
import { errMessage } from './errors'

describe('errMessage', () => {
  it.each([
    ['an Error', new Error('the cluster is unreachable'), 'the cluster is unreachable'],
    ['a string', 'plain text', 'plain text'],
    ['a number', 404, '404'],
    ['nothing', undefined, 'undefined'],
  ])('reads the message from %s', (_, thrown, want) => {
    expect(errMessage(thrown)).toBe(want)
  })
})
