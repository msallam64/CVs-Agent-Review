# CV Review Agent

A Salesforce/Agentforce agent that ingests CVs, answers grounded natural-language
questions about candidates, compares and ranks them with explainable scoring, and
lets recruiters bookmark evaluations — while explicitly representing **missing,
inferred, and conflicting** information and never hallucinating.

> **The thesis: this is about trust, not extraction.**
> Anyone can prompt a model to pull skills out of a CV. The hard part is making
> the output *trustworthy* — so the whole design treats **grounding, uncertainty,
> and explainability as structure that Apex verifies, not as prose the model
> promises.** The prompt *asks* for honest output; Apex *proves* it before
> anything is stored or shown. A claim that can't point at CV text is dropped,
> however confident the model sounded.

---

## Table of contents
1. [Architecture overview](#1-architecture-overview)
2. [Data model & Candidate Card design](#2-data-model--candidate-card-design)
3. [Key design decisions & trade-offs](#3-key-design-decisions--trade-offs)
4. [Assumptions](#4-assumptions)
5. [Known limitations](#5-known-limitations)
6. [Testing approach](#6-testing-approach)
7. [What I'd improve next](#7-what-id-improve-next)
8. [How to run](#8-how-to-run)

---

## 1. Architecture overview

Three layers, with a single rule: **the LLM reasons; Apex enforces honesty and does anything deterministic.**

```mermaid
flowchart TD
    R[Recruiter] -->|natural language| A[Agentforce Agent + Topic]
    A -->|delegates| ACT[Invocable Apex Actions]
    LWC[LWC UI: Card / Comparison / Upload] -->|@AuraEnabled| CTRL[CVAgentController]
    CTRL -->|same actions| ACT
    ACT -->|ILLMService| CS[ClaudeService]
    CS -->|Named Credential| CLAUDE[(Claude API)]
    ACT -->|verified data only| DB[(Candidate / Fact / Bookmark)]
    ACT -->|audit| LOG[(Agent_Log__c)]
```

**Why this shape:**
- **Agentforce is orchestration only.** It classifies intent and calls actions. It holds no business logic — so the layer we control the least holds the least responsibility.
- **The invocable Apex actions are where honesty is enforced.** Every action that turns model output into stored/shown data runs a verification gate.
- **Claude sits behind one interface (`ILLMService`).** Swappable and mockable — which is what makes the honesty claims *testable* without a live callout.
- **The LWC controller delegates to the same actions the agent uses**, so the UI and the agent can never diverge.

### The five actions

| Action | Purpose | The honesty guarantee |
|---|---|---|
| `FindCandidates` | Resolve a name/keyword → candidate Ids | (read-only helper) |
| `IngestCV` | CV text → structured Candidate Card | Facts with no verbatim evidence are **dropped** |
| `QueryCandidates` | Grounded Q&A (single & multi) | Answer is suppressed to `Not found in the CV.` unless a cited quote **verifies** against the source |
| `ScoreAndCompare` | Explainable ranking for a role | Model judges each criterion; **Apex computes the score & ranks**; ungrounded criteria collapse to gaps |
| `BookmarkCandidate` | Save an evaluation | One self-contained, auditable snapshot |

---

## 2. Data model & Candidate Card design

The **Candidate Card** is a `Candidate__c` plus its child `Fact__c` rows. The central design choice: **uncertainty is modeled as data, not as text.** Every extracted fact is its own row carrying a certainty label and a verbatim evidence quote — so uncertainty is queryable, roll-up-summable, and renderable, instead of being buried in a summary paragraph.

| Object | Role | Key fields |
|---|---|---|
| `Candidate__c` | The Candidate Card header | `Email__c`, `Phone__c`, `Summary__c`, `CV_Text__c`, `Confidence__c` (High/Med/Low), `Status__c` (Parsed/Partial/Failed), roll-ups `Conflict_Count__c` / `Missing_Count__c` |
| `Fact__c` | One extracted claim (master-detail to Candidate) | `Type__c` (Skill/Experience/Education/Achievement/Certification), `Detail__c`, **`Certainty__c` (Stated/Inferred/Conflicting/Missing)**, **`Evidence__c` (verbatim CV quote)**, `Conflict__c` |
| `Bookmark__c` | Saved evaluation | `Candidate__c`, `Role__c`, `Score__c`, `Reason__c`, `Notes__c`, `Snapshot__c` (JSON at eval time), `Saved_At__c` |
| `Agent_Log__c` | Audit trail of agent actions | `Action__c`, `Status__c`, `Input__c`, `Output__c`, `Error__c`, `Duration_ms__c` |
| `Rubric_Criterion__mdt` | Scoring rubric **as data** | `Weight__c`, `Guidance__c`, `Active__c` |
| `Scoring_Config__mdt` | Certainty discounts + threshold **as data** | discount per certainty, `Strong_Match_Threshold__c` |
| `LLM_Config__mdt` | Model/endpoint config | `Model__c`, `Named_Credential__c`, `Max_Tokens__c` |

The four `Certainty__c` values are a **restricted picklist** that exactly mirrors the Apex validation vocabulary, so the database and the code can't drift. `Conflict_Count__c` / `Missing_Count__c` are roll-up summaries — the recruiter sees "2 conflicts, 3 unknowns" on the record without opening a single fact.

---

## 3. Key design decisions & trade-offs

**1. Grounding is enforced in code, not requested in the prompt.**
`CVParser` drops any Stated/Inferred/Conflicting fact whose evidence field is blank; `QueryCandidates` and `ScoreAndCompare` verify each cited quote against the source and suppress anything that doesn't match. *Trade-off:* the verification is a strict normalized substring check, which biases toward **false negatives** (a near-verbatim quote can be rejected). That's deliberate — for a trust-first system, refusing when we could have answered is far safer than answering when we shouldn't have.

**2. The model judges; Apex computes and ranks.**
For scoring, the model assesses one candidate against one criterion at a time and cites evidence. It never produces an overall score, and it never compares candidates. Apex computes `score = Σ(match × weight × discount)` and sorts. *Why:* a model-produced score is an unverifiable, non-reproducible black box — the exact thing the assignment tests against. This way every point traces to a criterion, a weight, an evidence quote, and a certainty.

**3. Uncertainty moves the number.**
Each criterion's contribution is discounted by the certainty of the facts behind it (Stated 1.0 / Inferred 0.6 / Conflicting 0.4 / Missing 0.0). `Missing` counts as zero **but is surfaced as a gap to validate, never a confirmed weakness** — paired with a *coverage* signal so "we don't know enough" is distinguishable from "this candidate is weak." This is what powers the task's "no strong match → best available + gaps to validate in interview."

**4. Scoring policy is data, not code.**
Rubric weights, certainty discounts, and the strong-match threshold all live in Custom Metadata. A reviewer can read every number that produces a score; Apex only does arithmetic.

**5. Prompts live in Apex (`CVPrompts`), deliberately.**
They started in Custom Metadata for hot-tuning — until a length-255 field **silently truncated** a ~2,200-character prompt on every deploy, producing rounds of apparent "model misbehavior" that were really the model working from two sentences. Prompts now live in a version-controlled Apex constants class: diffable, atomic with the code that depends on them, and immune to that class of bug.

**6. Model choice.** Haiku 4.5 could not reliably hold the six-field extraction schema (it invented its own shapes); the project uses `claude-sonnet-4-5-20250929`. Reliability came from schema-first prompt ordering + explicit negative instructions + response prefill (seeding the assistant turn with `{`).

**7. The LLM is behind one seam (`ILLMService`).** A single interface with a mock double is what lets the anti-hallucination guarantees be **proven by tests** with no live callout.

**8. The ingestion boundary is isolated and stubbed.** PDF/DOC → text extraction is treated as an external service (which the task permits stubbing) behind the UI, rather than a half-working parser — see limitations.

---

## 4. Assumptions

- **CV text is available.** Extraction of raw text from PDF/DOC is out of scope and stubbed; the pipeline operates on CV text (pasted, `.txt`, or provided by an upstream extractor).
- **English-language CVs.** Prompts and heuristics assume English.
- **One evaluation configuration.** A single default `LLM_Config` and one default rubric; multi-tenant/per-role rubrics are not modeled (though the metadata design allows adding them).
- **Candidate names are reasonably distinct** for the name→Id helper; ambiguous duplicates return all matches for the recruiter to disambiguate.
- **The recruiter is a trusted internal user.** Object/field access is granted via the `CV_Agent_Access` permission set; there is no external/guest exposure.
- **Evaluation is point-in-time.** A bookmark snapshots the evaluation as shown; it is not re-computed later.

---

## 5. Known limitations

- **PDF/DOC extraction is stubbed.** The upload LWC reads `.txt` client-side and accepts pasted text; binary formats show a documented "extraction stubbed" notice. This is an isolated boundary, not woven into the core.
- **Grounding verification is a strict substring match.** A truthful answer whose quote is paraphrased or lightly reworded can be rejected (false negative). Chosen intentionally over the riskier alternative.
- **Single-candidate certainty is weaker than multi-candidate.** In multi-candidate mode certainty is *read from the verified Fact rows*; in single-candidate mode (raw CV text) it is the model's claim, constrained to the enum. An honest asymmetry that follows from the hybrid context strategy.
- **Bookmarks are not de-duplicated.** Each bookmark action creates one record by design; the same candidate+role can be bookmarked twice.
- **LWC has no Jest tests.** The Apex controller is fully tested; the JS components are not (they carry no business logic — that lives in the tested actions).
- **Org-specific deploy quirk.** The development org rejects Custom Metadata *record* deploys with `UNKNOWN_EXCEPTION` (type definitions deploy fine). The rubric/scoring records are therefore created via the org UI, and the Apex has a fallback identical to the seeded records so runtime is unaffected — see [How to run](#8-how-to-run).

---

## 6. Testing approach

**58 Apex tests**, all green, structured to *prove the trust guarantees* rather than just exercise code:

| Test class | What it proves | # |
|---|---|---|
| `CVParserTest` | Missing facts kept without evidence; **ungrounded Stated facts rejected** (the core anti-hallucination proof); certainty/type normalized; malformed JSON fails cleanly | 9 |
| `IngestCVTest` | End-to-end ingestion with the LLM mocked; graceful degradation with zero partial records; bulk-safe | 6 |
| `ClaudeServiceTest` | Real HTTP handling via `HttpCalloutMock` — including **an error object inside a 200 body** being treated as failure | 6 |
| `QueryCandidatesTest` | Verified answers pass; refusals pass; **fabricated quotes are suppressed**; multi-candidate certainty comes from the fact, not the model | 8 |
| `ScoreAndCompareTest` | Discount maths; **a fabricated criterion collapses to a gap**; coverage falls with unknowns; deterministic Apex-side ranking | 8 |
| `ScoringPolicyTest` | Metadata read + fallback + discount map | 3 |
| `BookmarkCandidateTest` | One self-contained auditable record; invalid input rejected; bulk-safe | 7 |
| `FindCandidatesTest` | Partial/case-insensitive match, list-all, empty result, bulk | 6 |
| `CVAgentControllerTest` | Card grouping order; ingest/compare delegation | 5 |

The design principle: the **grounding gate is the thing under test**. `ungrounded_fact_is_rejected`, `fabricated_quote_is_suppressed`, and `fabricated_quote_collapses_to_a_gap` are the three tests that back the README's central claim.

The org enforces **75% per-class coverage on deploy**, so every class ships with its own test.

Run them:
```bash
sf apex run test --test-level RunLocalTests --result-format human --wait 20
```

---

## 7. What I'd improve next

One genuine item, not a padded list: **replace the strict substring grounding check with a span-alignment check that tolerates minor reformatting** (whitespace/case are already handled, but not light paraphrase). Today the gate errs toward false negatives — a truthful answer can be refused because its quote isn't byte-for-byte. A fuzzy-but-still-grounded matcher (e.g. token-overlap against the source with a high threshold) would keep the guarantee — no answer without real support — while refusing fewer good answers. It's the one place where the safe choice visibly costs recall.

---

## 8. How to run

### Prerequisites
- Salesforce CLI, and an org authorized as the default (`sf org login web`).

### Deploy the code
```bash
sf project deploy start -d force-app --ignore-conflicts
```
This deploys the objects, the 5 Apex actions + controller, the LWCs, and the `CV_Agent_Access` permission set. *(Custom Metadata **records** may fail on some orgs — see the manual step below; the code runs correctly without them via built-in fallbacks.)*

### One-time manual setup (org UI)

**a) Claude connection** — create an **External Credential** (custom auth; a principal with an `ApiKey` parameter; custom headers `x-api-key` and `anthropic-version`) and a **Named Credential** `Claude_Integration` pointing at `https://api.anthropic.com`. Enter your Anthropic API key on the principal. *(The key is never stored in source.)*

**b) Scoring policy records** — Setup → Custom Metadata Types → **Manage Records**:

*Rubric Criterion* (4 records):

| Label / Name | Weight | Active |
|---|---|---|
| Technical Skills / `Technical_Skills` | 40 | ✅ |
| Relevant Experience / `Relevant_Experience` | 30 | ✅ |
| Education / `Education` | 15 | ✅ |
| Achievements / `Achievements` | 15 | ✅ |

*Scoring Config* (`Default`): Discount Stated `1.0`, Inferred `0.6`, Conflicting `0.4`, Missing `0.0`, Strong Match Threshold `60`.

*(These are optional — the Apex fallback uses identical values — but create them so the scoring policy is visible and tunable as data.)*

**c) Permissions** — assign the `CV Agent Access` permission set to yourself **and** to the Einstein Agent User:
```bash
sf org assign permset --name CV_Agent_Access
```

**d) Agent wiring** (Agentforce Studio) — create an agent, add a **Candidate Review** topic, and attach all five actions (Find Candidates, Ingest CV, Query Candidates, Score And Compare Candidates, Bookmark Candidate). *Two traps to avoid: each action must be **explicitly attached to the topic**, and the **agent user needs Apex-class access** (granted by the permission set above).*

### See the UI
Add `candidateCard` to the `Candidate__c` record page, and `candidateComparison` + `cvUpload` to an App/Home page via Lightning App Builder.

### Try it
Ingest two CVs → "compare them for a Senior Salesforce Developer role" → "bookmark the top one, note: strong culture fit."
