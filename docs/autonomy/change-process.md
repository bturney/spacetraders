# Derive specs and tickets from the Fleet roadmap

**The repository owns the overarching product plan; GitHub issues own capability specs and implementation tickets.** Begin with the [product direction](product.md), [roadmap](roadmap.md), [capability ledger](capabilities.md), and [issue-tracker conventions](../agents/issue-tracker.md). The issue-based specification is the authoritative scoped behavior contract; the repository roadmap does not copy it.

## 1. Identify the useful outcome

Inspect the highest-value roadmap gap, current source/branch, accepted [ADRs](../adr/), [glossary](../../GLOSSARY.md), active PRs and outcome evidence. Name the blocked Fleet outcome, scarce resource, uncertainty and existing module owner. Prefer observable gameplay effects over a proposed abstraction.

**Done when:** a reader can identify what currently fails or is missing, why it matters and what evidence supports that belief.

## 2. Decide whether to specify it

Compare doing nothing, simplifying/deepening current code, a small experiment and a new capability. Estimate economic value, Ship time, credits, API scarcity, uncertainty, invariants and maintenance cost. Obtain explicit Operator decisions for policy/UX direction and an ADR for architectural authority changes.

**Done when:** the selected path and alternatives have grounded reasoning, or the question is recorded *inconclusive/deferred* without speculative tickets.

## 3. Create the GitHub spec issue

Open one **scoped capability-spec GitHub issue**, using the [issue tracker](../agents/issue-tracker.md) and its `tracking` convention for non-actionable scoped specs. Link the specific roadmap goal, relevant capability ledger row, accepted ADRs, existing source and related issues. Keep the complete spec **in the issue**.

Describe the problem and evidence; desired outcomes; selected behavior and rejected alternatives; one module/authority owner; resources, API capacity, unknowns, resets and mutation consequences; in/out of scope; and independently reproducible acceptance/proof criteria with pass/fail/inconclusive distinctions. Record Operator decisions in the issue discussion.

**Done when:** a new agent can independently determine exactly what the capability must accomplish and how it is verified, without reading a second detailed spec in the repository.

## 4. Derive finite implementation tickets

After the spec is approved, create bounded GitHub sub-issues or linked tickets for concrete owning seams, dependencies, tests and acceptance evidence. Keep the implementation frontier and detailed status with the owning spec **issue**. The repo roadmap retains the broader priorities and milestones.

**Done when:** each leaf is actionable, ownership does not duplicate another runtime authority, and the issue graph clearly identifies the next unblocked work.

## 5. Implement and qualify

Reuse the existing Fleet owner and preserve [architecture invariants](architecture.md). Verify targeted behavior and `scripts/verify`; record PRs, source revisions, accepted/missing receipts, simulation limits and live evidence in the **spec/ticket issues**. Treat completed implementation, scenario evidence, simulator-conditional conclusions and independently approved production qualification as distinct.

**Done when:** tickets are closed or explicitly deferred, with checkable receipts, and the spec issue correctly states what is proven, failed or unproven.

## 6. Refresh the overarching plan only when needed

Update [roadmap.md](roadmap.md) when major priorities, sequencing or milestones change; [capabilities.md](capabilities.md) when high-level delivery/proof or important gaps change; [product.md](product.md) or an ADR for broader decisions. Link the relevant issue and proof without reproducing its acceptance criteria in Markdown. Keep fine-grained ticket statuses in GitHub.

**Done when:** a future agent can derive the next spec from the repository plan, and then find its detailed requirements and tickets in the linked GitHub issues.

## Boundaries

- **Repository:** overarching product direction, roadmap, high-level capability ledger, architecture/ADRs.
- **GitHub issues:** scoped specs, tickets, approvals, detailed acceptance, status and proof receipts.
- **Code/game evidence:** implementations and authoritative external consequences.

Documentation or spec approval does not authorize live Strategy changes, gameplay, protected-host experiments or deployment. Supersede older decisions explicitly and retain their history.
