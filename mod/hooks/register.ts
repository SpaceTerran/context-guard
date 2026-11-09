// Context Guard's helper inside each Claude Code session.
//
// Context Guard (the menu bar app and its hooks) asks a session to save when it gets big. What
// follows is decided by its program, `context-guard mod`, which reads the transcript and holds the
// rules: ask Haiku whether the session has finished saving, compact it, then send the continue
// message. Every 10 seconds this module asks the program for the next step, does it, and reports
// what happened. It also tells the program when each turn of the conversation starts and ends. It
// keeps no rules of its own.
import type { EngineInterface, Register } from 'claude-code'

/** How often the program is asked for the next step. */
const EVERY_MS = 10_000
/** How long to wait before looking again when the program isn't installed. */
const NOT_INSTALLED_WAIT_MS = 60_000
/** Steps in one go, so a "ready" verdict is acted on at once rather than 10 seconds later. */
const MAX_STEPS = 4
/** Longer than the program's own 10-second limit. */
const PROGRAM_TIMEOUT_MS = 15_000
/** A turn waits for its start to be noted, so this is short. */
const NOTE_TIMEOUT_MS = 5_000

/**
 * Runs `context-guard mod <command>` (the command is `$0`): the installed program, or the one
 * CONTEXT_GUARD_PROGRAM names (the live tests use that). Exits 127 when there is none.
 */
const RUN =
  'f="${CONTEXT_GUARD_PROGRAM:-$HOME/.claude/hooks/context-guard/context-guard}"; [ -x "$f" ] || exit 127; exec "$f" mod "$0"'
const NOT_INSTALLED = 127

/** What the program asks for. */
type Step =
  | { action: 'none' }
  | { action: 'judge'; nonce: string; mark: number; prompt: string; model: string; maxTokens: number; timeoutMs: number }
  | { action: 'compact'; nonce: string }
  | { action: 'continue'; nonce: string; text: string }

/** What happened, as the program reads it. */
type Outcome = {
  kind: 'judged' | 'judgeFailed' | 'compacted' | 'compactSkipped' | 'compactFailed' | 'continueFailed'
  mark?: number
  text?: string
  error?: string
  tokensBefore?: number
  tokensAfter?: number
}

// The module's own, so a reload starts them over.
let guarding = false
let busy = false
let waitUntil = 0
let judging: AbortController | undefined

export const register: Register = (on) => {
  on('session.start', async ($, e, next) => {
    const started = await next(e)
    // Only a session a person works in: not `claude -p`, the SDK or another program's helper.
    guarding = e.isInteractive && e.surface === 'terminal'
    if (guarding) $.clock.every(EVERY_MS, () => run($))
    return started
  })

  // Claude Code's registry says "busy" both while a turn runs and while agents it started run in
  // the background between turns. Woken mid-turn, a session ignores the message, so the program
  // needs to know which. A turn's start is noted before it runs; its end, after.
  on('prompt.submit', async ($, e, next) => {
    // A prompt typed while nothing runs: the turn counts from Enter, as the settings hooks that
    // run before its start can take a while. Typed during a turn, it joins that one.
    const starts = guarding && e.turnId === undefined && e.command === undefined
    if (starts) await note($, true)
    const entered = await next(e)
    if (starts && entered.drop !== undefined) await note($, false)
    return entered
  })

  on('turn.start', async ($, e, next) => {
    // An agent's turns are its own; only the conversation's count.
    if (guarding && e.agentId === undefined) await note($, true)
    return next(e)
  })

  on('turn.complete', async ($, e, next) => {
    const done = await next(e)
    if (guarding && e.agentId === undefined) await note($, false)
    return done
  })

  // `/clear` ends the conversation, not the process, so the timer goes on: each step reads the
  // session id afresh. A question to Haiku about the old conversation stops here.
  on('session.end', async (_, e, next) => {
    judging?.abort()
    return next(e)
  })
}

/** One go: the next step and any that follow at once. Never two at the same time. */
async function run($: EngineInterface): Promise<void> {
  if (busy) return
  busy = true
  try {
    if ((await $.clock.now()) < waitUntil) return
    for (let i = 0; i < MAX_STEPS; i++) {
      if (!(await step($))) break
    }
  } catch (err) {
    $.ui.log(`Context Guard: ${describe(err)}`, { to: 'debug' })
  } finally {
    busy = false
  }
}

