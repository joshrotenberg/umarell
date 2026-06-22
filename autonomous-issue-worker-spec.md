# `<name>` — Autonomous Issue Worker
**Spec v0.3 · draft for iteration**
*v0.3: intake committed to direct polling — webhooks and the Notifications API considered and rejected; Intake.Webhook + Bandit dropped.*
*v0.2: runtime committed (Elixir/OTP on `claude_wrapper`); agent_workshop sunset; distribution via Burrito.*

> Working title TBD (Venetian). A BEAM coordinator that consumes well-specced GitHub issues, does the work locally on a Max-authed `claude`, and drives each issue through a GitHub-native lifecycle. GitHub is the durable state; the system holds only transient coordination.

---

## Runtime & stack — committed

- **Language:** Elixir / OTP.
- **Base:** builds on `claude_wrapper` (Hex) for prompt composition and `claude -p` execution. The coordinator — supervision, scheduler, intake, reconciler — is new, built directly on OTP. *(agent_workshop is sunset; not a dependency.)*
- **HTTP:** Req (GitHub client + polling). No inbound HTTP — intake is poll-only.
- **Config:** native Elixir config — `runtime.exs`/env for daemon settings (identity, intervals, caps, watched repos); per-repo policy is a file in each target repo (GitHub stays the source of truth). Heavy reliance on the config layer expected.
- **Observability:** `:telemetry` + OpenTelemetry export; structured logs. No UI.
- **Live console:** IEx into the running node for inspection / poking a stuck job — the "console" from earlier, *not* a REPL-as-interface.
- **Distribution:** single self-contained binary via Burrito (+ Tinfoil). Deferred until/unless the tool ships beyond personal use, but cheap when wanted.

The **GitHub contract (§5) stays language-agnostic.** If a distributable/generic version ever happens (Rust, per earlier), it implements a contract already proven here — Elixir-now doesn't foreclose Rust-later.

---

## 1. Core loop

Issue labeled ready → claimed → draft PR + commits → PR ready → *(CI green → merge/release, per repo)*. The system performs every step — but a human could perform any of them through normal GitHub instead.

## 2. Operating invariant

**Every transition the system makes is one a human can make through the GitHub UI.** Developer and agent are externally indistinguishable. This buys observability, human takeover, and audit for free, and forbids any private side-channel state. When a design question is ambiguous, the answer that preserves this invariant wins.

## 3. Scope

**In:** claim → implement → open/ready PR; ordering via native dependencies; park-on-blocked; crash recovery; pacing against a shared Max quota.

**Out (explicit):**

- **Merge & release** — per-repo GitHub settings, not ours.
- **Any UI / dashboard** — GitHub's issue/PR/Actions surface + process logs *are* the observability.
- **Any durable store / database** — GitHub is the state; BEAM is transient.
- **Cross-issue querying / reporting read-model** — until it demonstrably earns its place.
- **Multi-user / multi-tenant.**
- **Agent decisions beyond an issue's stated scope.** Drive to *ready + green*, then stop.

## 4. Architecture (high level)

```
        GitHub  (queue • durable state • observability)
          │  ▲                                   ▲
   poll   │  │ claim → draft → push → ready      │ CI + auto-merge/release
          ▼  │ (same calls a human makes)        │ (per-repo, GitHub's job)
   ┌──────────────┐
   │   INTAKE     │  Poller → state queries (ready issues, orphan PRs)
   └──────┬───────┘
          ▼
   ┌──────────────┐
   │ COORDINATION │  Scheduler/pacer → DynamicSupervisor → JobWorkers • Reconciler
   │   (BEAM)     │
   └──────┬───────┘
          ▼  one worker per claimed issue
   ┌──────────────┐
   │  EXECUTION   │  JobWorker → `claude` (Max-authed) on local hardware
   │  (per job)   │  → result envelope back onto the PR
   └──────────────┘
```

Three planes: **durable** lives in GitHub, **transient coordination** in BEAM, **execution** in local `claude` subprocesses. Lose the BEAM node and nothing durable is lost — the next poll re-derives all state from GitHub.

### Supervision tree

```
App.Supervisor (:one_for_one)
├── GitHub.Client      Req/Finch pool, GitHub-rate-limit aware
├── Scheduler          GenServer: claim predicate + throttle
├── JobSupervisor      DynamicSupervisor
│     └── JobWorker     one per in-flight issue, restart: :temporary
└── Intake.Poller      GenServer on interval; runs state queries; also the Reconciler's source
```

### Components (responsibilities)

