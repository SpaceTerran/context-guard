import { expect, mock, test } from 'claude-code/testing'
import type { Engine } from 'claude-code/testing'
import type {
  AgentInfo,
  ModelCompleteInput,
  ModelCompleteResult,
  On,
  PromptSubmitInput,
  SessionCompactResult,
  SessionMessage,
} from 'claude-code'

type Input = Record<string, unknown>

/** The world beneath the mod: the program, Haiku, the session and its prompt box. */
type World = {
  sessionId: string
  agents: AgentInfo[]
  /** What the prompt box holds, read afresh each time. */
  draft: () => string
  /** The program's exit code (127 means it isn't installed). */
  exitCode: number
  /** What the program answers to `mod tick`, one per call, then "none". */
  steps: unknown[]
  /** What it answers to `mod report`, one per call, then "no more now". */
  replies: unknown[]
  /** Each run of the program: the command (`tick`, `report` or `turn`), what it read and where it ran. */
  runs: { command: string; input: Input; argv: readonly string[]; cwd?: string; timeoutMs?: number }[]
  asked: ModelCompleteInput[]
  model: () => ModelCompleteResult | Promise<ModelCompleteResult>
  compactions: number
  compact: () => SessionCompactResult | Promise<SessionCompactResult>
  submitted: PromptSubmitInput[]
  /** Why the session refuses a prompt, if it does. */
  drop?: string
}

const SUMMARY: SessionMessage = { role: 'user', text: 'This session is being continued…', toolUses: [] }
const NOTHING = { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 }
const USAGE = { input_tokens: 900, output_tokens: 20, cache_read_input_tokens: 0, cache_creation_input_tokens: 0 }
/** Enter at the prompt. */
const TYPED = { kind: 'composer' } as const
const JUDGE = { action: 'judge', nonce: 'cg-1', mark: 4200, prompt: 'Has it finished?', model: 'haiku', maxTokens: 300, timeoutMs: 30_000 }

function world(on: On): World {
  const w: World = {
    sessionId: 's1',
    agents: [],
    draft: () => '',
    exitCode: 0,
    steps: [],
    replies: [],
    runs: [],
    asked: [],
    model: () => ({ isAnswered: true, text: '{"verdict":"ready","reason":"pushed"}', usage: USAGE }),
    compactions: 0,
    compact: () => ({ messages: [SUMMARY], tokensBefore: 311_000, tokensAfter: 24_000 }),
    submitted: [],
  }
  on('session.start', (_, e) => ({ cwd: e.cwd }))
  on('session.end', (_, e) => ({ sessionId: e.sessionId }))
  on('session.id', () => ({ value: w.sessionId }))
  on('agent.list', () => ({ value: w.agents }))
  on('prompt.read', () => {
    const text = w.draft()
    return { value: { text, cursor: text.length } }
  })
  on('process.run', (_, e) => {
    const command = e.argv[e.argv.length - 1] ?? ''
    w.runs.push({ command, input: JSON.parse(e.init?.stdin ?? '{}'), argv: e.argv, cwd: e.init?.cwd, timeoutMs: e.init?.timeoutMs })
    const answer =
      command === 'tick' ? (w.steps.shift() ?? { action: 'none' })
      : command === 'report' ? (w.replies.shift() ?? { again: false })
      : {}
    const stdout = w.exitCode === 0 ? JSON.stringify(answer) + '\n' : ''
    return { value: { exitCode: w.exitCode, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }
  })
  on('model.complete', async (_, e, next) => {
    w.asked.push(e)
    // As the engine does: a call whose caller aborts it resolves "aborted", whatever was on its way.
    const aborted = new Promise<ModelCompleteResult>((resolve) =>
      next.signal.addEventListener('abort', () => resolve({ isAnswered: false, reason: 'aborted', usage: NOTHING })),
    )
    return { value: await Promise.race([w.model(), aborted]) }
  })
  on('session.compact', async () => {
    w.compactions++
    return w.compact()
  })
  on('prompt.submit', (_, e) => {
    w.submitted.push(e)
    return w.drop === undefined ? { text: e.text, origin: e.origin } : { drop: w.drop }
  })
  on('turn.start', (_, e) => ({ turnId: e.turnId }))
  on('turn.complete', () => ({ text: 'done' }))
  return w
}

async function start($: Engine, isInteractive = true): Promise<void> {
  await $.session.start({ cwd: '/Users/x/code', surface: isInteractive ? 'terminal' : null, isInteractive })
}

function commands(w: World): string[] {
  return w.runs.map((r) => r.command)
}

/** What the program was told of turns: true for a start, false for an end. */
function notes(w: World): unknown[] {
  return w.runs.filter((r) => r.command === 'turn').map((r) => r.input.active)
}

test('every 10 seconds it tells the program how the session stands', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  w.agents = [
    { id: 'a1', description: 'build', type: 'general-purpose', status: 'running' },
    { id: 'a2', description: 'tests', type: 'general-purpose', status: 'waiting' },
    { id: 'a3', description: 'done', type: 'general-purpose', status: 'completed' },
  ]
  w.draft = () => '   '
  await start($)
  await clock.advance(9_999)
  expect(w.runs).toEqual([])
  await clock.advance(1)
  expect(w.runs).toHaveLength(1)
  const run = w.runs[0]!
  expect(run.argv.slice(0, 2)).toEqual(['/bin/sh', '-c'])
  expect(run.argv[2]).toContain('$HOME/.claude/hooks/context-guard/context-guard')
  expect(run.command).toBe('tick')
  expect(run.input).toEqual({ sessionId: 's1', agents: 2, draft: false })
  expect(run.cwd).toBe('/')
  expect(run.timeoutMs).toBe(15_000)
  await clock.advance(10_000)
  expect(commands(w)).toEqual(['tick', 'tick'])
})

