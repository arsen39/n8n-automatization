-- Newsletter enhancements for Double Opt-In, digests and unsubscribe flow
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_type t
    JOIN pg_enum e ON t.oid = e.enumtypid
    WHERE t.typname = 'subscriber_status' AND e.enumlabel = 'pending_opt_in'
  ) THEN
    ALTER TYPE subscriber_status ADD VALUE 'pending_opt_in';
  END IF;
END
$$;

ALTER TABLE newsletter_subscribers
  ADD COLUMN IF NOT EXISTS unsubscribe_token TEXT,
  ADD COLUMN IF NOT EXISTS consent_version TEXT,
  ADD COLUMN IF NOT EXISTS dedupe_key TEXT,
  ADD COLUMN IF NOT EXISTS double_opt_in_required BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS confirmed_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_sent_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS metadata JSONB NOT NULL DEFAULT '{}'::jsonb;

-- Ensure existing rows have basic values
UPDATE newsletter_subscribers
SET
  unsubscribe_token = COALESCE(unsubscribe_token, gen_random_uuid()::text),
  consent_version = COALESCE(consent_version, 'v1'),
  dedupe_key = COALESCE(dedupe_key, md5(COALESCE(contact_id::text, '') || ':' || COALESCE(source_id::text, ''))),
  confirmed_at = COALESCE(confirmed_at, CASE WHEN status = 'subscribed' THEN NOW() ELSE confirmed_at END),
  double_opt_in_required = COALESCE(double_opt_in_required, FALSE)
WHERE unsubscribe_token IS NULL
   OR consent_version IS NULL
   OR dedupe_key IS NULL
   OR confirmed_at IS NULL
   OR double_opt_in_required IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS ux_newsletter_subscribers_token ON newsletter_subscribers(unsubscribe_token);
CREATE UNIQUE INDEX IF NOT EXISTS ux_newsletter_subscribers_dedupe ON newsletter_subscribers(dedupe_key) WHERE dedupe_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_newsletter_subscribers_status ON newsletter_subscribers(status, confirmed_at, unsubscribed_at);

ALTER TABLE pipeline_events DROP CONSTRAINT IF EXISTS pipeline_events_entity_type_check;
ALTER TABLE pipeline_events
  ADD CONSTRAINT pipeline_events_entity_type_check
  CHECK (entity_type IN ('lead','candidate','partner','subscriber'));
