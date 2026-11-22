---
title: Crew background jobs — run a long step off the chat and wake the same chat when it ends
status: draft
author: iamwhatever
created: 2026-11-22
last-audited: 2026-11-22
audited-at: c11cc04317
doc-pr: null
implementation-prs: []
tracking-issues: [40712]
supersedes: []
superseded-by: []
---

# RFC: Crew background jobs — run a long step off the chat and wake the same chat when it ends

- Status: draft. Nothing built. Reviewed in a worker grill on 2026-11-22 (Gateway, Launcher and Skeptic participants); its edits are applied below, and the choices it made are listed under [Decisions](#decisions).
- Author: iamwhatever
- Related: [`rfc-agent-started-turns`](rfc-agent-started-turns.md) (the claude-only path this generalises), [`rfc-app-sdk-durable-jobs-and-view-state`](rfc-app-sdk-durable-jobs-and-view-state.md) (the app-scoped job record this borrows from), [`rfc-crew-log-wake`](rfc-crew-log-wake.md).

Code facts are measured at `c11cc04317` (kirodotdev/KiroCrew main, 2026-11-22) and cite symbols, not line numbers. Paths are under `src/kiro_crew/` unless they say otherwise. KAS facts are read from the KAS 3.5.0 bundle shipped with kiro-cli 3.5.0 (`@kiro/agent/dist/server/acp-server.js`, minified) plus one probe noted where used.

## Summary

An agent often has a long step whose outcome it cannot change while it runs: a build, a test suite, a data export, a render, a long download. Today the agent either blocks its turn on that step (the chat is busy for the whole run) or backgrounds it with no way to learn it ended.

This RFC adds **Crew background jobs**. The agent hands Crew one command. Crew checks it with the shell tool's policy plus cron's command vet, always asks the person unless a policy tier already decided, and runs it in a sandbox at least as strict as the cron floor. The agent's turn ends and the chat is free. When the command exits, Crew posts the result into the **same chat** and starts a turn there through the queue every gateway-started turn already uses. It works on every backend, because the wake is an ordinary prompt turn, not a backend feature.

## Motivation

### What exists today

| Mechanism | What it does | Where it falls short for this ask |
|---|---|---|
| Agent-started turns (claude) | When a `run_in_background` Bash exits, Claude Code starts a turn itself; Crew's idle reader sees it and runs it as its own assistant message (`dashboard/chat_turn/agent_started.py`, `_on_agent_turn`). Config `agent.agent_started_turns`, default `true` (`config/sections_agent.py`). | Claude only: `ACP_BACKENDS_AGENT_STARTED_TURNS = frozenset({ACP_BACKEND_CLAUDE})` (`agent_sdk/backends_turns.py`); any other backend registers nothing (`watch_agent_turns` in `providers/acp_turns.py`). The job lives in the adapter's process tree, so it dies with that process. Phase 3 for other backends is blocked until an adapter marks the end of a turn it starts (`rfc-agent-started-turns.md`, decision 4). |
| `background/completed` crew-log entry | Records a model call the gateway made on the session's behalf (`on_background_completed` in `crew_log/emit_turn.py`). | Not a job record. Its `kind` enum is `title`, `summary`, `memory_consolidation`, `dynamic_card` (`crew_log/entry_types_delegated.py`). Nothing in it says a command ran or ended. |
| `background_wake_pending` / `background_wake_absent` | Answer "will something start another turn in this session?" from pending synthesis, sub-agents, workflow runs and an active monitor loop; `absent` adds queue entries, resource subscriptions and cron jobs (`dashboard/chat_utils_completion.py`). Used to decide the completion sound and the deferred-follow-up notice (`_turn_ending_chain` in `dashboard/chat_turn/turn_ending.py`). | They only read wake owners; they start nothing. A backend-native background command is in neither, so a turn that says "I'll report when the build ends" after a KAS `&` launch gets the "nothing will wake this chat" notice, which is correct today and is the gap. |
| Workflow result delivery | When a workflow run ends, its redacted summary is appended to the originating chat (`inject_workflow_result` in `dashboard/workflow_inject.py`) and a turn is started or queued with `slot.enqueue_or_run_prompt(..., gateway_prompt_kind=WORKFLOW_FOLLOWUP_KIND)` (`_wf_on_done` in `dashboard/server_runtime/workflow_startup.py`). | The right wake shape, backend-neutral. But a workflow run is agent work, not "run this command". |
| `monitor_start` loops | Re-inject a message into the same session every interval; survive gateway restarts; one automation per session (the `monitor_start` schema in `mcp_tools/control_parts/schemas.py`). The gate screens only a named GitHub PR. | Polling a file for "done" costs one model turn per tick, and the loop occupies the chat's only automation slot. |
| Work-ledger wake | A worker's report wakes its conductor through the `work-ledger` probe on the monitor loop (`ledger_wake.py` docstring), the `irq` cheap-probe/expensive-wake pattern (`irq.py` docstring). | Conductor-only, and deliberately cannot carry an instruction: nothing on that server reaches `enqueue_or_run_prompt` (`mcp_work.py` docstring). The probe-then-wake split is reusable. |
| `register_hook` | Registers a webhook that injects a message into a **dedicated** `hook:<id>` session (`register_hook` in `mcp_tools/control.py`). | Wakes a different session, not the same chat. The caller must hold a webhook bearer token and HMAC secret, so a script that calls back must carry a secret. |
| `task_run` | Starts the autonomous task runner from a spec (`task_run` in `mcp_tools/control.py`). | An LLM agent run, not a command; its result opens a task-review slot (`_open_result_slot` in `dashboard/handlers/taskrunner.py`), not the same chat. |
| One-shot cron with `command` | Runs a model-supplied shell command in a sandbox (`mode="cc"`), with a timeout, a cgroup ceiling and a 64 KB output cap (`run_command_sandboxed` and `_MAX_COMMAND_OUTPUT` in `cron_script.py`). | Closest runner. But it is schedule-shaped, it has its own lexical gate (`mcp_cron_vet.py`) instead of the shell tool's policy, and `run_command_sandboxed` itself says it "executes outside the kiro-cli ACP permission/hook flow". |

### KAS

- KAS's shell tool takes `run_in_background`. On a POSIX shell it only appends ` &` to the command (KAS 3.5.0 `executeBash`). So `sleep 15; echo done` with the flag still blocked 15 s in a probe on this host, because only the last command was backgrounded.
- KAS has a background process manager with `started` / `stalled` / `exited` lifecycle events, and a workflow watch kind `background-process` that "completes the watch the moment it exits" (KAS 3.5.0 bundle). I found no ACP frame that starts a chat turn when a plain background command exits. Not probed end-to-end.
- Even if KAS sent such a frame, Crew drains and drops frames that arrive between turns on KAS, kiro and codex (`_run_turn` in `acp/session_handle_turn.py`). Claude's own launch marker says the same: nothing reports the end of that work to Crew (`parse_background_launch` in `acp/_dispatch_parts/adapter_signals.py`).

So on KAS today there is no path from "command exited" to "this chat gets a turn". The wake has to come from Crew.

## Who uses it

- An agent in a dashboard chat with a long deterministic step: build and test, a dataset export, a video render, a large download.
- A conductor's worker that must wait on its own build without holding a chat slot.
- Non-coding work: convert a folder of documents, run a report script, transcode media.

Not the target: work that needs the model mid-run (use a sub-agent), recurring checks (use cron or `monitor_watch`), and external callbacks (use `register_hook`).

## Goals

1. Works on every backend, KAS included, with no backend change.
2. The wake reaches the same chat, as a normal turn, with the same context, tools, redaction and persistence as a workflow follow-up.
3. A job is never a way around the shell policy, the approval path or the sandbox.
4. Bounded: jobs per chat, runtime, output and disk.
5. Honest at the edges: restart, chat close and a busy chat each have one defined outcome.

## Non-goals

- Changing agent-started turns on claude. A claude agent may keep using native `run_in_background`.
- Re-attaching to a job's process after a gateway restart (see §6).
- Interactive jobs (stdin, TTY), streaming output into the chat while the job runs, or job chains.
- Channel sessions (Slack, Discord, Webex) in phase 1; see open question 3.

## Design

### 1. Tool surface

Four tools on `kirocrew-core`. None carries `autoApprove`, for the reason the `mcp_work.py` docstring states: an auto-approved MCP tool skips the PreToolUse gate.

| Tool | Input | Returns |
|---|---|---|
| `job_start` | `command` (string), `cwd` (optional, absolute), `timeout_secs` (optional), `label` (optional, short) | `job_id`, the limits applied, and one line telling the agent to end its turn |
| `job_status` | `job_id` (optional; omitted lists the jobs this caller may see) | state (`queued`, `running`, `exited`, `failed`, `timed_out`, `cancelled`, `interrupted`), start time, run time, exit code |
| `job_cancel` | `job_id` | whether a stop was sent and the final state once known |
| `job_output` | `job_id`, `tail_bytes` (optional), `offset` (optional) | a redacted slice of the job's output file |

**Caller identity.** All four resolve the caller with `require_strict_session_key` (`mcp_core_parts/identity.py`), as `register_hook` does, and accept a session key only from the gateway caller context or the signed per-session token (`_session_key_from_token`). They refuse the plain `KIROCREW_SESSION_KEY` env tier of `_resolve_session_key_strict` outright. That tier is process-keyed and names one tenant of a shared runtime, and its `host_pid_is_shared` guard (`mcp_caller.py`) returns False when the mapping is missing or unreadable, so it can fail open onto another chat's jobs.

**Who may see a job.** A caller may see or touch only jobs its own chat started, with one widening for sub-agents. A sub-agent's job belongs to the sub-agent's key, which its token resolves to. The job record copies `parent_session_key` and `root_session_key` from the `SubagentInfo` record (`subagent_parts/run_record.py`) found by the gate-resolved key, never from an argument or env; an empty `root_session_key` reads as the parent's own key. The parent and the root may list and cancel that job.

`job_start` is added to `WAKE_ARMING_TOOLS` (`dashboard/chat_utils_turn_text.py`), so the deferred-follow-up notice stays quiet after it.

### 2. Check before run

`job_start` judges the command at least as strictly as a shell tool call from that chat:

1. Run cron's command vet, `_vet_shell_command` (`mcp_cron_vet.py`), on the command. A vet refusal refuses the job. This is the control `cc` mode relies on for `~/.ssh` (see §3).
2. Build a `ToolCall` with `command=<command>`, `is_shell=True` and the chat's own spec grants, and run `HookManager.judge` (`hook_runtime/hook_manager.py`). One shared helper builds this, so the job path and the shell path cannot read different grants.
3. `deny` refuses the job with the same deny notice the shell tool would show. Deny parity holds, because command denial lives in Crew's PreToolUse gate (`build_agent_config` in `agent_parts/spec_build.py` injects no `deniedCommands`).
4. An `allow` that a tier stamped runs the job. An `allow` that no tier stamped means "fall through to the surface's own approval path" (`HookManager.judge` docstring). For a job, that always raises the permission card, in every approval mode. No kiro-cli spec grant (`allowedCommands`) is honored, because Crew cannot read those grants (`_doctor_unreadable_allowed_commands`, called from `_doctor` in `cli_doctor.py`). No new allow rule is created.
5. The vet result, the verdict, the command (redacted) and the job id are written to the SEL audit.

The MCP call to `job_start` is itself judged first, as any MCP tool is. So a job passes every gate a shell call passes, plus the cron vet.

### 3. Run

Crew owns the process; the backend does not. The runner reuses the parts of `run_command_sandboxed` (`cron_script.py`): shell resolve, `wrap_argv`, `cgroup_scope_argv`, `popen_limited` with `start_new_session=True`, a scrubbed env (`_clean_cron_env` in `cron_script_child_env.py`) and a per-run scratch dir (`_allocate_cron_scratch`).

- **Sandbox.** The job's mode is the stricter of the chat's `agent.sandbox` mode and the cron floor `cc` (`run_command_sandboxed`). The agent's shell runs inside the backend process, which Crew wraps at spawn (`wrap_argv` passed in `acp/client_spawn_env.py`); on kiro-cli that shell may also sit inside kiro-cli's own sandbox. A gateway-spawned job does not inherit kiro-cli's layer, so it must not be looser than `cc`. `cc` leaves `~/.ssh` readable on purpose, and `run_command_sandboxed` names `_vet_shell_command` as the primary control for it, which is why §2 runs that vet.
- **No sandbox backend.** A job refuses to start when the sandbox backend is `none`, whatever `agent.sandbox_allow_unsandboxed_exec` says, and writes the refusal to SEL. `wrap_argv` (`sandbox_wrap.py`) alone is not enough: it raises only in its refusal branch, and runs unconfined once the owner sets that key.
- **Env and policy files.** The env scrub drops `_CRON_ENV_DENY`, which includes the same `_AGENT_DENIED_ENV_KEYS` agent children lose (`cron_script_child_env.py`, `sandbox_argv.py`). A job cannot rewrite Crew's policy files: those paths are sealed read-only in every wrap (`_namespace_plan` in `sandbox_plan.py`, `_live_plan_host` in `sandbox_argv.py`).
- **Identity.** Runs as the gateway's OS user, which is the owner. A job may only start from a chat whose execution identity is the owner's own Global store (`capture_session_execution` in `execution_context.py`). A mate member, an app-owned slot or a relayed/remote caller is refused. Incognito and Temporary chats are refused, as `register_hook` refuses them.
- **Dev Fleet pods.** A pod chat's job runs on the pod's own gateway (`_apply_pod_home_remap` in `acp/client_spawn_env.py`).
- **Output.** stdout and stderr go to one file in the job's directory, capped (§5). Nothing is parsed while the job runs.

### 4. Wake the same chat

On exit, Crew writes the final record, then delivers like a workflow result, with a different prompt:

1. Build a short body for the person: label, state, exit code, run time, and the last part of the output (§5), redacted with `redact_exfiltration_urls` then `redact_credentials`, as `_redact` in `dashboard/workflow_inject.py` does. Redact the full tail before cutting it, as `run_command_sandboxed` does for stderr.
2. Append it to the chat as a gateway row with `meta.kind = "job_result"`, durable via `append_if_absent_off_loop`, as `inject_workflow_result` does.
3. Call `slot.enqueue_or_run_prompt(prompt, partial(_run_chat, _synthetic_payload=True), state, gateway_prompt_kind=JOB_FOLLOWUP_KIND)` (`dashboard/state_parts/chat_slot.py`), with a new kind beside `WORKFLOW_FOLLOWUP_KIND` in `GATEWAY_PROMPT_INJECT_KINDS` (`dashboard/chat_utils_injected_rows.py`). The prompt is fixed gateway text with the id and state of each job that ended (§6), never the label. It says the output is not in this conversation and tells the agent to call `job_output(job_id=<id>)`. It does not copy the workflow text "Its result was just posted above" (`_wf_on_done`), which is false on a warm session, and it does not carry a model-chosen name as the workflow prompt does.
4. **Owner gone.** If a sub-agent's session is released before its job exits, the wake goes to `root_session_key or parent_session_key`.

So job output reaches the model only as a `job_output` tool result, which is data. A command cannot write the agent's next instruction.

This is the only new wake. It is backend-neutral because it is an ordinary prompt turn.

`background_wake_pending` gains one owner: a running job of this chat. `background_wake_absent` inherits it.

### 5. Limits

Proposed defaults; each is a config key under `agent.jobs` with a hard ceiling.

| Limit | Default | Ceiling | On breach |
|---|---|---|---|
| Running jobs per chat | 2 | 4 | `job_start` refuses and names the running ids |
| Running jobs per gateway | 8 | 16 | queued as `queued`, starts when a slot frees |
| Run time | 30 min | 6 h | killed (process group); state `timed_out` |
| Output file per job | 10 MB | 50 MB | file stops growing; one truncation line is appended |
| Output in the result row | last 4 KB | 16 KB | rest reachable with `job_output` |
| Job records kept | 7 days | — | record, output and scratch dir removed by the sweep |
| Disk for all job dirs | 1 GB | — | `job_start` refuses until the sweep frees space |

### 6. Edge cases

| Event | Outcome |
|---|---|
| Chat busy when the job ends | `enqueue_or_run_prompt` queues the follow-up; it runs after the current turn, like a queued message. A conductor "Pause all" also queues it (`crew_pause.holds_slot` in `chat_slot.py`). |
| Several jobs end together | Each appends its row. One queued follow-up per chat is enough: a second finish while one is queued adds its job id and state to that queued prompt instead of queuing a second one, so the prompt names every job that ended since the last follow-up. |
| Session recycled or swept while the job runs | No effect on the job: Crew owns the process, not the backend. The follow-up turn starts or resumes the session as any queued turn does. |
| Sub-agent released while its job runs | The job keeps running; the wake goes to `root_session_key or parent_session_key` (§4). |
| Person closes the chat | Its running jobs are cancelled and recorded `cancelled` with cause "chat closed". No fallback slot is created (open question 2). |
| Person presses Stop in the chat | Stops the current turn only. Jobs keep running; `job_cancel` or a cancel control on the job row stops them. |
| Gateway restart | v1 does not re-attach. On boot, reconciliation marks every job still `running` as `interrupted`, as the App SDK job record does for its runs (`_INTERRUPT_MESSAGE` in `apps/job_sdk.py`), kills any leftover process group it can prove it owns, and delivers one wake per affected chat saying the job was interrupted. The agent decides whether to start it again. |
| Job's chat is a cron tab or a `hook:` session | Same as any chat, so a cron-run agent can hand off a long step too. |

### 7. What the agent sees

The `job_start` result tells the agent to end its turn and not to poll. The follow-up turn says which job ended and in what state, and tells the agent to read the output with `job_output`. The `job_result` row is for the person reading the chat. The agent must not rely on it: a warm session replays no history, since `_session_replay_history` (`dashboard/chat_turn/prompt_assembly.py`) replays only `if _context_is_new and not _provider_has_history`. On claude, the tool description says native `run_in_background` also works there; on other backends `job_start` is the only way to be woken.

## Decisions

The grill picked these three where participants offered more than one fix. Each was picked by the grill, not by the owner, and stays open to the owner's override.

1. **`~/.ssh` exposure: keep `cc` and run `_vet_shell_command` in `job_start`, rather than defaulting jobs to `strict`.** `strict` hides `~/.ssh` and breaks git and scp over SSH, which long build steps often need (`run_command_sandboxed` says so). The vet is the control cron already relies on, so jobs and cron stay one policy. Picked by the grill; open to the owner's override.
2. **The wake prompt points to `job_output` instead of relying on the row.** The other offer was to fence the row or give it a non-assistant role. Pointing to `job_output` fixes the warm-session gap (§7) and delivers output as a tool result, which is data. The row stays for the person, and a test pins that it is never replayed as assistant text. Picked by the grill; open to the owner's override.
3. **Sub-agent jobs are owned by the sub-agent and visible to its parent and root.** Both keys come from the `SubagentInfo` record found by the gate-resolved key, never from an argument or env. If the sub-agent session is gone at exit, the wake goes to `root_session_key or parent_session_key`. Picked by the grill; open to the owner's override.

## Migration plan

### Phase 0 — probe (no product code)

Answer, in this document:

- On KAS 3.5.0, does any frame reach Crew when a `run_in_background` command exits between turns? Exit: a recorded yes/no from a stdio capture.
- Do common long steps pass under `cc` plus the cron vet: `cargo build`, `npm test`, `cdk synth`? Exit: one table of pass/fail per step.

### Phase 1 — runner and record (no wake)

Job store (one file per job, one writer, as `apps/job_sdk.py` does), runner, limits, `job_start` / `job_status` / `job_cancel` / `job_output`, the shared shell-judge helper. Exit criteria:

- a command the shell tool denies is refused by `job_start` with the same tier name;
- a command `_vet_shell_command` refuses is refused by `job_start`;
- an `allow` no tier stamped raises the permission card in every approval mode, and denying it starts nothing;
- a parity test runs one table of commands through both paths and asserts equal deny verdicts;
- a job from a member, app-owned, Incognito or Temporary chat is refused;
- a call carrying only a forged `KIROCREW_SESSION_KEY` env value is refused by all four tools;
- a sub-agent's job is listed and cancellable from its parent and its root, and from no other chat;
- with a `none` sandbox backend and `agent.sandbox_allow_unsandboxed_exec = true`, `job_start` refuses and writes an SEL record;
- run-time, output and per-chat caps each trip in a test;
- a credential-shaped string in output is redacted in `job_output`.

### Phase 2 — wake

`JOB_FOLLOWUP_KIND`, the result row, `enqueue_or_run_prompt`, `background_wake_pending` owner, `WAKE_ARMING_TOOLS` entry, chat-close cancel, restart reconciliation. Exit criteria:

- on KAS and on claude: start `sleep 60; echo done` as a job, end the turn, and a follow-up turn appears in the same chat within seconds of exit, and the agent reads `done` through `job_output`;
- a job that ends during a running turn queues one follow-up that runs after it;
- two jobs that end during one running turn yield one follow-up that names both job ids;
- closing the chat cancels its job and starts no turn;
- a gateway restart mid-job yields `interrupted` and one wake per chat;
- a sub-agent released before its job exits wakes `root_session_key or parent_session_key`;
- job output that contains "ignore previous instructions" never appears in the prompt text;
- the label never appears in the prompt text;
- the `job_result` row is never replayed to the model as assistant text on a cold start.

### Phase 3 — UI

A job row with live state and a cancel control. Blocked on open question 4.

## Backward compatibility

New tools, a new queue kind and a new config section. No stored-data migration. With `agent.jobs.enabled = false`, the tools are not listed and nothing else changes.

## Security considerations

- **At least the shell tool's policy.** One helper builds the shell `ToolCall` for both paths, and a parity test pins equal deny verdicts (§2). The job path never adds an allow rule and never auto-approves.
- **Unstamped allow always asks.** An `allow` no tier stamped raises the permission card in every approval mode; kiro-cli `allowedCommands` grants are not honored, because Crew cannot read them (§2).
- **Cron vet for `~/.ssh`.** `_vet_shell_command` runs on every job, because `cc` leaves `~/.ssh` readable and relies on that vet (§3).
- **Same or stricter sandbox, truly fail closed.** At least `cc`. A `none` sandbox backend refuses the job even when the owner set `agent.sandbox_allow_unsandboxed_exec`, and the refusal is in SEL (§3). Env scrubbed with the cron scrub.
- **Owner only, unforgeable caller.** Caller key from the gateway caller context or the signed token only; the env tier is refused. Refused for members, apps, relayed callers, Incognito and Temporary. Jobs are visible and cancellable only from the chat that started them, plus a sub-agent's parent and root.
- **Output is data, not instruction.** Redacted before it is stored in the row or served by `job_output`. The wake prompt is fixed text with the job id and state only; neither output nor label enters it.
- **Audit.** SEL records on start (with vet result and verdict), refusal, cancel and end.

### Residual risks

- **Approval lifetime.** A job outlives the turn that approved it, so one approval covers its whole run time, up to the 6 h ceiling. Whether to cancel on Trust-grant expiry is open question 6. Not grilled.
- **Script body.** Like the shell tool, the policy judges the command line, not the body of a script it calls, and the script can change after the check.
- **More prompts on kiro-cli.** Always raising the card on an unstamped `allow` adds approval prompts the shell tool might not show on kiro-cli. This is the price of not trusting grants Crew cannot read.
- **No jobs without an OS sandbox.** Refusing a `none` backend means no jobs on a host without an OS sandbox (every Windows host, per `run_command_sandboxed`), even when the owner opted into unsandboxed exec.
- **Phase 0 is open.** It is not yet known whether `cargo build`, `npm test` and `cdk synth` pass under `cc` plus the vet.

## Alternatives considered

- **Extend agent-started turns to KAS (Phase 3 of that RFC).** Needs KAS to start a turn on exit and mark its end, and needs Crew to stop dropping between-turn frames on KAS (`_run_turn`). Neither exists. Each further backend would need the same work.
- **One-shot cron with `command`, then `cron_trigger`.** The runner is right, but its only gate is cron's own lexical vet, and it runs outside the permission flow. Using it as is would make a job a way around the shell policy. This RFC reuses its runner and its vet, and adds the shell policy and the approval card.
- **A launcher the agent runs through its own shell** (`kirocrew job run -- <cmd>`). Rejected. No unforgeable chat identity reaches a shell on the shared runtime: KAS runs on the shared `AcpRuntime` (`providers/acp_runtime_start.py`), whose process env names whichever session claimed the process (`_apply_session_identity_env` in `acp/client_spawn_env.py`), and KAS MCP entries keep only `KIROCREW_HOME` (`_MANAGED_ENV_KEYS_KEPT` in `acp/kas_env_withhold.py`). A shell can also forge a "finished" report for a job that never ran. And "the real shell judges first" cannot be built or verified as a pre-step: ACP gives a verdict only as `session/request_permission` while the tool runs (`_handle_permission` in `acp/client_permissions.py`), and Crew cannot read kiro-cli's `allowedCommands` to replay it. Reviving it would first need an identity carrier the agent cannot forge.
- **`monitor_start` polling a done-file.** One model turn per tick, and it takes the chat's only automation slot (the `monitor_start` schema).
- **`register_hook` and a script that POSTs on exit.** Wakes a `hook:` session, not this chat, and the script must hold a webhook secret.
- **`task_run`.** An LLM agent, and its result lands in a task-review slot (`_open_result_slot`).

## Open questions

1. **Sandbox floor.** Decision 1 keeps `cc` plus the cron vet. `cc` also hides `~/.aws`, which a `cdk deploy` job needs. Recommendation: keep it hidden; a job that needs cloud credentials is the kind of step the agent should run in its own turn, where the shell tool's approval sees it.
2. **Chat close.** Cancel the job (proposed), or let it finish and deliver to a fallback `job-<id>` slot as `inject_workflow_result` does for workflows?
3. **Channel sessions.** Slack, Discord and Webex sessions queue differently. In or out of v1? Recommendation: out.
4. **UI.** A dedicated job row with cancel, or reuse the workflow result row? Who owns the design?
5. **Limits.** Are the defaults in §5 right for large builds, which often run over 30 minutes?
6. **Approval lifetime.** Should a job started under a time-limited Trust grant be cancelled when that grant expires?
7. **Re-attach after restart.** Worth a later phase, or is `interrupted` plus a wake enough?
