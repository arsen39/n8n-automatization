-- n8n automation full schema (PostgreSQL)
-- Author: ChatGPT (Lea) + Сеня's improvements
-- Created: 2025-09-22
-- Safe to re-run (idempotent). Ordered to satisfy all FK dependencies.

BEGIN;

DROP SCHEMA public CASCADE;

CREATE SCHEMA public;

-- ========================================================
-- Extensions
-- ========================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;    -- for gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS "uuid-ossp"; -- optional uuid_generate_v4()


-- ========================================================
-- Enums
-- ========================================================
DO $$ BEGIN
    CREATE TYPE form_type AS ENUM ('development_request','vacancy_application','newsletter_signup','partner_outreach','generic');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE lead_type AS ENUM ('client','candidate','partner','newsletter');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE lead_stage AS ENUM (
        'new','contacted','nurturing','qualified','disqualified',
        'scheduled_call','sent_nda','nda_signed','kyc_paid','in_pool','won','lost','archived'
    );
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE channel AS ENUM ('email','form','telegram','slack','webhook','phone','other');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE direction AS ENUM ('inbound','outbound','system');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE doc_type AS ENUM ('nda','partner_agreement','estimate_request','proposal','other');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE doc_provider AS ENUM ('chaindoc','docusign','manual','other');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE doc_status AS ENUM ('draft','sent','viewed','signed','rejected','expired');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE booking_status AS ENUM ('scheduled','rescheduled','canceled','attended','no_show');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE subscriber_status AS ENUM ('subscribed','unsubscribed');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE availability AS ENUM ('available_now','part_time','notice_period','unavailable');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE classification_label AS ENUM ('spam','ham','client','partner','vacancy','newsletter');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

DO $$ BEGIN
    CREATE TYPE rate_period AS ENUM ('hourly','daily','monthly');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;


-- ========================================================
-- Triggers: auto-update updated_at on UPDATE
-- ========================================================
CREATE OR REPLACE FUNCTION trigger_set_timestamp()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;


-- ========================================================
-- Core reference & master entities (no outbound FKs first)
-- ========================================================