/** Asks the program for the next step and does it. True when the program wants the next one now. */
async function step($: EngineInterface): Promise<boolean> {
  const sessionId = await $.session.id()
  const agents = (await $.agent.list()).filter(
    (a) => a.status === 'pending' || a.status === 'running' || a.status === 'waiting',
  ).length
  const next = (await program($, 'tick', { sessionId, agents, draft: await hasDraft($) })) as Step | undefined

  let outcome: Outcome | undefined
  switch (next?.action) {
    case 'judge':
      outcome = await judge($, next)
      break
    case 'compact':
      outcome = await compact($)
      break
    case 'continue':
      outcome = await send($, next.text)
      break
    default:
      return false
  }
  if (outcome === undefined) return false
  const answer = await program($, 'report', { sessionId, nonce: next.nonce, ...outcome })
  return answer?.again === true
}

/** Asks Haiku whether the session has finished saving. */
async function judge($: EngineInterface, ask: Extract<Step, { action: 'judge' }>): Promise<Outcome> {
  const stop = new AbortController()
  judging = stop
  try {
    const r = await $.model.complete(
      { model: ask.model, prompt: ask.prompt, maxTokens: ask.maxTokens, timeoutMs: ask.timeoutMs },
      { signal: stop.signal },
    )
    if (r.isAnswered) return { kind: 'judged', mark: ask.mark, text: r.text }
    const error = r.reason === 'api-error' ? `API error ${r.status ?? 'with no response'} (${r.error})` : r.reason
    return { kind: 'judgeFailed', mark: ask.mark, error }
  } catch (err) {
    return { kind: 'judgeFailed', mark: ask.mark, error: describe(err) }
  } finally {
    if (judging === stop) judging = undefined
  }
}

/** Compacts the session, as `/compact` does. */
async function compact($: EngineInterface): Promise<Outcome> {
  try {
    const r = await $.session.compact()
    if (r.skip !== undefined) return { kind: 'compactSkipped', error: r.skip }
    return { kind: 'compacted', tokensBefore: r.tokensBefore, tokensAfter: r.tokensAfter }
  } catch (err) {
    // A turn that started in the meantime refuses it.
    return { kind: 'compactFailed', error: describe(err) }
  }
}

/** Sends the continue message as the person's own words. Nothing to report when it went in. */
async function send($: EngineInterface, text: string): Promise<Outcome | undefined> {
  // Something typed since the program looked means the person has taken over.
  if (await hasDraft($)) return { kind: 'continueFailed', error: 'something is typed in the prompt box' }
  try {
    const r = await $.prompt.submit({ text, asUser: true })
    return r.drop === undefined ? undefined : { kind: 'continueFailed', error: r.drop }
  } catch (err) {
    return { kind: 'continueFailed', error: describe(err) }
  }
}

/** Tells the program a turn of the conversation started or ended. Never stops the turn. */
async function note($: EngineInterface, active: boolean): Promise<void> {
  try {
    await program($, 'turn', { sessionId: await $.session.id(), active }, NOTE_TIMEOUT_MS)
  } catch (err) {
    $.ui.log(`Context Guard: ${describe(err)}`, { to: 'debug' })
  }
}

/** Whether anything is typed in the prompt box; undefined when it can't be read. */
async function hasDraft($: EngineInterface): Promise<boolean | undefined> {
  try {
    return (await $.prompt.read()).text.trim() !== ''
  } catch {
    return undefined
  }
}

/** Runs `context-guard mod <command>` with `input` as JSON and returns its JSON answer. */
async function program(
  $: EngineInterface,
  command: 'tick' | 'report' | 'turn',
  input: object,
  timeoutMs = PROGRAM_TIMEOUT_MS,
): Promise<Record<string, unknown> | undefined> {
  const r = await $.process.run(['/bin/sh', '-c', RUN, command], {
    stdin: JSON.stringify(input),
    timeoutMs,
    // The session's folder may be gone (a removed worktree), and the program doesn't need it.
    cwd: '/',
  })
  if (r.exitCode === NOT_INSTALLED) {
    waitUntil = (await $.clock.now()) + NOT_INSTALLED_WAIT_MS
    return undefined
  }
  if (r.exitCode !== 0) throw new Error(`context-guard mod ${command} exited ${r.exitCode}: ${r.stderr.trim()}`)
  try {
    const answer: unknown = JSON.parse(r.stdout)
    return typeof answer === 'object' && answer !== null ? (answer as Record<string, unknown>) : undefined
  } catch {
    return undefined
  }
}

function describe(err: unknown): string {
  return err instanceof Error ? err.message : String(err)
}
