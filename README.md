# Code audit kit

A drop-in Claude Code setup for auditing code that already exists. Instead of reading a diff, a panel of specialist reviewers examines the code through one lens each, then skeptics try to refute every finding before it reaches you. Because there is no diff to review, the kit rebuilds the audited content as a synthetic branch and runs the panel against that.

## What's here

```
agents/                               reviewer personas
  architecture-reviewer.md
  performance-reviewer.md
  security-reviewer.md
  scalability-reviewer.md
  kubernetes-reviewer.md              the example domain lens
skills/code-audit/
  SKILL.md                            the /code-audit skill
  scripts/audit-scope.sh              builds the SCOPE...TOP branch from a path or snippet
  scripts/domains.sh                  picks the domain lenses
  workflows/audit.js                  the panel: lenses, skeptics, voting
audit-panel.png                       a one-page visual of the whole system
```

## Install

Copy the personas into your agents directory and the skill into your skills directory:

```bash
cp agents/*.md ~/.claude/agents/
cp -r skills/code-audit ~/.claude/skills/
```

Use `.claude/agents/` and `.claude/skills/` inside a project instead if you want it scoped to that repo.

The panel runs through the Workflow tool, which spawns the lenses and skeptics in parallel. The skill's instructions call it, so no extra setup is needed.

## Use

Ask for an audit and name the target:

- "Audit `src/payments` with the code audit kit"
- "Audit this repo, focusing on the authentication code"
- "Audit this snippet" and paste one fenced block

The skill measures the target, confirms the size with you, builds the synthetic branch, runs the panel, and writes a local report. Nothing is changed and nothing is posted.

## How it works

### The scope

`audit-scope.sh` turns existing code into something the panel can review like a change:

- `measure` sizes the target and lists what it would include: untracked files, nested repos it skips, symlinked ancestors, rule files it excludes, and unreadable paths. It writes nothing.
- `path` builds two commits. `SCOPE` is the repo's tree with the target removed; `TOP` is the tree with the target's working content folded back in. `TOP` is checked out into a throwaway worktree. `git diff SCOPE...TOP` then lists the audited content in full.
- `snippet` builds the same shape as a fresh scratch repo: an empty root commit and one commit holding the snippet.

The caps are 100 files, 10,000 lines, and 512 KiB. Over a cap, the skill asks for a narrower target rather than spending a panel on it.

### Tier and domains

The skill always passes the deep tier, so every blocking or major finding on a code lens gets a third skeptic that tries to reproduce it. The skill never lowers it; a direct Workflow caller can still pass `quick` or `standard`.

`domains.sh` reads the audited content and reports which domain lenses fit: Rust, Kubernetes, kernel, or supply chain. This kit ships the Kubernetes persona as the example; the other three are detected but not run until you add their personas.

### The lenses

Each lens is a reviewer persona with its own checklist:

- **architecture**: layering, module boundaries, API design, coupling, consistency, maintainability.
- **performance**: hot paths, complexity, I/O, memory, caching, blocking work, N+1.
- **security**: attacker-controlled input across trust boundaries, authn and authz, injection, SSRF, path traversal, deserialization, secrets, fail-open paths, races.
- **scalability**: 10 to 100 times the current data, users, or concurrency: unbounded growth, contention, fan-out, pagination, limits, retries.
- **kubernetes** (example domain lens): controllers, RBAC, pod security, Helm, CRDs. It only joins the panel when the audited content shows Kubernetes evidence.

### The skeptics

Every finding gets challenged before it is reported:

- Two skeptics per blocking or major finding: one checks the facts, one checks the impact.
- On deep, a third skeptic on code lenses tries to reproduce the finding. It may abstain, and an abstention does not count as a vote.
- Minor findings get one skeptic that answers the facts question and the impact question separately.

All skeptics uphold means confirmed. All refute means rejected. Anything else is disputed, and the skill checks disputed findings against the code itself before keeping them.

### What else makes the panel sharper

- **Repo rules**: the conventions files (`REVIEW.md`, `AGENTS.md`, `CLAUDE.md`, `CONTRIBUTING*`) are copied from `SCOPE`, so the code is judged by the rules it had before the audit.
- **Siblings**: when the code handles a member of a set case by case, the lens checks every place the set's other members are handled, not just the first.
- **Instances**: the same bug in several places is one finding with a list of places, so one fix covers it.
- **The exec gate**: nothing from the code runs unless you wrote it, and even then only an interpreted one-liner or one targeted test, never a build.

### The advanced pass

The panel names no model. To run a security-focused pass on a specific Claude model, call the workflow directly with the advanced args instead of the default panel:

```json
{
  "repo": "<worktree or snippet dir>",
  "base": "<SCOPE sha>",
  "tier": "deep",
  "lenses": ["security", "kubernetes"],
  "advanced": true,
  "advancedModel": "claude-mythos-5-2",
  "effort": "high"
}
```

Every lane in the pass runs on that model and effort. It is trace-only (nothing from the code runs, whatever `exec` says), and the lenses are the security lens plus the domain lenses only, at the deep tier. The model must be one your session can reach; the workflow does not pick or verify it, and it logs the lens set but never the model id. The example uses Mythos; substitute whichever advanced Claude model you have access to, or drop `advancedModel` and `effort` together to run the same security-only pass on the session model.

## Adapt it

### Add a domain lens

Copy `agents/kubernetes-reviewer.md` to your own persona, rename it and its `name:`, rewrite the checklist for your domain, then add it to `ALL_LENSES` in `workflows/audit.js` with `domain: true`. `scripts/domains.sh` already detects Rust, kernel, and supply-chain; if your domain is one of those, the detector is there, and all you need is the persona and the `ALL_LENSES` entry. For a new domain, add a detector block to `domains.sh` that notes its key when the audited content has evidence.

### Change the core lenses

The four core personas are separate files. Rewrite one in place, or add a new one to `ALL_LENSES` without `domain: true` so it joins every audit.

## Safety

- The panel is read-only. No reviewer creates, edits, or deletes files.
- Nothing from the audited code runs unless `exec: true`, and the skill sets that only when the user wrote it.
- `audit-scope.sh` neutralizes the target repo's own hooks, fsmonitor, and filter drivers for its own git calls, and materializes the worktree as a fresh repo. The phases after it use ordinary git, so audit code you trust; a pasted snippet has no such exposure.
- Findings are local. The skill never posts them to a forge and has no verdict.

## Requirements

Claude Code with the Workflow tool. The scripts run on Linux with GNU coreutils and findutils: `bash` 4 or newer, `git`, `awk`, `grep`, `realpath`, `stat`, `find`, and `xargs`. macOS and BSD are not supported.
