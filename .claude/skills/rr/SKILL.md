---
name: rr
version: '1.2.1'
repo: 'https://github.com/mreza0100/rr'
description: Reza's Research-and-Report protocol. Research can target the **internet, the local codebase, or both** — RR detects this from the topic and tells the agents which sources to use. Two modes — RR (run a Workflow pipeline — scout → fan-out → adversarial verify → synthesize — and deliver its report) and RRP (write a self-contained prompt for the user to run in another chat). Triggered when the user says "RR", "research and report", "RRP", "RR-prompt", "research <topic>", "look into <topic>", or "find out <topic>". Use this skill INSTEAD of jumping straight to web search OR straight to grep — RR is a structured Workflow pipeline, not a single query.
---

# RR — Research & Report

> Reza's research protocol. The trigger is `RR` — short for "research and report".

When the user says "RR <topic>", they don't want a single search and a one-paragraph answer. They want a **dynamic research pipeline** that builds knowledge in batches, where each batch is shaped by what the previous batch found, and that finishes with a **report and a plan** — not raw findings.

**Research surface — pick before spawning:**

| Surface      | Tools the agent uses          | When to pick                                                                                                                |
| ------------ | ----------------------------- | --------------------------------------------------------------------------------------------------------------------------- |
| **internet** | WebSearch, WebFetch, context7 | External topics — libraries, regulations, market, competitive landscape, "what does X look like in 2026"                    |
| **codebase** | Read, Grep, Glob, Bash        | Internal topics — "how is auth wired", "where do we use SQS", "find every place that touches PHI", "audit our consent flow" |
| **both**     | All of the above              | Mixed — "RR best-practice X and how we currently do it", "compare our impl to GraphQL Yoga's recommended pattern"           |

If the user doesn't specify, infer from the topic. If genuinely ambiguous, ask one short question ("internet, codebase, or both?") rather than guess. Pass the surface into the workflow so every agent uses the right tools.

There are two modes:

| Mode    | Trigger                                                                             | Output                                                                                                    |
| ------- | ----------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| **RR**  | "RR <topic>", "research and report on X", "research X", "look into X", "find out X" | Run a Workflow pipeline (scout → fan-out → verify → synthesize), then deliver its report back to the user |
| **RRP** | "RRP <topic>", "RR-prompt for X", "write me an RR prompt for Y"                     | Write a self-contained prompt the user runs in another chat; do NOT execute and do NOT spawn an agent     |

---

## Mode 1 — RR (delegate to a Workflow)

**Don't run the pipeline in the main conversation.** Research generates a lot of tool noise — WebSearch results, fetched pages, context7 dumps, grep output — that you don't want filling the main thread. Instead, author a **Workflow script** and run it: the workflow's agents search in the background, pipe each stage's result into the next, and return one structured aggregate. You write the file and deliver the summary.

### Step 1 — Refine the goal (in reasoning, not output)

Before doing anything, work out in your reasoning what the user **actually** wants from this research. The topic as stated is rarely the goal:

- "RR vector DBs" → probably means "which vector DB should we use for Freudche given our stack and scale" — not a generic survey.
- "RR EU AI Act timeline" → probably means "what do we have to do and by when, for our specific risk class" — not a Wikipedia summary.

Restate the refined goal to yourself. If the refinement materially changes the scope and you're not sure, ask the user one short clarifying question before running the workflow. Otherwise proceed.

### Step 2 — Determine the storage path

Every RR run produces a research file. **All research output goes to a single centralized directory regardless of which command invoked RR:**

**Storage directory:** `RR/` (gitignored local sandbox, like `RND/` — RR research is working material, not committed)

**Filename convention:** `{caller}-{topic-slug}-{YYYY-MM-DD}.md` where `{caller}` is the command or agent that triggered the RR (e.g., `mentor-funding-landscape-2026-05-10.md`, `professor-eu-llm-providers-2026-05-10.md`). If RR was triggered standalone (no command active), use `dev` as the caller prefix. Use today's date from the environment context.