- **Intake** — a poller that runs targeted GitHub *state queries* (ready issues per watched repo; orphaned draft PRs for the reconciler) on an interval, normalizes to `WorkEvent`, and de-dupes. Direct polling only — webhooks and the Notifications API were evaluated and rejected (see §5). A thin source seam is kept so another source could slot in later, but nothing else is built.
- **Scheduler / pacer** — the only decision-maker. Evaluates the claim predicate, enforces concurrency / working-hours / quota backoff, and claims. Holds no durable state — its inputs are GitHub + in-memory counters.
- **JobSupervisor → JobWorker** — `DynamicSupervisor`; one `JobWorker` per in-flight issue, `restart: :temporary` (a crashed job is recovered by the reconciler from GitHub, not by blind restart). The worker holds nothing durable: reads context at claim, runs, writes a transition back, exits.
- **Reconciler** — on boot and on every poll: open draft PRs by the agent identity = jobs that were in flight. Per orphan, decide resume / restart / park. Default conservative.

---

## 5. GitHub contract (precise)

The part we don't control, so it's pinned.

### State model

**Labels = the state machine.** Agent-state labels are mutually exclusive; exactly one is present while an issue is in the system. Every transition is a swap (remove old, add new).

| Label | Meaning | Set by | Cleared by |
|---|---|---|---|
| `agent:ready` | queued, eligible to claim | human / upstream automation when the spec is ready | scheduler on claim → `working` |
| `agent:working` | claimed, in progress | scheduler on claim | worker on finish / park |
| `agent:blocked` | parked; needs a human (decision / missing info / repeated failure); reason in comment | worker | human, by flipping back to `agent:ready` |

> Dependency-blocked is **not** a label — it's derived from native deps. Done is **not** a label — it's the issue closing.

**Assignment = the claim mutex.** Claiming = assigning the issue to the agent identity — the closest native primitive to a lock. (Not a true compare-and-swap; see §8.) A human grabbing the issue the normal way locks the agent out too. Labels carry *state*; assignment carries the *lock*.

**Dependencies = ordering.** Native "blocked by" (GA; in REST, webhooks, and `gh --json`). The scheduler reads **direct** blockers only — transitivity enforces itself down the chain. A dependency is satisfied when the blocking **issue is closed**. *(REST endpoint keys on the global issue ID, not the number; `gh issue view --json` sidesteps this for reads.)*

**PR lifecycle.** Draft = work in progress. Ready = implemented (CI running or passed). Issue closed = done (terminal).

**Comments = payload + transition detail.** Labels hold current state (lossy on history/why). The *why* and the *payload* — result envelope, parking question — live in structured PR/issue comments.

**Per-repo config = a file in the repo** (`.agent.toml` or similar): label names, working hours, concurrency, model/profile, allowed tools, done-predicate. Read at job start. Keeps the coordinator stateless about policy and keeps GitHub the source of truth even for config.

### Lifecycle

| Stage | GitHub state (human-identical) | Owns next transition |
|---|---|---|
| Queued | issue + `agent:ready`, conv-commit title, deps set | Scheduler (claims) |
| Claimed | assigned to agent identity, `agent:working` | JobWorker |
| In progress | draft PR open, commits pushed | JobWorker (local `claude`) |
| Blocked (dep) | a "blocked by" issue still open | GitHub → Scheduler (when blocker closes) |
| Blocked (human) | `agent:blocked` + comment | Human (flips to `agent:ready`) |
| Implemented | PR marked ready + result envelope | GitHub CI |
| Done | PR merged, issue closed | GitHub (per-repo auto-merge/release) — **not the system** |

### Block types — one predicate, two exclusion sources

| | Block source | Unblocks on | Scheduler role |
|---|---|---|---|
| Dependency | native "blocked by" | blocking issue **closes** | auto-resolves (next poll) |
| Human | agent parks (`agent:blocked`) | **human** flips label back | waits; never re-pulls |

### The claim predicate

Claim issue *i* iff **all** hold:

1. `i` has exactly one agent-state label, and it is `agent:ready`
2. `i` is unassigned (claimable)
3. every "blocked by" dependency of `i` is a **closed** issue
4. concurrency below the cap (global and/or per-repo)
5. inside configured working hours
6. quota budget available (not in backoff)

Blockers must be acyclic — a cycle is detected when evaluating and routed to `agent:blocked` + comment, else it deadlocks both sides forever.

### API surface

| Operation | REST / `gh` | Notes |
|---|---|---|
| Find ready issues | `GET /repos/{o}/{r}/issues?labels=agent:ready&state=open` | per-repo, conditional-request friendly |
| Read blockers | `gh issue view N --json` (dependency fields) | avoids the global-ID gotcha |
| Claim | `POST /issues/{n}/assignees` | not true CAS; see §8 |
| Swap state label | label add + remove | enforce exactly one agent-state label |
| Open draft PR | `gh pr create --draft` / `POST /pulls` `draft:true` | |
| Mark ready | `gh pr ready` / GraphQL `markPullRequestReadyForReview` | |
| Write payload | `POST /issues/{n}/comments` | result envelope / parking question |
| Detect orphans | `gh pr list --draft --author <agent> --json` | reconciler input |
| *(opt)* CI status | check-runs / status API | only if doing a Fix-CI loop |

