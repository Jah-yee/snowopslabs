// SPDX-License-Identifier: Apache-2.0
//
// The server's real answers, for UI tests.
//
// The Go contract suite (internal/httpapi/server_contract_rows_test.go) writes
// one golden file per route into internal/httpapi/testdata/contract, with an
// index of which request each answers. serveContract() replaces fetch with a
// stand-in that answers every request from those files, so a view rendered
// under it goes through the real API client and reads exactly what the server
// sends. A Go change that renames or drops a field then fails a UI test here.

import fs from 'node:fs'
import path from 'node:path'
import { vi } from 'vitest'

const DIR = path.resolve(__dirname, '../../../internal/httpapi/testdata/contract')
const BASE = '/api/v2'

interface Entry {
  method: string
  route: string
  status: number
  golden: string
}

const index = JSON.parse(fs.readFileSync(path.join(DIR, 'index.json'), 'utf8')) as Entry[]

/** A route template as a pattern: "/apps/{name}/detail" matches "/apps/x/detail". */
function pattern(route: string): RegExp {
  return new RegExp('^' + route.replace(/\{[^}]+\}/g, '[^/]+') + '$')
}

/** The entry that answers a request. A route with no variables wins over a
 *  template, as it does in the server's router ("/challenges/status" is not
 *  "/challenges/{name}"). */
function find(method: string, pathname: string): Entry | undefined {
  const candidates = index.filter(e => e.method === method && pattern(e.route).test(pathname))
  return candidates.find(e => !e.route.includes('{')) ?? candidates[0]
}

/** Golden files hold placeholders where a real answer has a time, a job ID or
 *  the lab's root directory. */
function fill(text: string): string {
  return text
    .split('"<time>"').join('"2026-05-01T10:00:00Z"')
    .split('"<job>"').join('"job-1"')
    .split('<root>').join('/lab')
}

/** The parsed golden answer for a route, e.g. golden('GET', '/apps'). */
export function golden<T = unknown>(method: string, route: string): T {
  const entry = index.find(e => e.method === method && e.route === route)
  if (!entry) throw new Error(`the contract has no row for ${method} ${route}`)
  return JSON.parse(fill(fs.readFileSync(path.join(DIR, entry.golden), 'utf8'))) as T
}

export interface ContractCall {
  method: string
  /** The path under /api/v2, without the query. */
  path: string
  query: URLSearchParams
  /** The parsed JSON body, or undefined when there was none. */
  body: unknown
}

export interface ContractServer {
  /** Every request made, as "METHOD /path". */
  requests: string[]
  /** Every request made, with its query and body. */
  calls: ContractCall[]
  /** Requests no golden answers. A test asserts this is empty. */
  unanswered: string[]
  /** Answer one request differently, for a state the goldens do not hold. */
  override(method: string, pathname: string, status: number, body: unknown): void
  /** Answer successive requests with successive bodies; the last one repeats. */
  overrideEach(method: string, pathname: string, status: number, bodies: unknown[]): void
}

/** Replaces fetch for the current test with one that answers from the contract
 *  goldens. vi.unstubAllGlobals() in the test's cleanup restores the real one. */
export function serveContract(): ContractServer {
  const server: ContractServer & { overrides: Map<string, { status: number; bodies: unknown[] }> } = {
    requests: [],
    calls: [],
    unanswered: [],
    overrides: new Map(),
    override(method, pathname, status, body) {
      this.overrides.set(`${method} ${pathname}`, { status, bodies: [body] })
    },
    overrideEach(method, pathname, status, bodies) {
      this.overrides.set(`${method} ${pathname}`, { status, bodies: [...bodies] })
    },
  }

  const answer = (status: number, body: string) =>
    new Response(body, {
      status,
      headers: { 'Content-Type': status >= 400 ? 'application/problem+json' : 'application/json' },
    })

  vi.stubGlobal('fetch', async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = new URL(String(input), 'http://localhost')
    const method = (init?.method ?? 'GET').toUpperCase()
    const pathname = url.pathname.startsWith(BASE) ? url.pathname.slice(BASE.length) : url.pathname
    const key = `${method} ${pathname}`
    server.requests.push(key)
    const raw = typeof init?.body === 'string' ? init.body : undefined
    server.calls.push({ method, path: pathname, query: url.searchParams, body: raw ? JSON.parse(raw) : undefined })

    const custom = server.overrides.get(key)
    if (custom) {
      const body = custom.bodies.length > 1 ? custom.bodies.shift() : custom.bodies[0]
      return answer(custom.status, JSON.stringify(body))
    }

    const entry = find(method, pathname)
    if (!entry) {
      server.unanswered.push(key)
      return answer(404, JSON.stringify({ type: 'not_found', title: 'Not Found', status: 404, detail: `no contract row answers ${key}` }))
    }
    return answer(entry.status, fill(fs.readFileSync(path.join(DIR, entry.golden), 'utf8')))
  })
  return server
}

/** The paginated envelope list routes answer with. */
export function page<T>(items: T[]) {
  return { items }
}