### Step 3 — Author and run the Workflow

The pipeline is **scout → fan-out → synthesize**, each stage piped into the next:

- **Scout** (one agent) maps the landscape and returns 2-6 sub-questions. Skip it when the goal is already structured ("compare A, B, C", "audit auth, authz, transport") — pass the sub-questions in as `args.subQuestions` instead.
- **Fan-out** runs one `pipeline()` lane per sub-question: **research → verify**. Research runs a dynamic batch sweep; verify adversarially tries to refute each finding, drops what it can't corroborate, flags single-source claims, and re-rates confidence. Lanes are independent — one sub-question verifies while another still researches.
- **Synthesize** (one agent) folds the verified findings into Verdict / Findings / Plan / Open questions with an overall confidence rating.

Pass the workflow `args: { goal, surface, context, subQuestions? }` — inline the refined goal, the surface (`internet` / `codebase` / `both`), and everything an agent needs to start: project context, plus a time horizon for internet ("prefer 2025–2026 sources") or key directories + `CLAUDE.md` path for codebase. Workflow scripts have no filesystem access, so agents can't write files — the structured return is the only output, and you write the file in Step 4.

Reference script (adapt the prompts and `context` per topic):

```js
export const meta = {
  name: 'rr-research',
  description: 'RR — scout the landscape, fan out per sub-question (research → adversarial verify), synthesize a cited report + plan',
  phases: [
    { title: 'Scout', detail: 'map the landscape, surface sub-questions' },
    {
      title: 'Fan-out',
      detail: 'per sub-question lane: research then adversarially verify',
    },
    {
      title: 'Synthesize',
      detail: 'fold verified findings into Verdict / Findings / Plan',
    },
  ],
};
const A = typeof args === 'string' ? JSON.parse(args) : args;
const { goal, surface, context } = A;
const head = `Goal: ${goal}\nResearch surface: ${surface}\nContext: ${context}\n`;
const SUBQ = {
  type: 'object',
  required: ['subQuestions'],
  properties: {
    landscape: { type: 'string' },
    subQuestions: {
      type: 'array',
      items: {
        type: 'object',
        required: ['question', 'rationale'],
        properties: {
          question: { type: 'string' },
          rationale: { type: 'string' },
        },
      },
    },
  },
};
const FIND = {
  type: 'object',
  required: ['findings'],
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        required: ['claim', 'sources', 'confidence'],
        properties: {
          claim: { type: 'string' },
          sources: { type: 'array', items: { type: 'string' } },
          confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
        },
      },
    },
  },
};
const REPORT = {
  type: 'object',
  required: ['verdict', 'findings', 'plan', 'confidence'],
  properties: {
    verdict: { type: 'string' },
    findings: { type: 'array', items: { type: 'string' } },
    plan: { type: 'string' },
    openQuestions: { type: 'array', items: { type: 'string' } },
    confidence: { type: 'string', enum: ['high', 'medium', 'low'] },
  },
};

phase('Scout');
let subQuestions = A.subQuestions;
if (!subQuestions?.length) {
  const scout = await agent(`${head}\nRun ONE entry-point batch to map this topic. Return a landscape summary (what you searched, key findings with sources/URLs) and 2-6 sub-questions for parallel fan-out, each with a one-line rationale. Don't answer everything — the next stage fans out.`, { phase: 'Scout', schema: SUBQ });
  subQuestions = scout.subQuestions;
}

phase('Fan-out');
const lanes = await pipeline(
  subQuestions,
  (sq) =>
    agent(`${head}\nResearch ONLY this sub-question: "${sq.question}" (${sq.rationale}). Run a dynamic batch sweep — each batch shaped by the last. Return findings as claims, each with its sources/URLs and a confidence rating.`, {
      label: `research:${sq.question.slice(0, 32)}`,
      phase: 'Fan-out',
      schema: FIND,
    }),
  (res, sq) =>
    agent(`${head}\nAdversarially verify these findings for "${sq.question}". Try to REFUTE each claim: drop any you can't corroborate, flag single-source claims as unverified, prefer newer/primary sources, re-rate confidence honestly. Findings: ${JSON.stringify(res.findings)}`, {
      label: `verify:${sq.question.slice(0, 32)}`,
      phase: 'Fan-out',
      schema: FIND,
    }),
);