### Intake — direct polling

The poller runs targeted **state queries**, not an event stream:

- ready work: `GET /repos/{o}/{r}/issues?labels=agent:ready&state=open` per watched repo (core API, supports conditional requests)
- reconciliation: `gh pr list --draft --author <agent>`

Use ETag / `If-Modified-Since` — 304s don't count against the rate limit, so idle polls are free. Prefer per-repo issue listing over the Search API (lower limit, weaker caching). The query *is* its own reconciliation: a missed tick self-heals on the next one.

**Rejected:** webhooks (need ingress + an at-least-once backstop you'd be polling for anyway; push latency is moot for an overnight batch) and the Notifications API (poll-based and ingress-free, but a broad activity firehose you'd filter down — the work queue wants a targeted state query, not "what changed"). Escalation order if latency ever matters: poll → Notifications API → webhooks.

### Auth

- **Execution:** `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token` — draws on the Max subscription. **Keep `ANTHROPIC_API_KEY` out of the environment** (it silently takes precedence and bills the API).
- **Contract ops:** GitHub credentials for the agent identity (App vs PAT/bot — open). This identity is what assignment-as-mutex keys on.

---

## 6. Execution (high level)

Each `JobWorker` invokes `claude` against a working checkout on local hardware (laptop / Meerkat), authed to Max. The inner build/test loop runs locally at full speed; CI is only the final gate. On completion the worker writes the result envelope to the PR and marks it ready — or parks the issue — then exits. `claude` is invoked through `claude_wrapper`'s composition layer (prompt assembled from issue body + context + done-predicate, then `claude -p`). The worker reports outcome through the §7 contract — **not** Claude-specific hooks — which keeps that seam clean and the generic-runner extraction latent.

## 7. The contract (typed in/out, high level)

- **Work item (in):** the issue *is* the spec — conventional-commit title, labels, native deps, and a body carrying acceptance criteria / constraints / done-predicate, plus a freeform section for what the schema can't hold.
- **Result envelope (out):** a structured PR comment — status (implemented / blocked / needs-human), summary of changes, any in-scope classification decisions made, cost/turns, test outcome.
- **Parking question (out, when blocked):** a structured comment stating the single open question crisply (+ options if any). A handoff back to Loop 1; keep it tight so the human's answer is fast.

## 8. Concurrency & pacing

The one component that's both ours and load-bearing, because Max is a pool shared with interactive use.

- **Concurrency cap** — global; optionally per-repo.
- **Working-hours gate** — default the runner to off-hours so a backlog sweep never starves interactive quota.
- **Quota-aware backoff** — catch the rate-limit signal from `claude` and slow, don't hammer.
- **Per-job `--max-budget-usd`** as a hard ceiling.
- **Claim race** — assignment isn't a true CAS. With a single poll source on a single instance, double-evaluation is unlikely; for correctness, still treat a failed/looped assignment as "lost the claim" and drop the job.

## 9. Crash recovery

No persistent worker state, so recovery = re-derivation. On boot/poll the reconciler lists open draft PRs by the agent identity — each is a job that didn't finish. Per orphan: **resume** (re-attach), **restart** (reset branch), or **park** (`agent:blocked` + comment) when ambiguous. The half-done PR is observable, so "park for a human" is always a safe fallback.

---

## 10. Open decisions

**Resolved:** runtime — Elixir/OTP on `claude_wrapper` (v0.2) · `claude` invocation — `claude_wrapper` composition layer (v0.2) · distribution — Burrito (v0.2) · **intake — direct polling (v0.3)**.

| Decision | Options | Notes |
|---|---|---|
| Agent identity | GitHub App / bot user + PAT | App = cleaner perms + higher rate limits; this is the assignment-mutex key |
| Concurrency model | global cap / per-repo cap / both | start global |
| Done-predicate | agent self-reports / CI-defined / both | who certifies "implemented" |
| Fix-CI loop | in scope / out | does the worker re-engage on red CI, or stop at ready? |
| Branch & PR naming | convention TBD | conv-commit-derived |
| Repo discovery | one config per repo / org-level default | how the system learns which repos to watch |
| Label namespace | `agent:*` / other | exact names live in per-repo config |
| Issue structure | parsed fields / body-as-substrate / hybrid | how much of the spec the runner parses vs the worker reads (see contract work) |
| Envelope carrier | fenced block in final turn / sentinel file / tool-call | how the worker physically emits the result envelope (see contract work) |
