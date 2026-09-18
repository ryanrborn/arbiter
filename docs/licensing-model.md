# Licensing Model & Open-Core Architecture

**Status:** Decided  
**Date:** 2026-09-18  
**Task:** bd-gjw1ze · **Tracker:** github:1868  

---

## 1. The Decision, in Short

Arbiter adopts an **open-core** licensing and distribution model:

* **Core:** Licensed under the **Apache License, Version 2.0 (Apache-2.0)** and developed openly in this repository.
* **Commercial ("Arbiter Pro"):** Packaged as a separate, closed-source Hex package in a dedicated private repository, distributed exclusively through an authenticated private Hex repository (the proven Oban model).

This architecture is **explicitly not dual licensing**, and **explicitly not in-repo license zoning** (such as an `ee/` directory or per-file proprietary markers).

### Why Not Dual Licensing?
Dual licensing generates commercial revenue only when the free tier is copyleft (such as GPL/AGPL). Under dual licensing, commercial customers pay to escape the copyleft requirement when embedding or redistributing code. When the open codebase is permissively licensed (such as Apache-2.0), there is no copyleft obligation to escape, rendering dual licensing structurally ineffective as a revenue mechanism.

### Why Not In-Repo License Zoning?
Distributing open and proprietary code within a single git tree (GitLab-style `ee/` directories or dual-licensed trees) introduces substantial ongoing operational friction:
* Complicated build and release tooling to strip proprietary code for open-source distributions.
* Ambiguity around dependency imports and accidental license contamination across file boundaries.
* Contributor confusion regarding which parts of the tree accept external contributions.

Drawing the boundary strictly at the **package level** keeps the core repository pure Apache-2.0, preserves standard Elixir dependency semantics, and delegates commercial tier access control entirely to authenticated package distribution.

---

## 2. Alternatives Considered and Rejected

### 2.1. MIT License
* **Rationale for rejection:** MIT lacks an explicit patent grant (Section 3 of Apache-2.0) and lacks a patent-retaliation termination clause. In AI orchestration, agent tooling, and developer infrastructure—spaces with high concentrations of aggressive software patent filings—an explicit patent grant is vital protection for both the project and downstream adopters. Furthermore, corporate legal teams regularly clear Apache-2.0 projects without friction, whereas MIT without patent indemnification occasionally prompts extended legal scrutiny.

### 2.2. BUSL-1.1 / Functional Source License (FSL)
* **Rationale for rejection:** Source-available licenses (such as Business Source License 1.1 or FSL) are primarily designed to defend cloud-hosted software products against hyperscalers and managed-service competitors (e.g., AWS launching a hosted wrapper around an open database). Arbiter is a self-hosted control plane that coordinates local git worktrees and agent sessions on developer machines; nobody runs or consumes Arbiter as a generic multi-tenant hosted SaaS. The realistic competitive threat to Arbiter is platform vendors shipping native fleet orchestration within their own developer tools—a scenario no source-available license prevents. In exchange for zero competitive defense, adopting BUSL/FSL imposes a substantial "adoption tax" by forfeiting OSI-approved open-source status, creating friction for corporate evaluation and community contribution.

### 2.3. AGPLv3 + Commercial Exception
* **Rationale for rejection:** While an AGPL + commercial exception model can monetize enterprises whose corporate policies strictly forbid AGPL in developer environments, AGPL's core enforcement mechanism—the network-use copyleft trigger—does not bite for a self-hosted developer CLI and workspace control plane. More critically, at early-stage adoption with zero existing users, frictionless adoption is vastly more valuable than a monetization barrier that no user exists to pay for.

---

## 3. Arbiter Pro Protection: Contract and Trade Secret, Not Copyright

Arbiter is an **agent-authored codebase**. Under current United States Copyright Office policy and guidance regarding machine-generated output, copyright protection over purely AI-generated code is thin; legal copyright extends primarily to human selection, coordination, and arrangement.

* For the **Apache-2.0 core**, thin copyright is immaterial: the core code is freely licensed, redistributable, and modified under clear permissive terms.
* For **Arbiter Pro**, relying solely on copyright enforcement would introduce critical legal vulnerability.

Consequently, Arbiter Pro's commercial protection rests on **contractual agreements and non-distribution of source (trade secret protection)**, backed by authenticated package repository access controls, rather than relying on statutory copyright infringement claims. Any commercial tier whose defense depends solely on copyright must not be built.

---

## 4. Contributor License Agreement (CLA) Requirement

Before this repository accepts external contributions, a **Contributor License Agreement (CLA)** is mandatory. A Developer Certificate of Origin (DCO) is insufficient.