phase('Synthesize');
const report = await agent(`Goal: ${goal}\nSynthesize these verified per-sub-question findings into one report. Findings: ${JSON.stringify(lanes.filter(Boolean))}\nReturn: verdict (1-3 sentences), findings (3-7 key bullets, citations inline), plan (concrete, opinionated recommendation), openQuestions (only if material), and an overall confidence rating. Flag any claim resting on a single source.`, { phase: 'Synthesize', schema: REPORT });

return { goal, surface, subQuestions, lanes: lanes.filter(Boolean), report };
```

Tell the user one sentence — "Running the RR workflow — scout, N lanes, synthesize." — and let it run. Don't predict findings.

### Step 4 — Write the ONE aggregate file

When the workflow returns, write a **single file** to the storage path from Step 2. This is the complete, self-contained record:

- **(1) Prompt** — the original RR request and the refined goal
- **(2) Fan-out plan** — the sub-questions (`subQuestions`)
- **(3) Scout landscape** — what the scout batch mapped
- **(4) Findings per sub-question** — the verified `lanes`: claims with sources + confidence, one heading per sub-question
- **(5) Verdict** — `report.verdict` + overall confidence
- **(6) Plan** — `report.plan`
- **(7) Open questions** — `report.openQuestions`, only if present

This is the ONLY file the run produces — the workflow's agents can't write files, so there are no intermediates.

### Step 5 — Deliver the aggregate report

The **one file at the storage path is the complete record.** There are no other files to read. The user does NOT want the per-lane parade or the per-sub-question expansion in the chat — they want the synthesized answer, with a pointer to the single file that has everything.

**Default chat output — terse:**

```
Saved: {full path to file}

## Verdict
{1-3 sentences — the headline answer / decision / recommendation} (confidence: high/medium/low)

## Findings (key points)
{3-7 bullets — the substantive answer condensed. Cite sources inline where it matters.}

## Plan
{concrete, opinionated, actionable — the action the user should take. If a decision: name it.}

