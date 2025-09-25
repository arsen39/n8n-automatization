# n8n + PostgreSQL CRM/Ops Pipelines

Production‑ready automation for inbound → CRM → emails → bookings → follow‑ups. This repository contains opinionated n8n flows, a normalized PostgreSQL schema, and tooling to run, test, and observe the system.

---

## Why this repo

- **End‑to‑end value path**: from website forms and inbox ingestion to templated replies, Calendly bookings, multi‑step sequences, and newsletters.
- **Data first**: a clean relational model (companies, contacts, leads, messages, bookings, templates, subscriptions, consents, events).
- **Predictable ops**: idempotency, JSON‑Schema validation, forward‑only migrations, health checks, and alerting.

> For agent instructions (Codex/AI tools), see **AGENTS.md**. This README focuses on humans.

---

## Highlights

- Inbound form intake with AI classification/enrichment
- Templated personalized emails (multi‑language), logged to `messages`
- Calendly intake (create/cancel) with lead status sync
- Sequencer for follow‑ups (F1/F2… steps, stop conditions, quiet hours)
- Newsletter with Double‑Opt‑In & one‑click unsubscribe
- Inbox IMAP ingestion → conversation threading & dedup by `Message-ID`
- HR intake for candidates and talent pool
- Central `pipeline_events` for observability and on‑call debugging

---

## Architecture (high level)

```
External Sources
  ├─ Website Forms ─────────┐
  ├─ Calendly Webhooks ───┐ │
  ├─ IMAP Inbox ────────┐ │ │
  └─ RSS/API Feeds ───┐ │ │ │
                      ▼ ▼ ▼ ▼
                  n8n Flows (webhooks, timers, integrations, AI)
                      │   │   │
                      │   │   ├─ Emails / Calendly / Telegram Alerts
                      │   │
                      ▼   ▼
                  PostgreSQL (normalized CRM + events + templates)
                      │
                      └─ Analytics / Healthchecks / Playbooks
```

Key principles: **idempotency keys** for all external payloads, deterministic state transitions, atomic flows with explicit error branches, and event logs at critical steps.

---

## Repository layout

```text
/                       # project root
├─ AGENTS.md            # contract for agents (Codex) and maintainers
├─ README.md            # you are here
├─ .editorconfig / .gitattributes / .gitignore
├─ .nvmrc               # Node LTS version
├─ package.json         # scripts & dev deps (pnpm/yarn supported)
├─ .env.example         # list of env vars (no secrets)
│
├─ docs/
│  ├─ architecture.md
│  ├─ data-model.md
│  ├─ flows.md
│  ├─ decisions/ADR-*.md
│  └─ playbooks/
│     ├─ oncall-runbook.md
│     └─ release-checklist.md
│
├─ n8n/
│  ├─ flows/
│  │  ├─ crm.in.forms.json
│  │  ├─ crm.proc.dev_request.json
│  │  ├─ ops.in.calendly.json
│  │  ├─ mkt.proc.sequencer.json
│  │  └─ sub.mkt.send_sequence_step.json
│  ├─ schemas/
│  │  └─ n8n.flow.schema.json
│  └─ scripts/
│     ├─ validate-flows.mjs
│     ├─ import-flows.mjs
│     └─ export-flows.mjs
│
├─ sql/
│  ├─ migrations/
│  ├─ seeds/
│  │  ├─ templates.sql
│  │  └─ demo-data.sql
│  ├─ functions/
│  └─ verify/   # pgTAP checks
│
├─ schemas/
│  ├─ payloads/
│  │  ├─ form.submit.schema.json
│  │  ├─ calendly.webhook.schema.json
│  │  └─ imap.message.schema.json
│  └─ db/
│     └─ templates.schema.json
│
├─ fixtures/
│  ├─ forms/
│  ├─ calendly/
│  ├─ imap/
│  └─ newsletter/
│
├─ src/
│  ├─ cli/
│  │  ├─ replay-fixture.ts
│  │  └─ healthcheck.ts
│  ├─ lib/
│  │  ├─ env.ts
│  │  ├─ logger.ts
│  │  └─ mailer.ts
│  └─ validators/
│     └─ jsonschema.ts
│
├─ scripts/
│  ├─ setup.sh
│  ├─ migrate.sh
│  ├─ seed-templates.ts
│  ├─ check-health.mjs
│  └─ precommit-validate.mjs
│
├─ ops/
│  ├─ dashboards/
│  ├─ alerts/
│  └─ healthchecks/
│     └─ db.sql
│
├─ tests/
│  ├─ integration/
│  └─ e2e/
│
└─ .github/
   ├─ workflows/ci.yml
   ├─ ISSUE_TEMPLATE.md
   ├─ PULL_REQUEST_TEMPLATE.md
   └─ CODEOWNERS
```