test('nothing runs in a session nobody types into', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  await start($, false)
  await clock.advance(60_000)
  expect(w.runs).toEqual([])
})

test('a ready verdict is compacted at once, and the counts go back', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  w.steps = [JUDGE, { action: 'compact', nonce: 'cg-1' }]
  w.replies = [{ again: true }, { again: false }]
  await start($)
  await clock.advance(10_000)

  expect(w.asked).toEqual([{ model: 'haiku', prompt: 'Has it finished?', maxTokens: 300, timeoutMs: 30_000 }])
  expect(commands(w)).toEqual(['tick', 'report', 'tick', 'report'])
  expect(w.runs[1]!.input).toEqual({
    sessionId: 's1', nonce: 'cg-1', kind: 'judged', mark: 4200, text: '{"verdict":"ready","reason":"pushed"}',
  })
  expect(w.compactions).toBe(1)
  expect(w.runs[3]!.input).toEqual({ sessionId: 's1', nonce: 'cg-1', kind: 'compacted', tokensBefore: 311_000, tokensAfter: 24_000 })
})

test('one go takes at most four steps', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  w.steps = [JUDGE, JUDGE, JUDGE, JUDGE, JUDGE]
  w.replies = [{ again: true }, { again: true }, { again: true }, { again: true }, { again: true }]
  await start($)
  await clock.advance(10_000)
  expect(w.asked).toHaveLength(4)
  await clock.advance(10_000)
  expect(w.asked).toHaveLength(5)
})

test("Haiku not answering is reported, with the reason", async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  w.steps = [JUDGE]
  w.model = () => ({ isAnswered: false, reason: 'api-error', status: 529, error: 'overloaded', usage: USAGE })
  await start($)
  await clock.advance(10_000)
  expect(w.runs[1]!.input).toEqual({ sessionId: 's1', nonce: 'cg-1', kind: 'judgeFailed', mark: 4200, error: 'API error 529 (overloaded)' })
})

test('a compaction that is refused or skipped is reported', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  w.steps = [{ action: 'compact', nonce: 'cg-1' }, { action: 'compact', nonce: 'cg-1' }]
  w.compact = () => {
    throw new Error('a turn is running')
  }
  await start($)
  await clock.advance(10_000)
  expect(w.runs[1]!.input).toMatchObject({ sessionId: 's1', nonce: 'cg-1', kind: 'compactFailed' })
  expect(w.runs[1]!.input.error).toEqual(expect.any(String))

  w.compact = () => ({ skip: 'a PreCompact hook said no' })
  await clock.advance(10_000)
  expect(w.runs[3]!.input).toEqual({ sessionId: 's1', nonce: 'cg-1', kind: 'compactSkipped', error: 'a PreCompact hook said no' })
})

test("the continue message goes in as the person's own words", async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  w.steps = [{ action: 'continue', nonce: 'cg-1', text: 'continue now' }]
  await start($)
  await clock.advance(10_000)
  expect(w.submitted).toHaveLength(1)
  expect(w.submitted[0]).toMatchObject({ text: 'continue now', origin: { kind: 'plugin', asUser: true } })
  expect(commands(w)).toEqual(['tick'])
})

test('something typed in the prompt box stops the continue message', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  w.steps = [{ action: 'continue', nonce: 'cg-1', text: 'continue now' }]
  // The program saw an empty box; the person started typing before the message went in.
  let reads = 0
  w.draft = () => (reads++ === 0 ? '' : 'actually, first')
  await start($)
  await clock.advance(10_000)
  expect(w.submitted).toEqual([])
  expect(w.runs[0]!.input).toMatchObject({ draft: false })
  expect(w.runs[1]!.input).toEqual({ sessionId: 's1', nonce: 'cg-1', kind: 'continueFailed', error: 'something is typed in the prompt box' })
})

