# QuantCore Agent Skill Router (Single Entrypoint)

## 1. Global LLM Response & Token Contract (MANDATORY)
- **Zero Fluff**: Never output greetings, conversational filler, or unrequested summaries.
- **Compact Output**: Respond with telegraphic bullets or minimal code diffs. Omit unchanged functions.
- **Ask Before Assuming**: If critical ambiguity exists, ask max 2 one-line questions and stop.
- **Requirement 0 ($0 Spend)**: Never introduce paid APIs, cloud SDKs, or subscription market feeds.

## 2. Progressive Reference Tree (Lazy-Load ONLY Relevant Leaf)
Do NOT read all files below. Read strictly the reference matching your active file target:
- Editing system boundaries, queues, or Docker topology -> `skills/references/architecture-invariants.md`
- Editing `src/QuantCore.Api/**` or `src/QuantCore.Contracts/**` -> `skills/references/dotnet-api-practices.md`
- Editing `src/quant_nn_worker/**` -> `skills/references/python-nn-practices.md`
- Editing `migrations/**` or SQL queries -> `skills/references/postgres-concurrency.md`
- Editing `src/quant-ui/**` -> `skills/references/react-realtime-ui.md`
- Editing `tests/**` or `.github/workflows/**` -> `skills/references/testing-and-cicd.md`
- Generating explanations or reviews -> `skills/references/communication-style.md`