---

## Prerequisites

- Node **LTS** (see `.nvmrc`) and **pnpm** (or yarn/npm)
- PostgreSQL **14+** (local or via a container)
- n8n (desktop or CLI) for importing/exporting flows

---

## Quickstart

```bash
# 1) Install deps
corepack enable && pnpm i

# 2) Prepare environment
cp .env.example .env    # fill values (no secrets committed)

# 3) Database: migrate & seed
bash scripts/migrate.sh up
pnpm run seed:templates

# 4) Validate flows before any edit
pnpm run flows:validate

# 5) Run tests
pnpm test

# 6) Optional: replay a demo fixture through local n8n
pnpm run replay fixtures/forms/website-lead-basic.json
```

**Demo journey (what to expect):** form → AI classification → upsert company/contact/lead → templated reply → (optional) Calendly booking → lead stage update → Telegram alert.

---

## Working with n8n flows

- Keep flows **atomic** with explicit **error branches** and retry policy.
- Use `n8n/scripts/import-flows.mjs` and `export-flows.mjs` to sync JSON with a local n8n.
- Validate all edited flows with `pnpm flows:validate` before committing.
- Do not hard‑code message bodies—use the `templates` table and render at runtime.

---

## Database & migrations

- Forward‑only migrations live in `sql/migrations/` (timestamped filenames).
- Verified by `sql/verify/` (e.g., pgTAP) in CI.
- Staging/raw payloads are stored separately from normalized entities.
- Every external payload must carry a unique id → map to `external_id`/`message_id`.

---

## Environment variables (`.env.example`)

```
DATABASE_URL=postgres://user:pass@localhost:5432/db
N8N_ENCRYPTION_KEY=
# Mail
SMTP_HOST=   SMTP_USER=   SMTP_PASS=
# or Gmail OAuth
GMAIL_OAUTH_CLIENT_ID=   GMAIL_OAUTH_CLIENT_SECRET=   GMAIL_OAUTH_REFRESH_TOKEN=
# Calendly
CALENDLY_WEBHOOK_SECRET=
# LLM provider
LLM_PROVIDER=anthropic|openai
ANTHROPIC_API_KEY=   OPENAI_API_KEY=
# IMAP inbox
IMAP_HOST=   IMAP_USER=   IMAP_PASS=
# Comms
TELEGRAM_BOT_TOKEN=
NEWSLETTER_SENDER=   UNSUB_BASE_URL=
```

> Secrets never live in the repo. In CI use GitHub Secrets (or SOPS/age if needed).

---

## Testing & quality gates

- **Schema**: pgTAP checks in `sql/verify/` (unique keys, FKs, invariants)
- **Flows**: JSON‑Schema validation of n8n exports
- **Integration**: fixtures in `fixtures/*` + `src/cli/replay-fixture.ts`
- **CI**: blocked merges on failing tests/linters/flow validation

---

## Observability

- Event logging to `pipeline_events` for: start, success, error, retry, correlation ids
- Health checks in `ops/healthchecks/` + `scripts/check-health.mjs`
- Telegram/Slack alerts on flow errors, stalled tasks, provider outages

---

## Security & compliance

- DB roles separated for read/write/migrations
- PII retention policy; anonymize PII in logs and fixtures
- Strict Double‑Opt‑In and explicit consent storage for newsletters
- No secrets in commits; restrict access to production data

---

## Contributing

1. Create a feature branch `feature/<slug>`.
2. Keep PRs small and atomic; include migration notes if schema changes.
3. Update docs when structure/rules change.
4. Ensure CI is green (tests, lint, flow validation).

See **AGENTS.md** for additional rules followed by automation agents.

---

## Roadmap (high level)

- Inbox IMAP ingestion & conversation threading (Message‑ID dedup)
- Newsletter: full DOI flow & unsubscribe endpoints
- HR intake pipeline & talent pool
- Sequencer v1.0: segments, additional steps, stop conditions, quiet hours
- Partner docs (NDA, agreements) & signing workflows
- Content digests (RSS/API) → automated newsletters

---

## License

Specify your license (e.g., MIT) in `LICENSE`.

---

## Acknowledgements

- n8n — the workflow engine
- PostgreSQL — the source of truth
- And all contributors who keep flows small, idempotent, and observable.
