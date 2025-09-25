### AGENTS.md

A unified "contract" for AI agents (Codex) and humans working with the repository. This document describes the project's goals, architecture, repository structure, rules for changes, environment setup, tests, security, observability, and quality criteria. Follow this file, and you will build a predictable, scalable system.

#### 1\) Purpose and Scope

**Project goal:** CRM/ops pipelines based on n8n + PostgreSQL with an "end-to-end thread" from inbound sources to communications:

- **Inbound forms** → AI classification → CRM (company/contact/lead) → auto-replies.
- **Calendly intake** → bookings → lead stage synchronization.
- **Sequencer (follow-ups)** → multi-step campaigns.
- **Newsletter (Double-Opt-In, unsubscribes)** → bulk mailings.
- **Inbox Email (IMAP)** → ingest correspondence into conversations.
- **HR intake** → candidates, pool, follow-ups.
- **Docs (NDA/Partner)** → preparation, signing (integrations).
- **Content digest (RSS/API)** → thematic digests.

**Key principles:** idempotency, deterministic state transitions, centralized event logging, minimal manual work, clear separation of data and logic.

#### 2\) High-Level Architecture Overview

- **n8n** — workflow orchestration: webhooks, timers, integrations, email, AI transformations, business rules.
- **PostgreSQL** — "source of truth": normalized schema (company/contact/lead, messages, bookings, templates, subscriptions/consents, pipeline_events, etc.).
- **AI services** — classification and generation (provider is abstracted via env variables).
- **Communications** — Email (SMTP/Gmail), Calendly, Telegram alerts.
- **Observability** — events log in the DB + health checks + alerts for errors/stalls.

#### 3\) Repository Structure

```
/                       # project root
├─ AGENTS.md            # this file — contract and instructions for agents/humans
├─ README.md            # a brief showcase: what it is and how to quick-start
├─ LICENSE
├─ .editorconfig
├─ .gitattributes
├─ .gitignore
├─ .nvmrc               # Node version (LTS)
├─ package.json         # scripts and dev-dependencies (pnpm/yarn are acceptable)
├─ pnpm-lock.yaml
├─ .env.example         # example environment variables (should not contain secrets)
│
├─ docs/                # documentation for humans (see details below)
│  ├─ architecture.md
│  ├─ data-model.md
│  ├─ flows.md
│  ├─ decisions/ADR-0001-....md
│  └─ playbooks/
│     ├─ oncall-runbook.md
│     └─ release-checklist.md
│
├─ n8n/                 # everything about n8n: flows, validation schemas, utilities
│  ├─ flows/
│  │  ├─ crm.in.forms.json
│  │  ├─ crm.proc.dev_request.json
│  │  ├─ ops.in.calendly.json
│  │  ├─ mkt.proc.sequencer.json
│  │  └─ sub.mkt.send_sequence_step.json
│  ├─ schemas/
│  │  └─ n8n.flow.schema.json       # JSON-Schema for quick validation of flow exports
│  └─ scripts/
│     ├─ validate-flows.mjs         # validate structure and fields before commit/CI
│     ├─ import-flows.mjs           # import *.json into local n8n via API/CLI
│     └─ export-flows.mjs           # export from local n8n to /n8n/flows
│
├─ sql/                  # DB: migrations, functions, seeds, tests
│  ├─ migrations/
│  │  ├─ 2025-09-22_0001_initial.sql
│  │  └─ ...
│  ├─ seeds/
│  │  ├─ templates.sql             # base email templates, sequences
│  │  └─ demo-data.sql
│  ├─ functions/
│  │  ├─ helpers.sql               # utility functions (e.g., phone normalization)
│  │  └─ ...
│  └─ verify/                      # pgTAP/SQL checks for schema, triggers, uniqueness
│     └─ 001_schema_basics.sql
│
├─ schemas/              # contract schemas for incoming/outgoing payloads
│  ├─ payloads/
│  │  ├─ form.submit.schema.json
│  │  ├─ calendly.webhook.schema.json
│  │  └─ imap.message.schema.json
│  └─ db/
│     └─ templates.schema.json
│
├─ fixtures/             # mock data for e2e/CI and local replay
│  ├─ forms/
│  │  ├─ website-lead-basic.json
│  │  └─ ...
│  ├─ calendly/
│  │  ├─ event-created.json
│  │  └─ event-canceled.json
│  ├─ imap/
│  │  ├─ sample-thread-1.json      # normalized json (or .eml in raw/)
│  │  └─ raw/
│  │     └─ sample.eml
│  └─ newsletter/
│     └─ doi-roundtrip.json
│
├─ src/                  # helper utilities (Node/TS): validation, CLI, adapters
│  ├─ cli/
│  │  ├─ replay-fixture.ts         # "run" a fixture through the local n8n
│  │  └─ healthcheck.ts
│  ├─ lib/
│  │  ├─ env.ts
│  │  ├─ logger.ts
│  │  └─ mailer.ts
│  └─ validators/
│     └─ jsonschema.ts
│
├─ scripts/              # bash/node scripts for CI and local execution
│  ├─ setup.sh
│  ├─ migrate.sh
│  ├─ seed-templates.ts
│  ├─ check-health.mjs
│  └─ precommit-validate.mjs
│
├─ ops/                  # observability and operations
│  ├─ dashboards/
│  ├─ alerts/
│  └─ healthchecks/
│     └─ db.sql
│
├─ tests/
│  ├─ integration/
│  │  ├─ db.spec.ts
│  │  └─ flows.spec.ts
│  └─ e2e/
│     └─ demo-journey.spec.ts
│
└─ .github/
   ├─ workflows/ci.yml
   ├─ ISSUE_TEMPLATE.md
   ├─ PULL_REQUEST_TEMPLATE.md
   └─ CODEOWNERS
```