## Open questions
{anything unresolved, only if material. Skip the section entirely if there's nothing.}
```

**Do NOT print the fan-out trail in the chat.** That belongs in the file. If the user wants to see how the workflow got there, they read the file or ask "show me the lanes."

The **file** must contain the full structure (Prompt / Fan-out plan / Scout / Findings / Verdict / Plan / Open questions) — that's the persisted research record. Your **chat reply** is the executive summary: Verdict + key Findings + Plan + path to the file.

If the workflow's report is thin on Plan or Verdict, write it yourself from the findings, clearly marking it as your synthesis.

---

## Mode 2 — RRP (write a prompt for someone else to execute)

When the user says RRP, they will run the prompt **in a different chat** (often a fresh context, possibly a different model). Your job is to write a prompt that produces a usable RR report **without** the executor having access to this conversation, this codebase, or any of the surrounding context.

### Constraints on the prompt you write

- **Self-contained.** No "as we discussed", no reference to prior turns, no assumption that the executor has read any file. If context matters (Freudche stack, scale, constraints, deadline), inline it in the prompt.
- **Goal first, topic second.** State the refined goal at the top so the executor doesn't waste batches figuring out what's actually wanted.
- **State the surface.** "Research surface: internet / codebase / both." For codebase research the executor needs path orientation; for internet research the executor needs a time horizon.
- **Embed the RR protocol inline.** Do NOT assume the executor has the `rr` skill. Briefly explain the dynamic-batch pipeline, the "satisfies and beyond N+1" rule, and the required report structure. ~10 lines is enough — copy the essentials below.
- **Specify the deliverable shape.** Tell the executor exactly which sections to return (Verdict / Findings / Plan / Open questions in the chat reply; full Pipeline run details in the saved file if any).
- **Name the time horizon (internet research).** "Use sources from 2025–2026 unless older is the canonical reference." Stale data is the #1 RR failure mode for internet topics.
- **Authorize tools.** Internet: "Use web search, fetch official docs, prefer primary sources over blog summaries." Codebase: "Use grep, glob, read; prefer reading actual code over guessing from doc strings."
- Do **not** include secrets, internal URLs, or anything Reza wouldn't paste into a fresh chat window.

### Output format for RRP mode

Wrap the prompt in a fenced block so Reza can copy-paste it cleanly. Briefly above the block, state in one line what context you embedded so he can sanity-check.

```
Context I embedded: {one line}

---PROMPT BELOW — copy into another chat---

```

{the prompt}

```

```

### Reusable RR-protocol snippet to embed inside RRP prompts

When writing an RRP, paste a compact version of the protocol so the executor knows the shape. Suggested wording:

> Run this as a **dynamic research pipeline**, not a single search/grep. The research surface is **{internet / codebase / both}** — use those tools accordingly (web search & fetch for internet; read/grep/glob/bash for codebase). Start with one entry-point query to map the landscape, then plan each next batch based on what the previous batch returned — not a plan written up front. Continue until the goal is answered, then do one extra "pressure-test" batch to look for counter-evidence, newer sources, or contradicting code paths before stopping. Return the result in this shape: **Verdict** (1-3 sentences — the headline answer) / **Findings** (3-7 bullets, citations inline) / **Plan** (concrete, opinionated recommendation) / **Open questions** (anything unresolved). Keep the per-batch breakdown out of the reply — if the user wants the trail, they'll ask.

---

## Common failure modes (avoid these in both modes)

- **Executing RR inline instead of delegating.** RR mode runs a Workflow. If you're running WebSearch/WebFetch/Grep in the main conversation for an RR request, you're doing it wrong — that noise is exactly what the workflow keeps out of the main thread.
- **Single-shot search/grep.** RR is a pipeline. One WebSearch is not RR. One Grep is not RR. (Applies to whoever executes — workflow agent, or the user in another chat.)
- **Picking the wrong surface.** Codebase questions ("how does our auth work") sent as internet research return generic blog posts; internet questions ("which vector DB should we use") sent as codebase research return "we don't have one." Pick deliberately. If unsure, ask.
- **Plan the whole pipeline up front.** The research within each lane is supposed to evolve. If batch 3 was decided before batch 1 ran, the lane isn't doing RR.
- **Skip the verify stage.** The adversarial verify lane exists because the first answer is often a confident-sounding wrong one — it refutes, drops uncorroborated claims, and flags single-source findings. Don't collapse research and verify into one pass.
- **Dump findings, skip the plan.** Reza asked for a report **and a plan**. A wall of facts is half the deliverable.
- **Spam the chat with the fan-out trail.** The user-facing reply is Verdict + Findings + Plan + file path. The per-lane trail goes in the file.
- **Assume the executor has context.** Neither the workflow's agents (RR) nor the user's other chat (RRP) see this conversation. Inline everything that matters into `args.context` / the RRP prompt.
- **Predicting the workflow's findings while it runs.** You know nothing about what it found until it returns. Don't fabricate or summarize in advance.
- **Skipping the file write.** Every RR run produces exactly ONE research file in the caller's research directory. You write it in Step 4 from the workflow's structured return. If no file is written, the work isn't persisted — future conversations can't reference it. The file is the canonical record; the chat reply is the courtesy summary.

---

## Triggers (so you know when to load this skill)

Load this skill when the user's message includes any of:

- `RR <something>`
- `RRP <something>` / `RR-prompt for <something>` / "write me an RR prompt"
- "research and report on <something>" / "do an RR on <something>"

Do NOT load this skill for ordinary research requests like "look up X" or "what is Y" — those don't need the pipeline.