test('without the program it looks again a minute later', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  w.exitCode = 127
  await start($)
  await clock.advance(10_000)
  expect(w.runs).toHaveLength(1)
  await clock.advance(50_000)
  expect(w.runs).toHaveLength(1)
  w.exitCode = 0
  await clock.advance(10_000)
  expect(w.runs).toHaveLength(2)
})

test('a program that fails is tried again at the next tick', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  w.exitCode = 1
  await start($)
  await clock.advance(20_000)
  expect(commands(w)).toEqual(['tick', 'tick'])
})

test('a slow step is never run twice, and /clear moves on to the new conversation', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  w.steps = [JUDGE]
  let answer: (r: ModelCompleteResult) => void = () => {}
  w.model = () => new Promise((resolve) => (answer = resolve))
  await start($)
  await clock.advance(30_000)
  expect(commands(w)).toEqual(['tick'])
  expect(w.asked).toHaveLength(1)

  // /clear ends the conversation while Haiku is still thinking about it.
  await $.session.end({ reason: 'clear', sessionId: 's1', resume: { id: 's1' } })
  await clock.settle()
  expect(w.runs[1]!.input).toEqual({ sessionId: 's1', nonce: 'cg-1', kind: 'judgeFailed', mark: 4200, error: 'aborted' })
  answer({ isAnswered: true, text: 'late', usage: USAGE })
  await clock.settle()
  expect(w.runs).toHaveLength(2)

  w.sessionId = 's2'
  await clock.advance(10_000)
  expect(w.runs[2]!.input).toMatchObject({ sessionId: 's2' })
})

test('an answer this version does not know is left alone', async ($, on) => {
  const clock = mock.clock(on)
  const w = world(on)
  w.steps = [{ action: 'something-newer', nonce: 'cg-1' }]
  await start($)
  await clock.advance(10_000)
  expect(commands(w)).toEqual(['tick'])
})

test("the conversation's turns are noted as they start and end", async ($, on) => {
  mock.clock(on)
  const w = world(on)
  await start($)
  await $.turn.start({ text: 'hi', turnId: 't1' })
  expect(w.runs).toHaveLength(1)
  expect(w.runs[0]!.input).toEqual({ sessionId: 's1', active: true })
  expect(w.runs[0]!.timeoutMs).toBe(5_000)
  await $.turn.complete({ turnId: 't1', answer: 'done', reason: 'answer', durationMs: 900, isAborted: false })
  expect(notes(w)).toEqual([true, false])
  await $.turn.complete({ turnId: 't2', answer: '', reason: 'aborted', durationMs: 900, isAborted: true })
  expect(notes(w)).toEqual([true, false, false])
})

test("an agent's turns are not the conversation's", async ($, on) => {
  mock.clock(on)
  const w = world(on)
  await start($)
  await $.turn.start({ text: 'build it', turnId: 't1', agentId: 'a1' })
  await $.turn.complete({ turnId: 't1', agentId: 'a1', answer: 'done', reason: 'answer', durationMs: 900, isAborted: false })
  expect(w.runs).toEqual([])
})

test('a prompt typed while nothing runs counts from Enter', async ($, on) => {
  mock.clock(on)
  const w = world(on)
  await start($)
  await $.prompt.submit({ text: 'next', wait: false, origin: TYPED })
  expect(notes(w)).toEqual([true])

  // Typed during a turn, it joins that turn; a slash command's own turn is noted when it starts.
  await $.prompt.submit({ text: 'also', wait: false, origin: TYPED, turnId: 't1' })
  await $.prompt.submit({ text: '/status', wait: false, origin: TYPED, command: { name: 'status', args: '' } })
  expect(notes(w)).toEqual([true])
})

test('a prompt the session refuses starts no turn', async ($, on) => {
  mock.clock(on)
  const w = world(on)
  w.drop = 'a UserPromptSubmit hook said no'
  await start($)
  await $.prompt.submit({ text: 'next', wait: false, origin: TYPED })
  expect(notes(w)).toEqual([true, false])
})

test('nothing is noted in a session nobody types into', async ($, on) => {
  mock.clock(on)
  const w = world(on)
  await start($, false)
  await $.prompt.submit({ text: 'next', wait: false, origin: TYPED })
  await $.turn.start({ text: 'next', turnId: 't1' })
  await $.turn.complete({ turnId: 't1', answer: 'done', reason: 'answer', durationMs: 900, isAborted: false })
  expect(w.runs).toEqual([])
})

test('a note that fails never stops the turn', async ($, on) => {
  mock.clock(on)
  const w = world(on)
  w.exitCode = 1
  await start($)
  expect(await $.turn.start({ text: 'hi', turnId: 't1' })).toEqual({ turnId: 't1' })
  expect(notes(w)).toEqual([true])
})