**Rule:** The structure is part of the contract. Add new folders/files strictly with intention and reflect them in this document (a PR with changes to AGENTS.md is mandatory).

#### 4\) AI Agent Roles and "Contract"

**Agent role:** senior engineer/integrator. The agent has access to the code, runs scripts, validates schemas and flows, and opens PRs. Storing/writing secrets in the repo is forbidden.

**Always execute before making changes:**

1.  `node n8n/scripts/validate-flows.mjs` (validate flow JSONs).
2.  `bash scripts/migrate.sh --check` (check migrations/DB state).
3.  `pnpm test` (do not break existing tests).

**Agent rules of conduct:**

- **Respect idempotency:** no logic that violates unique keys/foreign constraints. Wherever external sources are involved, use an idempotency key (external_id, message_id, booking_id).
- **Any new logic → events in `pipeline_events`** (start, success, error, retry, correlation).
- **Validation of incoming payloads** — strictly according to JSON-Schema from `/schemas/payloads/*`.
- **Migrations are forward-only;** rollbacks are done in a separate PR and only with a description of the consequences.
- **Any change to tables with PII** — coordinate the retention and anonymization schema.
- **n8n flows** — keep them atomic: one input, clear outputs, explicit error branches.
- **Emails/messages** — generate them using `templates` (no hardcoded strings in nodes), log all renders.

#### 5\) Running the Environment

##### 5.1 Locally (without Docker)

1.  Node LTS (see `.nvmrc`), pnpm.
2.  PostgreSQL ≥14 (locally or via Docker Compose).
3.  n8n locally (CLI/desktop) — the agent can import/export flows.
4.  Copy `.env.example` → `.env` and fill in the values.
5.  **Commands:**
    ```bash
    pnpm i
    bash scripts/setup.sh           # check tools
    bash scripts/migrate.sh up      # apply migrations
    pnpm run seed:templates         # seed base templates
    pnpm test                       # run tests
    node src/cli/replay-fixture.ts fixtures/forms/website-lead-basic.json
    ```

##### 5.2 CI (GitHub Actions)

- `services.postgres` → initialize DB → migrations → seeds → tests.
- **Artifacts:** test reports, exported n8n flows (if changed).
- Block merge on "red" tests/validation/linting.

#### 6\) Environment Variables

`.env.example` contains only keys without values, along with comments:

```dotenv
DATABASE_URL=postgres://...
N8N_ENCRYPTION_KEY=...
SMTP_HOST/SMTP_USER/SMTP_PASS or GMAIL_OAUTH_*
TELEGRAM_BOT_TOKEN
CALENDLY_WEBHOOK_SECRET
LLM_PROVIDER=anthropic|openai
ANTHROPIC_API_KEY/OPENAI_API_KEY
IMAP_HOST/IMAP_USER/IMAP_PASS
NEWSLETTER_SENDER, UNSUB_BASE_URL
```

Do not commit secrets. In CI — only via GitHub Secrets. If necessary, use SOPS/age (policy described in `docs/security.md`).

#### 7\) Data and DB Schema (High-Level)

**Key entities:**

- `company`, `contact`, `lead` (lead ↔ company/contact relations, statuses, and history).
- `messages` (outgoing/incoming emails, `message_id`, `conversation_id`).
- `bookings` (Calendly), `booking_id`, mapping to a lead.
- `templates` (email/step templates), `template_key`, versions.
- `subscriptions`, `consents` (newsletter/DOI, unsubscribes, retention policy).
- `pipeline_events` (universal event log, correlations, retries).

**Invariants:**

- All external payloads carry a unique key, mapped to `external_id`/`message_id`.
- Status updates are handled deterministically (FSM/state transition table).
- "Dirty" data is not mixed with normalized data: raw payloads are stored in staging tables.

Details are in `docs/data-model.md`.

#### 8\) Quality, DoD, and Review

**Definition of Done (General):**

- Migrations apply to a clean DB; pgTAP checks are green.
- n8n flows are valid against `n8n.flow.schema.json`; error branches and retries are added.
- Input/output payloads are validated against JSON-Schema.
- Event logs are written at key steps; alerts are configured for errors.
- Test coverage: critical path + regressions.
- Documentation is updated (`AGENTS.md`/`flows.md`/`architecture.md`).

