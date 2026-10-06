# Model tier mapping (#603)

Researched 2026-10-05. Question: which Claude and OpenAI model + effort settings
fill `agent:mechanical` / `agent:bounded` / `agent:deep` for implementer
subagents, given Claude Pro + ChatGPT Plus. Tier semantics (smallest capable /
default / strongest; escalate one tier on blocker or two same-cause
`scripts/verify` failures) are fixed by #602.

## Recommendation

| Tier | Claude (Claude Code only) | OpenAI (OpenCode or Codex) | Rationale |
|---|---|---|---|
| `agent:mechanical` | `haiku` (Haiku 4.5; no effort knob) | `gpt-6-luna`, medium | Cheapest on both plans' limits; Luna is OpenAI's "focused coding" model (350-3,000 Plus msgs/5h). Haiku 4.5 is a year old; switch to Haiku 5.5 when it ships. Escalation covers misses. |
| `agent:bounded` | `sonnet` (Sonnet 5.5), medium | `gpt-6.1-sol`, medium | Sonnet 5.5 is near Opus 5.5 on vendor agentic-coding charts (Terminal-Bench 4.0 70.6% vs 66.4%) at half the token price; medium is its Claude Code default. GPT-6.1 Sol supersedes GPT-6 Sol (same price, "near-Astra"). |
| `agent:deep` | `opus` (Opus 5.5), high | `gpt-6.1-sol`, high | Opus 5.5 leads FrontierCode (54.4% vs GPT-6 Sol 49.3%) and the Vals Index (67.0% vs GPT-6.1 Sol 61.2%), so Operator's "Opus beats Sol at the top" holds. Deep is reached by escalation after failures, so pay for `high` (vendor scores are at xhigh; Opus 5.5 defaults to medium). Fable 5.1 and GPT-6 Astra are off-plan (usage credits). |

Changes against the Operator's starting point:

1. Sol means **GPT-6.1 Sol** (2026-09-29), not GPT-6 Sol or GPT-5.6 Sol.
2. Deep Opus at **high**, not medium. Drop to medium if Pro limits bind.
3. The Claude column applies to **Claude Code only**. OpenCode (the primary
   harness) cannot use the Claude Pro subscription, so OpenCode-dispatched
   implementers use the OpenAI column.

## What "Luna" and "Sol" are

