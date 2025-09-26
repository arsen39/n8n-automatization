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

INSERT INTO templates (name, channel, subject_template, body_template) VALUES
  ('newsletter.doi.ru', 'email', 'Подтвердите подписку на рассылку', 'Привет{{full_name_suffix}}!

Чтобы завершить подписку, перейдите по ссылке: {{confirm_url}}

Если вы не оставляли заявку, просто проигнорируйте письмо.'),
  ('newsletter.doi.en', 'email', 'Please confirm your newsletter subscription', 'Hi{{full_name_suffix}}!

Please confirm your subscription by clicking: {{confirm_url}}

If you didn''t request this email, you can ignore it.'),
  ('newsletter.doi.pl', 'email', 'Potwierdź subskrypcję newslettera', 'Cześć{{full_name_suffix}}!

Potwierdź subskrypcję klikając: {{confirm_url}}

Jeśli to nie Ty, zignoruj tę wiadomość.'),
  ('newsletter.welcome.ru', 'email', 'Добро пожаловать в наш дайджест', 'Привет{{full_name_suffix}}!

Спасибо за подписку. Управлять настройками можно по ссылке {{preferences_url}}.
Если хотите отписаться, перейдите по {{unsubscribe_url}}.'),
  ('newsletter.welcome.en', 'email', 'Welcome to our newsletter', 'Hi{{full_name_suffix}}!

Thanks for subscribing. Manage your preferences here: {{preferences_url}}.
To unsubscribe use {{unsubscribe_url}}.'),
  ('newsletter.welcome.pl', 'email', 'Witamy w naszym newsletterze', 'Cześć{{full_name_suffix}}!

Dziękujemy za subskrypcję. Zarządzaj ustawieniami: {{preferences_url}}.
Aby się wypisać kliknij {{unsubscribe_url}}.'),
  ('newsletter.confirmed.ru', 'email', 'Подтверждение подписки', 'Подписка подтверждена{{full_name_suffix}}!
Управлять настройками: {{preferences_url}}.
Если хотите отписаться, используйте {{unsubscribe_url}}.'),
  ('newsletter.confirmed.en', 'email', 'Subscription confirmed', 'Subscription confirmed{{full_name_suffix}}!
Manage preferences: {{preferences_url}}.
To unsubscribe use {{unsubscribe_url}}.'),
  ('newsletter.confirmed.pl', 'email', 'Potwierdzenie subskrypcji', 'Subskrypcja potwierdzona{{full_name_suffix}}!
Zarządzaj ustawieniami: {{preferences_url}}.
Aby się wypisać użyj {{unsubscribe_url}}.'),
  ('newsletter.unsubscribed.ru', 'email', 'Вы отписаны от рассылки', 'Вы успешно отписались{{full_name_suffix}}.
Если это было ошибкой, подпишитесь снова: {{resubscribe_url}}.'),
  ('newsletter.unsubscribed.en', 'email', 'You have been unsubscribed', 'You have been unsubscribed{{full_name_suffix}}.
If this was a mistake you can subscribe again here: {{resubscribe_url}}.'),
  ('newsletter.unsubscribed.pl', 'email', 'Zostałeś wypisany z newslettera', 'Zostałeś wypisany{{full_name_suffix}}.
Jeśli to pomyłka, zapisz się ponownie: {{resubscribe_url}}.'),
  ('newsletter.digest.ru', 'email', '[Дайджест] {{generated_date}}', '{{greeting_line}}

{{items_block}}

Управлять подпиской: {{unsubscribe_url}}'),
  ('newsletter.digest.en', 'email', '[Digest] {{generated_date}}', '{{greeting_line}}

{{items_block}}

Manage your subscription: {{unsubscribe_url}}'),
  ('newsletter.digest.pl', 'email', '[Newsletter] {{generated_date}}', '{{greeting_line}}

{{items_block}}

Zarządzaj subskrypcją: {{unsubscribe_url}}')
ON CONFLICT (name) DO NOTHING;