-- Users
CREATE TABLE IF NOT EXISTS users (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name TEXT NOT NULL,
    email TEXT UNIQUE,
    role TEXT CHECK (role IN ('agent','admin','viewer')) DEFAULT 'agent',
    telegram_username TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS set_timestamp ON users;
CREATE TRIGGER set_timestamp BEFORE UPDATE ON users
FOR EACH ROW EXECUTE FUNCTION trigger_set_timestamp();

-- Sources
CREATE TABLE IF NOT EXISTS sources (
    id SERIAL PRIMARY KEY,
    code TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    description TEXT
);

-- Companies
CREATE TABLE IF NOT EXISTS companies (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    website TEXT,
    country TEXT,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS set_timestamp ON companies;
CREATE TRIGGER set_timestamp BEFORE UPDATE ON companies
FOR EACH ROW EXECUTE FUNCTION trigger_set_timestamp();

CREATE UNIQUE INDEX IF NOT EXISTS companies_website_unique_not_null
ON companies (website)
WHERE website IS NOT NULL;

-- Contacts (depends on companies)
CREATE TABLE IF NOT EXISTS contacts (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID REFERENCES companies(id) ON DELETE SET NULL,
    full_name TEXT,
    email TEXT,
    phone TEXT,
    title TEXT,
    timezone TEXT,
    preferred_lang TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_contacts_company ON contacts(company_id);
DROP TRIGGER IF EXISTS set_timestamp ON contacts;
CREATE TRIGGER set_timestamp BEFORE UPDATE ON contacts
FOR EACH ROW EXECUTE FUNCTION trigger_set_timestamp();

-- Optional multi-email / multi-phone (depend on contacts)
CREATE TABLE IF NOT EXISTS contact_emails (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    contact_id UUID NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
    email TEXT NOT NULL,
    label TEXT,             -- e.g., work, personal, billing
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_contact_emails_primary_per_contact
    ON contact_emails (contact_id) WHERE is_primary = TRUE;
CREATE UNIQUE INDEX IF NOT EXISTS ux_contact_emails_contact_email_ci
    ON contact_emails (contact_id, lower(email));
DROP TRIGGER IF EXISTS set_timestamp ON contact_emails;
CREATE TRIGGER set_timestamp BEFORE UPDATE ON contact_emails
FOR EACH ROW EXECUTE FUNCTION trigger_set_timestamp();

CREATE TABLE IF NOT EXISTS contact_phones (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    contact_id UUID NOT NULL REFERENCES contacts(id) ON DELETE CASCADE,
    phone TEXT NOT NULL,
    label TEXT,             -- e.g., mobile, office, telegram
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS ux_contact_phones_primary_per_contact
    ON contact_phones (contact_id) WHERE is_primary = TRUE;
CREATE UNIQUE INDEX IF NOT EXISTS ux_contact_phones_contact_phone
    ON contact_phones (contact_id, phone);
DROP TRIGGER IF EXISTS set_timestamp ON contact_phones;
CREATE TRIGGER set_timestamp BEFORE UPDATE ON contact_phones
FOR EACH ROW EXECUTE FUNCTION trigger_set_timestamp();

-- Forms (referenced by submissions later)
CREATE TABLE IF NOT EXISTS forms (
    id SERIAL PRIMARY KEY,
    code TEXT UNIQUE NOT NULL,
    name TEXT NOT NULL,
    type form_type NOT NULL,
    active BOOLEAN NOT NULL DEFAULT TRUE
);

-- Leads (depends on contacts, companies, users, sources)
CREATE TABLE IF NOT EXISTS leads (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    contact_id UUID REFERENCES contacts(id) ON DELETE SET NULL,
    company_id UUID REFERENCES companies(id) ON DELETE SET NULL,
    type lead_type NOT NULL,
    stage lead_stage NOT NULL DEFAULT 'new',
    owner_user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    source_id INTEGER REFERENCES sources(id) ON DELETE SET NULL,
    score INTEGER,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    dedupe_key TEXT UNIQUE -- for upserts from n8n
);
CREATE INDEX IF NOT EXISTS idx_leads_stage ON leads(stage);
CREATE INDEX IF NOT EXISTS idx_leads_owner ON leads(owner_user_id);
DROP TRIGGER IF EXISTS set_timestamp ON leads;
CREATE TRIGGER set_timestamp BEFORE UPDATE ON leads
FOR EACH ROW EXECUTE FUNCTION trigger_set_timestamp();


-- ========================================================
-- Dependent tables (reference the masters above)
-- ========================================================

-- Submissions (depends on forms, sources, leads)
CREATE TABLE IF NOT EXISTS submissions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    form_id INTEGER REFERENCES forms(id) ON DELETE SET NULL,
    source_id INTEGER REFERENCES sources(id) ON DELETE SET NULL,
    resource TEXT, -- which site/app (e.g., chain.do, main site)
    received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    raw_payload JSONB NOT NULL,
    email TEXT,
    full_name TEXT,
    message TEXT,
    external_id TEXT UNIQUE,  -- idempotency key from webhook/email
    spam_score NUMERIC(5,2),
    is_spam BOOLEAN,
    spam_reason TEXT,
    status TEXT CHECK (status IN ('new','triaged','enriching','scheduled','converted','archived')) DEFAULT 'new',
    lead_id UUID REFERENCES leads(id) ON DELETE SET NULL
);

-- Conversations & messages (depend on leads/contacts)
CREATE TABLE IF NOT EXISTS conversations (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lead_id UUID REFERENCES leads(id) ON DELETE CASCADE,
    channel channel NOT NULL,
    subject TEXT,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_message_at TIMESTAMPTZ
);
CREATE INDEX IF NOT EXISTS idx_conversations_lead ON conversations(lead_id);

CREATE TABLE IF NOT EXISTS messages (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    conversation_id UUID REFERENCES conversations(id) ON DELETE CASCADE,
    direction direction NOT NULL,
    medium channel NOT NULL,
    sender_contact_id UUID REFERENCES contacts(id) ON DELETE SET NULL,
    body TEXT,
    body_html TEXT,
    message_ts TIMESTAMPTZ NOT NULL DEFAULT now(),
    external_message_id TEXT UNIQUE,
    meta JSONB
);
CREATE INDEX IF NOT EXISTS idx_messages_conv_ts ON messages(conversation_id, message_ts);

-- Attachments (depends on messages)
CREATE TABLE IF NOT EXISTS attachments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    message_id UUID REFERENCES messages(id) ON DELETE CASCADE,
    filename TEXT,
    mime TEXT,
    size_bytes BIGINT,
    storage_url TEXT
);

-- Documents (depends on leads)
CREATE TABLE IF NOT EXISTS documents (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lead_id UUID REFERENCES leads(id) ON DELETE CASCADE,
    doc_type doc_type NOT NULL,
    provider doc_provider NOT NULL,
    external_id TEXT UNIQUE,
    status doc_status NOT NULL DEFAULT 'draft',
    link_url TEXT,
    sent_at TIMESTAMPTZ,
    signed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS set_timestamp ON documents;
CREATE TRIGGER set_timestamp BEFORE UPDATE ON documents
FOR EACH ROW EXECUTE FUNCTION trigger_set_timestamp();

-- Bookings (depends on leads)
CREATE TABLE IF NOT EXISTS bookings (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lead_id UUID REFERENCES leads(id) ON DELETE CASCADE,
    calendly_event_id TEXT UNIQUE,
    scheduled_start TIMESTAMPTZ NOT NULL,
    scheduled_end TIMESTAMPTZ,
    timezone TEXT,
    status booking_status NOT NULL DEFAULT 'scheduled',
    url TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS set_timestamp ON bookings;
CREATE TRIGGER set_timestamp BEFORE UPDATE ON bookings
FOR EACH ROW EXECUTE FUNCTION trigger_set_timestamp();

-- Newsletter subscribers (depends on contacts, sources)
CREATE TABLE IF NOT EXISTS newsletter_subscribers (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    contact_id UUID REFERENCES contacts(id) ON DELETE CASCADE,
    source_id INTEGER REFERENCES sources(id) ON DELETE SET NULL,
    subscribed_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    unsubscribed_at TIMESTAMPTZ,
    status subscriber_status NOT NULL DEFAULT 'subscribed',
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (contact_id)
);
DROP TRIGGER IF EXISTS set_timestamp ON newsletter_subscribers;
CREATE TRIGGER set_timestamp BEFORE UPDATE ON newsletter_subscribers
FOR EACH ROW EXECUTE FUNCTION trigger_set_timestamp();

-- Candidate & Partner profiles
CREATE TABLE IF NOT EXISTS candidate_profiles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    contact_id UUID UNIQUE REFERENCES contacts(id) ON DELETE CASCADE,
    cv_url TEXT,
    skills JSONB,
    experience_years NUMERIC(4,1),
    location TEXT,
    rate_currency TEXT,
    rate_min NUMERIC(12,2),
    rate_max NUMERIC(12,2),
    rate_period rate_period NOT NULL DEFAULT 'hourly',
    availability availability DEFAULT 'available_now',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS set_timestamp ON candidate_profiles;
CREATE TRIGGER set_timestamp BEFORE UPDATE ON candidate_profiles
FOR EACH ROW EXECUTE FUNCTION trigger_set_timestamp();

CREATE TABLE IF NOT EXISTS partner_profiles (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    company_id UUID UNIQUE REFERENCES companies(id) ON DELETE CASCADE,
    areas JSONB,         -- e.g., {'fintech': true, 'ai': true}
    tech_stack JSONB,    -- e.g., ['react','node','solidity']
    available_specialists JSONB, -- list or map
    avg_rates JSONB,     -- e.g., {'senior': 60, 'middle': 40}
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS set_timestamp ON partner_profiles;
CREATE TRIGGER set_timestamp BEFORE UPDATE ON partner_profiles
FOR EACH ROW EXECUTE FUNCTION trigger_set_timestamp();

-- Classifications (depends on submissions)
CREATE TABLE IF NOT EXISTS classifications (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    submission_id UUID REFERENCES submissions(id) ON DELETE CASCADE,
    model_name TEXT,
    label classification_label NOT NULL,
    confidence NUMERIC(5,2),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Tasks (depends on leads)
CREATE TABLE IF NOT EXISTS tasks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    lead_id UUID REFERENCES leads(id) ON DELETE CASCADE,
    type TEXT CHECK (type IN ('followup','send_nda','review_estimate','schedule_call','add_to_pool','other')) NOT NULL,
    due_at TIMESTAMPTZ,
    status TEXT CHECK (status IN ('open','done','canceled')) NOT NULL DEFAULT 'open',
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    notes TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    completed_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS set_timestamp ON tasks;
CREATE TRIGGER set_timestamp BEFORE UPDATE ON tasks
FOR EACH ROW EXECUTE FUNCTION trigger_set_timestamp();

-- Webhooks (independent)
CREATE TABLE IF NOT EXISTS webhooks (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    provider TEXT CHECK (provider IN ('n8n','calendly','email','other')) NOT NULL,
    external_id TEXT UNIQUE,
    secret_hash TEXT,
    last_seen_at TIMESTAMPTZ,
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS set_timestamp ON webhooks;
CREATE TRIGGER set_timestamp BEFORE UPDATE ON webhooks
FOR EACH ROW EXECUTE FUNCTION trigger_set_timestamp();

-- Tags and linking (lead_tags depends on leads & tags)
CREATE TABLE IF NOT EXISTS tags (
    id SERIAL PRIMARY KEY,
    name TEXT UNIQUE NOT NULL
);
CREATE TABLE IF NOT EXISTS lead_tags (
    lead_id UUID REFERENCES leads(id) ON DELETE CASCADE,
    tag_id INTEGER REFERENCES tags(id) ON DELETE CASCADE,
    PRIMARY KEY (lead_id, tag_id)
);

-- Pools & membership (candidate_pool_members depends on pools & candidate_profiles)
CREATE TABLE IF NOT EXISTS pools (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT UNIQUE NOT NULL,
    description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS set_timestamp ON pools;
CREATE TRIGGER set_timestamp BEFORE UPDATE ON pools
FOR EACH ROW EXECUTE FUNCTION trigger_set_timestamp();

CREATE TABLE IF NOT EXISTS candidate_pool_members (
    pool_id UUID REFERENCES pools(id) ON DELETE CASCADE,
    candidate_profile_id UUID REFERENCES candidate_profiles(id) ON DELETE CASCADE,
    status TEXT CHECK (status IN ('prospect','active','archived')) NOT NULL DEFAULT 'prospect',
    added_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (pool_id, candidate_profile_id)
);

-- Outreach (campaigns, templates, steps)
CREATE TABLE IF NOT EXISTS outreach_campaigns (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    type TEXT CHECK (type IN ('partner','fake_client','hr','newsletter')) NOT NULL,
    status TEXT CHECK (status IN ('draft','active','paused','completed')) NOT NULL DEFAULT 'draft',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS set_timestamp ON outreach_campaigns;
CREATE TRIGGER set_timestamp BEFORE UPDATE ON outreach_campaigns
FOR EACH ROW EXECUTE FUNCTION trigger_set_timestamp();

CREATE TABLE IF NOT EXISTS templates (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT UNIQUE NOT NULL,
    channel channel NOT NULL DEFAULT 'email',
    subject_template TEXT,
    body_template TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
DROP TRIGGER IF EXISTS set_timestamp ON templates;
CREATE TRIGGER set_timestamp BEFORE UPDATE ON templates
FOR EACH ROW EXECUTE FUNCTION trigger_set_timestamp();

CREATE TABLE IF NOT EXISTS campaign_steps (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    campaign_id UUID REFERENCES outreach_campaigns(id) ON DELETE CASCADE,
    step_no INTEGER NOT NULL,
    template_id UUID REFERENCES templates(id) ON DELETE SET NULL,
    wait_days INTEGER NOT NULL DEFAULT 0,
    channel channel NOT NULL DEFAULT 'email',
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    UNIQUE (campaign_id, step_no)
);
DROP TRIGGER IF EXISTS set_timestamp ON campaign_steps;
CREATE TRIGGER set_timestamp BEFORE UPDATE ON campaign_steps
FOR EACH ROW EXECUTE FUNCTION trigger_set_timestamp();

-- Pipeline event log (independent)
CREATE TABLE IF NOT EXISTS pipeline_events (
    id BIGSERIAL PRIMARY KEY,
    entity_type TEXT CHECK (entity_type IN ('lead','candidate','partner')) NOT NULL,
    entity_id UUID NOT NULL,
    event_type TEXT NOT NULL,
    data JSONB,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT now()
);


-- ========================================================
-- Indexes
-- ========================================================
CREATE INDEX IF NOT EXISTS idx_submissions_payload_gin ON submissions USING gin (raw_payload);
CREATE INDEX IF NOT EXISTS idx_messages_meta_gin ON messages USING gin (meta);
CREATE INDEX IF NOT EXISTS idx_pipeline_events_entity ON pipeline_events(entity_type, entity_id, occurred_at);


-- ========================================================
-- Views
-- ========================================================
CREATE OR REPLACE VIEW view_inbound_inbox AS
SELECT s.id as submission_id, s.received_at, s.email, s.full_name, s.message, s.is_spam, c.label as ai_label
FROM submissions s
LEFT JOIN LATERAL (
    SELECT label FROM classifications cl
    WHERE cl.submission_id = s.id
    ORDER BY cl.created_at DESC
    LIMIT 1
) c ON TRUE
WHERE COALESCE(s.is_spam, FALSE) = FALSE
ORDER BY s.received_at DESC;

CREATE OR REPLACE VIEW view_contacts_primary AS
SELECT
  c.id AS contact_id,
  COALESCE(
    (SELECT e.email FROM contact_emails e WHERE e.contact_id=c.id AND e.is_primary ORDER BY e.updated_at DESC NULLS LAST LIMIT 1),
    c.email
  ) AS primary_email,
  COALESCE(
    (SELECT p.phone FROM contact_phones p WHERE p.contact_id=c.id AND p.is_primary ORDER BY p.updated_at DESC NULLS LAST LIMIT 1),
    c.phone
  ) AS primary_phone
FROM contacts c;


-- ========================================================
-- Seeds (idempotent via UNIQUE constraints)
-- ========================================================
INSERT INTO sources (code, name) VALUES
    ('chain_do','Chain.do site'),
    ('main_site','Main company site'),
    ('email_inbox','Email inbox')
ON CONFLICT (code) DO NOTHING;

INSERT INTO forms (code, name, type) VALUES
    ('dev_request','Development / Consulting Request','development_request'),
    ('vacancy','Vacancy Application','vacancy_application'),
    ('newsletter','Newsletter Signup','newsletter_signup')
ON CONFLICT (code) DO NOTHING;

INSERT INTO templates (name, channel, subject_template, body_template) VALUES
('Partner outreach: initial', 'email', 'Exploring partnership opportunities',
'Hi {{name}},

We''re expanding our partner network and think there could be a great fit.

{{body}}'),
('Partner outreach: followup 1', 'email', 'Following up on partnership',
'Hi {{name}},

Just checking in on my previous note—happy to share a short deck or jump on a call.')
ON CONFLICT (name) DO NOTHING;

INSERT INTO templates (name, channel, subject_template, body_template) VALUES
('dev_request.initial.en','email','Thanks for reaching out — 15‑min intro call?','Hi {{name}},\n\nThanks for your request! To estimate properly, please share:\n• goal/product;\n• key features (MVP);\n• timeline/priority;\n• budget range (PLN/EUR/USD).\n\nYou can pick a slot right away: {{calendly_url}}\n\nAlternatively, just reply here — we''ll adapt.\n— {{from_name}}'),
('dev_request.followup1.en','email','Quick reminder to book a 15‑min intro','Hi {{name}},\n\nJust a gentle nudge. You can grab a slot here: {{calendly_url}}\n\nPrefer async? Send a brief and we''ll start an estimate.\n— {{from_name}}'),
('dev_request.followup2.en','email','Still up for a quick intro?','Hi {{name}},\n\nLooks like there''s no slot yet. If relevant, pick any time: {{calendly_url}}\n\nOr reply with a brief — we''ll proceed async.\n— {{from_name}}')
ON CONFLICT (name) DO NOTHING;

INSERT INTO tags (name) VALUES
('followup_1_sent'),
('followup_2_sent')
ON CONFLICT (name) DO NOTHING;

COMMIT;