- OpenAI's GPT-5.6 family shipped as Sol / Terra / Luna
  ([OpenAI on X](https://x.com/OpenAI/status/2075271421149020426)).
- GPT-6 Sol and GPT-6 Luna launched 2026-09-22 in Codex for Plus and up;
  API ids `gpt-6-sol` / `gpt-6-luna`; positioned as cheaper than GPT-6 Astra
  ([OpenAI dev community announcement](https://community.openai.com/t/announcing-gpt-6-sol-and-gpt-6-luna-in-the-api-codex-and-chatgpt/1399925)).
- GPT-6.1 Sol (`gpt-6.1-sol`) launched 2026-09-29: "Near-Astra performance for
  complex work at a lower cost", Plus/Pro/Business/Enterprise/Edu. GPT-6 Luna:
  "Most efficient model for focused, high-volume tasks, including summarization,
  extraction, and focused coding", all paid plans
  ([Codex models](https://learn.chatgpt.com/docs/models);
  [TechCrunch](https://techcrunch.com/2026/09/29/openai-launches-gpt-6-1-sol-says-it-nearly-matches-gpt-6-astra-and-costs-less/)).
- GPT-6 Astra (`gpt-6-astra`) is OpenAI's top model; a GPT-6.1 Astra release was
  cancelled (TechCrunch, above). Terra has no GPT-6 successor in the sources found.
- GPT-5.5 retires 2026-10-14 ([Codex models](https://learn.chatgpt.com/docs/models)).

## Plan access and rate limits

### ChatGPT Plus (Codex)

Codex pricing page, local messages per 5 hours on Plus; shared with cloud
chats, weekly limits may also apply
([Codex pricing](https://learn.chatgpt.com/docs/pricing)):

| Model | Plus msgs / 5h |
|---|---|
| GPT-6 Astra | 5-45 |
| GPT-6.1 Sol | 15-160 |
| GPT-6 Sol | 15-150 |
| GPT-6 Luna | 350-3,000 |

The same page recommends lighter models such as Luna for simpler tasks.

**Uncertain:** whether Astra is inside Plus allowance. The Codex models page lists
Astra availability as "ChatGPT Credits" and API; the pricing page lists Plus
estimates for Astra; a third-party summary of OpenAI's help article says "Plus
includes Astra in Work and Codex". At 5-45 messages per 5 hours it is too thin
for a dispatch tier either way.

### Claude Pro (Claude Code)

- Opus 5.5 is available on Pro, Max, Team, Enterprise, with "increased
  five-hour usage limits across subscription tiers"
  ([Introducing Claude Opus 5.5](https://www.anthropic.com/claude-opus-5-5)).
- Claude Code `default` on Pro is Opus 5.5; aliases `opus` → Opus 5.5,
  `sonnet` → Sonnet 5.5 on the Anthropic API path
  ([model config](https://code.claude.com/docs/en/model-config)).
- Fable 5 / 5.1 "aren't included in your plan's usage limits. You can use them
  with usage credits" on Pro
  ([Fable models on your plan](https://support.claude.com/en/articles/15424964-claude-fable-models-on-your-plan)).
- No primary source found giving per-model Pro consumption rates. Inference:
  API list prices (Opus 5.5 $4/$20, Sonnet 5.5 $2/$10, Haiku 4.5 $1/$5 per MTok)
  approximate relative limit burn.

### Harness constraint

- Anthropic: "Anthropic does not permit third-party developers to offer
  Claude.ai login into their own applications, or to route requests through
  Free, Pro, or Max plan credentials"
  ([Claude Code legal and compliance](https://code.claude.com/docs/en/legal-and-compliance)).
- OpenCode docs: Anthropic "explicitly prohibits" Pro/Max plugins; no longer
  bundled since OpenCode 1.3.0. ChatGPT Plus/Pro login is supported
  ([OpenCode providers](https://opencode.ai/docs/providers/)).

## Capability evidence

Vendor charts (each vendor picks its own settings; treat cross-vendor rows as
indicative):

| Benchmark | Opus 5.5 | Sonnet 5.5 | Fable 5.1 | GPT-6 Astra | GPT-6 Sol | Source |
|---|---|---|---|---|---|---|
| Terminal-Bench 4.0 | 66.4% | 70.6% | 55.8% | 57.9% | — | Anthropic Opus 5.5 / Sonnet 5.5 posts |
| FrontierCode 1.1 | 54.4% | 46.2% (High) | 50.3% | 53.3% | 49.3% | same |
| CursorBench 4.0 | 57.8% | 55.5% | 51.8% | — | — | same |

Sources: [Opus 5.5](https://www.anthropic.com/claude-opus-5-5),
[Sonnet 5.5](https://www.anthropic.com/claude-sonnet-5-5),
[Fable 5.1](https://www.anthropic.com/claude-fable-and-mythos-5-1).
Anthropic marks Opus 5.5's Terminal-Bench run at xhigh.

Independent:

- Vals Index, both at max effort: Opus 5.5 66.97% (#3/43); GPT-6.1 Sol 61.15%
  (#8/43). Vibe Code Bench v1.1: 90.29% vs 88.93%. Terminal-Bench Science:
  47.14% vs 52.86% (Sol ahead)
  ([Vals Opus 5.5](https://www.vals.ai/models/anthropic_claude-opus-5-5),
  [Vals GPT-6.1 Sol](https://www.vals.ai/models/openai_gpt-6.1-sol)).
- Artificial Analysis, max effort: GPT-6 Sol Coding Agent Index 57,
  Terminal-Bench 4.0 43%; GPT-6 Luna 41 and 13%. Both ~50-60% cheaper per task
  than GPT-5.6
  ([AA article](https://artificialanalysis.ai/articles/gpt-6-sol-and-luna-push-the-cost-efficiency-frontier)).
  The full Coding Agent Index leaderboard is "Not publicly available".
- Haiku 4.5 (2025-10-15): SWE-bench Verified 73.3%, pitched for parallel
  sub-agents under a Sonnet orchestrator
  ([Haiku 4.5](https://www.anthropic.com/news/claude-haiku-4-5)). No current
  Terminal-Bench 4.0 number found; Haiku 5.5 is announced "in the coming weeks"
  (Sonnet 5.5 post).
- Not found from a primary source: SWE-bench Pro for Opus 5.5 or GPT-6.1 Sol
  (secondary blogs quote 89.9% for Opus 5.5; unverified).
  tbench.ai leaderboard rows did not render.

Gap: Luna vs Haiku 4.5 head-to-head. No shared benchmark found.

## Effort settings

- Claude Code effort levels for Opus 5.5 / Sonnet 5.5: `low`, `medium`, `high`,
  `xhigh`, `max`; both default to `medium` in Claude Code. Haiku 4.5 has no
  effort levels listed
  ([model config](https://code.claude.com/docs/en/model-config)).
- Set per subagent via frontmatter `model:` + `effort:`; frontmatter overrides
  `CLAUDE_CODE_SUBAGENT_MODEL` (same page).
- Anthropic API guidance: effort matters strongly for coding/agentic work;
  `xhigh` is the best setting for most coding on recent models; lower effort on
  newest models often matches prior-generation high effort (claude-api skill
  docs bundled with Claude Code, cached 2026-09-25).
- OpenAI: secondary sources list `low`, `medium` (default), `high`, `xhigh`,
  `max` for GPT-6.1 Sol. The Codex models page names Light / Medium / High /
  Extra High, plus Max (Luna) and Ultra (parallel subagents; not Luna).
  **Uncertain:** exact API value strings. Verify with the OpenCode model list
  before writing config.
- OpenCode per-agent: `"model": "openai/<id>"` and `"reasoningEffort": "<level>"`
  passed through to the provider
  ([OpenCode agents](https://opencode.ai/docs/agents/)).

## Open items

1. Swap mechanical Claude to Haiku 5.5 once released.
2. If Pro 5-hour limits bind on deep runs, drop Opus to medium before
   dropping a tier.
3. Re-check after any GPT-6.1 Luna or Astra-on-Plus change.
