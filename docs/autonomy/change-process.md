# Changing the autonomous Fleet product

**Use this when proposing or implementing any new autonomous behavior, economic policy, Operator surface or simulator-dependent capability.** The roadmap and durable specs live in this directory. GitHub issues hold finite decisions/tasks and dated evidence; they are not the permanent master plan.

## 1. Find the constraint

Read [product](product.md), the owning [capability row](capabilities.md) and [roadmap](roadmap.md). Inspect the target branch, current source, accepted [ADRs](../adr/), [glossary](../../GLOSSARY.md), relevant open PRs and actual outcome evidence. Write the *observed* limitation and its affected Ships/resource/time horizon. Separate a known loss from an unsupported inference or a simulator artifact.

**Done when:** the candidate names a verifiable current behavior, the desired outcome, its evidence source and the one existing module that should own the change.

## 2. Compare options before generating tickets

Consider **do nothing**, **repair/deepen existing code**, **delete a duplicate path**, **small targeted experiment**, and **new capability**. Evaluate expected improvement, binding resource, unknown assumptions, invariant risk and implementation/verification cost. If the preferred outcome is still speculative, run the cheapest decisive controlled investigation first.

For permanent architectural authority changes, write/update an ADR explaining the rejected options. For changed product policy or Operator affordance, capture the explicit accepted decision. Keep actual game truth separate from local estimated beliefs.

**Done when:** the chosen option, rejected alternatives, irreversible consequences, and smallest valid proof are recorded; otherwise record **inconclusive** and stop without spinning up a permanent backlog.

## 3. Put an accepted spec in source control

For an approved capability, create `docs/autonomy/specs/<capability-slug>.md` using [the template](specs/README.md). It owns *outcomes, decisions and acceptance proof*, not a detailed reimplementation of the old issue. Link governing ADRs, current source/owners, dated scenario evidence, security and reset boundaries. Update the [roadmap](roadmap.md) if it is selected as near-term work and mark its [ledger row](capabilities.md) **planned**.

GitHub issues may link a **specific versioned spec commit** for bounded implementation, without pasting and drifting the whole contract. A tracking issue, if unavoidable, is a short index and should close when its finite work is done. Future iterations edit the owning source spec via PR; superseded versions stay in Git history.

**Done when:** a reviewer can determine exactly what becomes true, how it is tested, what remains out of scope, and the authoritative code/evidence owner from the versioned file alone.

## 4. Implement through the existing seam

Build one end-to-end increment. Use Fleet Planning for contributions, Fleet Allocation for decisions and coordinated claims, the Evidence and Governor interfaces for observations/requests, Ship/Fleet Execution for accepted actions, and MutationAttempts for irreversible game-side effects. Preserve the safety invariants in [architecture](architecture.md). Delete a superseded authority in the same increment where safe rather than installing another adapter layer.

Check [AGENTS.md](../../AGENTS.md) and [testing](../agents/testing.md) before changes; run targeted regressions and `scripts/verify` before push. Use the OpenAPI spec for added endpoint ownership.

**Done when:** the code is merged to the intended branch, unit/seam tests and the required repository verification pass, and the proof record links the exact revision. An integration branch alone is **integrating**.

## 5. Qualify, update and close the loop

Exercise the accepted spec's decisive scenarios. For economic policy, record estimated *and* realized Net Earnings, Ship-hours, fuel, capital and API costs, alternatives and confidence. For simulator use, log pinned actual-bot and world revisions, scenario/seed, completeness, fidelity limitations and budget/approval. For mutation/reset work, prove the named ambiguous and interrupted windows. Attribute failures; label gaps **unproven**.

Update the spec's evidence/status, [capability ledger](capabilities.md) and [roadmap](roadmap.md) **in the delivery or qualification PR**. Link actual immutable evidence. Close finite issues with the result; the source roadmap survives, whether proof passed, failed or was inconclusive.

**Done when:** the recorded product claim equals what the evidence actually establishes, the next decision is findable without reopening a mega issue, and no second copy of the roadmap remains in issue prose.

## Change hygiene

- **One home per meaning:** product here, structure in ADR/architecture, requirements in the owning spec, priority in roadmap, implementation in source, history and receipts in Git/issue/run evidence.
- **Separate authorization:** approving a spec or merging documentation does **not** authorize a gameplay action, live Strategy change, protected-host experiment or deployment. Follow the applicable operational approval.
- **Supersede explicitly:** name the old contract, the replacing source file/ADR and the proof or decision. Close the old container as **superseded**, not **completed**, when replacing its planning role.
