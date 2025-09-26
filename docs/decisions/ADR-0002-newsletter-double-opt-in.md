# ADR-0002: Extend newsletter storage for Double Opt-In flows

## Status
Accepted

## Context
Case 1.3 requires Double Opt-In, unsubscribe tokens and digest scheduling. The initial schema only stored `status` and timestamps, so flows could not persist unsubscribe tokens, consent versions or send-only windows. `pipeline_events` also rejected `subscriber` entity types.

## Decision
* Extend the `subscriber_status` enum with `pending_opt_in`.
* Add `unsubscribe_token`, `consent_version`, `dedupe_key`, `double_opt_in_required`, `confirmed_at`, `last_sent_at` and `metadata` to `newsletter_subscribers` with supporting indexes and backfill.
* Allow `pipeline_events.entity_type = 'subscriber'` for logging DOI, welcome, digest and unsubscribe events.

## Consequences
* The n8n flows can store DOI state, deduplicate submissions and track send cadence.
* Existing rows receive generated tokens and confirmation timestamps automatically; no manual migration needed.
* Observability for newsletter actions now lives in the shared `pipeline_events` log alongside lead/candidate events.