**PR Guide:**

- Small, atomic PRs. Branch name: `feature/<slug>` or `fix/<slug>`.
- Description of changes: what, why, how it was tested, migrations, schemas.
- Screenshots/exports of n8n if flows were changed.
- CI is green. Merge is forbidden otherwise.

#### 9\) Observability and Alerts

- Basic health checks in `ops/healthchecks/` (DB, task queue, event freshness).
- Telegram/Slack alerts for: errors in flows, "stuck" tasks, external provider failures, increased response time.
- Mini-dashboards: "new leads by day," "bookings/unsubscribes," "errors in 24h." Scripts are in `scripts/check-health.mjs`, showcases in `ops/dashboards/`.

#### 10\) Security and Compliance (PII/GDPR)

- Separation of DB roles: read/write/migrations.
- PII retention by data type, anonymization in logs/fixtures.
- Double-Opt-In for newsletters, explicit storage of consents, one-click unsubscribe.
- Secrets — only via environment variables/CI Secrets, no commits.
- Audit of access to prod data (if applicable), logging of admin actions.

#### 11\) Flows (Catalog of Current/Planned)

This list is more of a "registry" than a task assignment.

- `crm.in.forms` — receive form, validate, AI classification, upsert company/contact/lead, transition status, log event, trigger emails.
- `crm.proc.dev_request` — assemble response email from templates, translate/localize, send, track.
- `ops.in.calendly` — sync bookings (created/canceled), link to lead, alerts.
- `mkt.proc.sequencer` (+ `sub.mkt.send_sequence_step`) — sequence scheduler, segment selection, steps with waits and stop conditions.
- `newsletter` — Double-Opt-In, mailing, unsubscribes, retention.
- `inbox.imap` — ingest correspondence, threading, deduplication by Message-ID, auto-tagging.
- `hr.intake` — candidate applications, screening, statuses/pool, follow-ups.
- `docs.partner` — prepare and track agreements/signatures.
- `content.digest` — collect and normalize materials (RSS/API), publish digests.

#### 12\) Change Checklists

**Before changing the DB schema:**

- [ ] ADR in `docs/decisions/` (if no precedent).
- [ ] Forward migration, pgTAP check; rollback migration as a separate task.
- [ ] Updated JSON schemas if payloads are affected.

**Before changing an n8n flow:**

- [ ] Error branches and retries are added.
- [ ] All external calls are protected by timeouts and checkpoints.
- [ ] Event logs at key steps, correlation by key.
- [ ] Exported `.json` passes `n8n/scripts/validate-flows.mjs`.

**Before merge:**

- [ ] CI is green (lint/tests/validations).
- [ ] Documentation is updated (at a minimum, this file, if structure/rules are affected).

#### 13\) Commands (package.json)

Recommended set:

```json
{
  "scripts": {
    "setup": "bash scripts/setup.sh",
    "migrate": "bash scripts/migrate.sh up",
    "migrate:check": "bash scripts/migrate.sh --check",
    "seed:templates": "ts-node scripts/seed-templates.ts",
    "flows:validate": "node n8n/scripts/validate-flows.mjs",
    "flows:import": "node n8n/scripts/import-flows.mjs",
    "flows:export": "node n8n/scripts/export-flows.mjs",
    "replay": "ts-node src/cli/replay-fixture.ts",
    "health": "node scripts/check-health.mjs",
    "lint": "eslint .",
    "test": "jest --runInBand"
  }
}
```

#### 14\) CI (Minimal Pipeline)

`.github/workflows/ci.yml` (draft):

```yaml
name: ci
on: [push, pull_request]
jobs:
  build:
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:14
        env:
          POSTGRES_PASSWORD: postgres
        ports: ["5432:5432"]
        options: >-
          --health-cmd="pg_isready -U postgres" --health-interval=10s --health-timeout=5s --health-retries=5
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with: { node-version-file: ".nvmrc" }
      - run: corepack enable
      - run: pnpm i --frozen-lockfile
      - run: bash scripts/migrate.sh up
        env:
          {
            DATABASE_URL: postgresql://postgres:postgres@localhost:5432/postgres,
          }
      - run: pnpm seed:templates
        env:
          {
            DATABASE_URL: postgresql://postgres:postgres@localhost:5432/postgres,
          }
      - run: pnpm flows:validate
      - run: pnpm lint
      - run: pnpm test
```

#### 15\) Glossary

- **Idempotency** — re-running an operation does not change the final state (we use unique keys, UPSERT, pre-write checks).
- **Staging data** — raw, unprocessed payloads from external sources that we store separately.
- **FSM** (Finite State Machine) — a deterministic table of status transitions for a lead/application.
- **DLQ** (Dead-Letter Queue) — we store failed messages here and replay them manually or via a script.

#### 16\) Changing This Document

Any changes to the structure/rules are made through a PR, with a brief ADR (decision/alternatives/justification). The goal is to make the project predictable for humans and agents, ensuring the "end-to-end thread" always stays green.

---

End of AGENTS.md