### Why a DCO is Insufficient
A DCO only certifies that the contributor has the legal right to submit the work under the repository's open-source license (Apache-2.0). It does **not** grant the project maintainers any right to relicense that contribution under proprietary terms.

### Why Open Core Requires a CLA
Under a pure open-source project that never intends to monetize proprietary extensions, a CLA may be optional. Under an open-core architecture, however:
* Maintainers may need to adapt or migrate core logic into Pro capabilities.
* If an external contributor submits code under Apache-2.0 to a core module without executing a CLA that assigns or grants full relicensing rights to the maintainer, that module is permanently locked under Apache-2.0. The maintainer cannot subsequently incorporate or adapt that code into the closed commercial package.

Therefore, executing a CLA prior to accepting outside contributions is non-optional.

---

## 5. Extension Seams in the Existing Codebase

The Arbiter architecture already defines 17 `@callback`-bearing Elixir behaviours. The open-core boundary requires no architectural rewrites because clean extension seams are already established.

The following six behaviours are designated as the intended core/Pro extension seams (module names spelled exactly as defined):

1. `Arbiter.Agents.Agent` — Autonomous agent runner harness and CLI interaction.
2. `Arbiter.Trackers.Tracker` — Issue tracker integrations (Jira, GitHub, Linear, enterprise trackers).
3. `Arbiter.Mergers.Merger` — Merge request, forge, and merge queue strategies.
4. `Arbiter.Sessions.Provider` — PTY/terminal and process launch providers.
5. `Arbiter.Agents.Routing.Policy` — Dynamic model and agent dispatch routing policies.
6. `Arbiter.Quota.Gate` — Provider quota throttling, cost boundaries, and overage gating.

### Resolution Mechanism: Config-Driven Module-Swap
The resolution mechanism for these extension points is the existing config-driven module-swap idiom (`Application.get_env/3`), as currently demonstrated in `Arbiter.Workflows.ReviewGateFixRoundDispatcher`:

```elixir
# Implementation resolved at runtime via application configuration, falling back to default core module
impl = Application.get_env(:arbiter, :review_gate_fix_round_dispatcher, Arbiter.Workflows.ReviewGateFixRoundDispatcher)
```

Pro packages register advanced implementations via workspace configuration or application environment, cleanly swapping out or wrapping core behaviours without requiring core code changes.

---

## 6. Core-to-Pro Migration Policy

To maintain trust with the open-source community while sustaining commercial viability, all core and Pro development adheres to a four-point policy:

1. **Sole Copyright Retains Relicensing Rights:** As sole copyright holder (or via CLA grant), licensing the core codebase under Apache-2.0 grants broad rights to third parties but surrenders none. The author may copy core code into Pro and distribute it under proprietary terms at any time.
2. **Published Releases are Permanent:** Once a version or module is published under Apache-2.0, that grant is irrevocable. Every release published under Apache-2.0 remains Apache-2.0 forever and remains publicly forkable. Removing a capability from future versions of the core repository does not erase it from the public domain or historical tags.
3. **Additive Pattern Only (No Capability Subtractions):** Pro features must follow an **additive pattern**: Pro provides more capable implementations behind established core behaviours, or introduces entirely new capabilities that never existed in core. Core capabilities that users depend on must **not** be stripped or retroactively gated behind a paywall. Gating previously open features behind commercial licenses is what caused severe community backlash in the Redis, Elastic, and Terraform relicensing controversies.
4. **Operational Consequence:** Any feature or capability intended for Arbiter Pro must **never be shipped in the core repository first**. Once published in core under Apache-2.0, that code is permanently public and cannot be withdrawn.

---

## 7. Open Questions

The following questions remain unresolved and are explicitly deferred:

1. **Trademark Clearance on "Arbiter":**
   * *Status:* Unresolved.
   * *Detail:* The name "Arbiter" is generic and has established usage across distributed systems vocabularies (e.g., etcd consensus arbiters, Kubernetes cluster arbiters, MongoDB arbiters).
   * *Next Step:* Conduct a comprehensive trademark knockout search to evaluate registration viability and conflict risks.
2. **Arbiter Pro Tier Scope:**
   * *Status:* Unresolved.
   * *Detail:* The precise boundaries and feature set of Arbiter Pro (e.g., advanced multi-tenant analytics, proprietary enterprise tracker integrations, complex fleet coordination policies) are deferred until customer demand and commercial feedback are established.

---

## 8. Merge Preconditions

* **Leo Technologies IP Waiver:**
  * Prior to merging the official `LICENSE` file and concluding the initial licensing milestone, an IP waiver from Leo Technologies is a required merge precondition.
  * This addresses the **215 commits** in project history authored under the git identity `ryan.born@leotechnologies.com` to ensure unambiguous ownership and unencumbered licensing rights.
