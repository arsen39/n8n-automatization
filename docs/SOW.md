
# ТЗ: Автоматизация процессов компании на n8n (Idealogic / Chain.do)

Версия: **0.1**  
Дата: **2025‑09‑22**  
Ответственная за подготовку: **Лея**  
Цель документа: дать полный, атомарный, пошаговый план внедрения автоматизаций на n8n с привязкой к существующей БД (PostgreSQL), веб‑хукам форм, email‑инбоксу, подписанию документов (Chaindoc/DocuSign), переводу (DeepL), «humanizer» и Calendly. Документ структурирован так, чтобы по нему можно было сразу выполнять работу итерациями, без дополнительных разъяснений.

---

## 0) Резюме (TL;DR)

Мы строим **единый входящий конвейер** (forms + email), **AI‑классификатор** (спам/не спам + тип намерения), **моментальную человеческоподобную коммуникацию** (темп, задержки, «humanizer», DeepL), автосоздание **лидов/контактов/компаний** в нашей БД, **букинг звонков** (Calendly), **юридические документы** (NDA/партнёрка через Chaindoc/DocuSign), **медленный nurture‑флоу** для вакансий (2–3 недели), **управление рассылкой** для подписчиков, а также **аутрич‑кампании** (партнёрка, «fake‑client» для получения оценок).

---

## 1) Область работ (Scope) и цели

### 1.1. Что автоматизируем сейчас

- Обработка 3 типов форм сайта: **dev_request**, **vacancy**, **newsletter**.
    
- Подключение **email‑инбокса** в общий входящий конвейер.
    
- **AI‑классификация** входящих (spam/ham + client/partner/vacancy + intent).
    
- **Быстрый диалог с клиентом**: подтверждение, уточняющие вопросы, линк на букинг.
    
- **Документы**: отправка NDA/партнёрских договоров и трекинг статусов.
    
- **HR флоу**: заявка → NDA → отбор → профиль кандидата → пул.
    
- **Newsletter**: подписка, double‑opt‑in (опционально), привет, дайджест.
    
- **Аутрич кампании**: партнёрка (3 шага), «fake‑client» (запросы оценок).
    
- **Оповещения команды**: Telegram/Slack.
    
- **База**: запись всего в PostgreSQL по согласованной схеме.
    

### 1.2. Что не в скопе первой итерации

- Платёжные флоу beyond KYC‑инвойса (кроме сигнала «kyc_paid»).
    
- Полноценный helpdesk/тикетинг (только задачи «tasks»).
    
- Сложная аналитика (только базовые отчёты и pipeline_events).
    

### 1.3. Цели качества

- **Idempotency** всех входящих (dedupe_key/external_id).
    
- **Human‑like** коммуникация: задержки, время суток, стиль.
    
- **Прозрачность**: логирование pipeline_events, алерты при ошибках.
    
- **Минимум ручного труда** на рутине, но ручной override всегда доступен.
    

---

## 2) Архитектура решения

### 2.1. Компоненты

- **n8n**: основной оркестратор воркфлоу.
    
- **PostgreSQL**: БД по предоставленной схеме (см. раздел 3).
    
- **Email (IMAP/SMTP)**: входящие/исходящие.
    
- **Web‑формы** (Chain.do и/или другие сайты): прием через Webhook.
    
- **Calendly**: букинг звонков и вебхуки статусов.
    
- **Chaindoc/DocuSign**: NDA и партнёрские соглашения.
    
- **DeepL**: перевод.
    
- **Humanizer**: варьирование стиля/ритмики писем.
    
- **Telegram/Slack**: алерты и уведомления менеджерам.
    
- **LLM провайдер**: классификация и генерация/редактирование писем.
    

### 2.2. Потоки данных (высокоуровнево)

1. **Inbound**: Form/Webhook/Email → n8n → Submissions → AI‑label → (спам? → архив : нет → создание/обновление Contacts/Companies → Lead → Conversation/Message → автокоммуникация → задачи/букинг/документы).
    
2. **Outbound**: Campaigns/Templates → Email/Telegram → ответы → Messages/Conversations → Lead/Tasks.
    
3. **Документы**: Lead → create Document (Chaindoc/DocuSign) → status вебхуком → update documents/lead stage → нотификации.
    
4. **Букинги**: Lead → Calendly URL → вебхук статуса → Bookings → нотификации.
    

### 2.3. Безопасность и секреты

- Секреты в n8n Credentials.
    
- IP allow‑list для вебхуков (по возможности).
    
- Подписи вебхуков (Calendly/Chaindoc/DocuSign).
    
- PII: шифрование в покое (PostgreSQL at‑rest) и audit (pipeline_events).
    

---

## 3) База данных: факты и важные решения

### 3.1. Ядро схемы

- Справочники: **sources**, **forms**.
    
- Главные сущности: **contacts**, **companies**, **leads** (+ stages/types/owners).
    
- Входящие: **submissions**, **conversations/messages**, **attachments**.
    
- Процессы: **documents**, **bookings**, **tasks**.
    
- HR/Partners: **candidate_profiles**, **partner_profiles**, **pools**, **candidate_pool_members**.
    
- Кампании: **outreach_campaigns**, **templates**, **campaign_steps**.
    
- Классификация: **classifications**.
    
- Служебное: **pipeline_events**, **webhooks**, **tags/lead_tags**.
    

### 3.2. Ключевые поля для идемпотентности

- **submissions.external_id** (из вебхуков/инбокса),
    
- **documents.external_id**, **bookings.calendly_event_id**,
    
- **leads.dedupe_key** (e‑mail+resource+дата и т.д.).
    

### 3.3. Жизненный цикл лида (стадии)

- `new → contacted → nurturing → qualified → scheduled_call → sent_nda → nda_signed → kyc_paid → in_pool → won/lost/archived` (используем строго эти значения для отчётности).
    

### 3.4. Вьюшки

- **view_inbound_inbox** — удобный инбокс без спама, с последней AI‑меткой.
    
- **view_contacts_primary** — вычисление первичных email/телефона.
    

_(Примечание: в Приложении A — полезные SQL для отладки и QA.)_

---

## 4) Соглашения по именованию и структуре воркфлоу n8n

- **Префикс** по домену: `crm.`, `hr.`, `mkt.`, `ops.`
    
- **Триггеры**: `*.in.*` (webhook/imap), **обработчики**: `*.proc.*`, **аутрич**: `mkt.camp.*`, **юридические**: `ops.doc.*`, **сервисные**: `ops.util.*`.
    
- Одна ответственная точка записи в БД на этап (Function → Postgres Node).
    
- В каждом воркфлоу: блок **Error‑handler** → Telegram алерт + запись в pipeline_events.
    
- **Rate‑limit и Wait** обязательны перед исходящей массовой рассылкой.
    

---

## 5) Сквозные политики

- **Языки**: автоопределение → DeepL при необходимости → шаблон нужной локали.
    
- **Humanizer**: рандомизация задержек (5–90 сек), вариативность приветствий/подписей, окна отправки (рабочие часы адресата по timezone).
    
- **Классификация**: модель возвращает `{label: spam|ham, intent: client|partner|vacancy|newsletter, confidence}`.
    
- **Нотификации**: все значимые события → Telegram канал `#sales_ops` и/или Direct ответственному.
    
- **GDPR**: быстрый `unsubscribe`/`delete` по ключу в письме; запись в `newsletter_subscribers`/`tags`.
    

---

## 6) Спецификация потоков (node‑by‑node скелеты + критерии приёмки)

### 6.A) Универсальный входящий конвейер (Forms/Webhooks)

**Workflow:** `crm.in.forms`  
**Trigger:** `Webhook` (по формам `dev_request`, `vacancy`, `newsletter`), заголовок `X-Resource` + `X-Form-Code`.

**Steps:**

1. **Validate & Normalize** (Function): валидация схемы, маппинг в `{form_code, resource, email, full_name, message, payload, external_id}`.
    
2. **Insert Submission** (Postgres): запись в `submissions` (id возвращаем в контекст).
    
3. **AI Classify** (HTTP→LLM): `{text: message+payload, channel: form}` → `classifications` insert.
    
4. **Spam Branch** (IF): если spam→update `submissions.is_spam=true; status='triaged'` → `pipeline_events` → END.
    
5. **Upsert Contact/Company** (Postgres): по email → `contacts` и при необходимости `companies`.
    
6. **Upsert Lead** (Postgres): тип из intent → `leads` (stage=`new`, owner по правилам роутинга).
    
7. **Start Conversation** (Postgres): `conversations` + первичное `messages` (direction=inbound/system, medium=webhook).
    
8. **Next hop** (Switch by `form_code`): → 6.B/6.C/6.D.
    

**Acceptance:**

- 100% валидных форм видны в `view_inbound_inbox` без задержки > 2 мин.
    
- Спам не создает лидов/контактов.
    
- Дубли по `external_id` не заводят повторные записи.
    

**Tests:** позитивы/негативы, пустые поля, дубликаты, массовая подача.

---

### 6.B) Клиентская заявка (Development/Consulting)

**Workflow:** `crm.proc.dev_request`

**Trigger:** `crm.in.forms` → маршрут `dev_request` **или** `crm.in.email` (см. 6.E) с intent=`client`.

**Steps:**

1. **Initial Reply Composer**: шаблон «приняли заявку» + уточняющие вопросы (если мало данных) + **Calendly URL**.
    
2. **Humanize & Translate**: через Humanizer/DeepL → финальный текст.
    
3. **Send Email** (SMTP): через `templates` или прямой body; запись `messages` (outbound, medium=email).
    
4. **Create Task**: `tasks(type='schedule_call', due_at=+24h)`.
    
5. **Telegram Notify**: кто ответственный + краткий summary + ссылка на лид.
    
6. **If Calendly Booked** (webhook → 6.F): создать `bookings`, обновить стадию → `scheduled_call`.
    
7. **Send NDA** (6.G): после букинга или по правилу (можно до звонка) → `documents`.
    
8. **Follow‑ups**: если нет букинга 24/72 ч → мягкие напоминания (2 касания, humanized, окна времени).
    

**Acceptance:**

- Каждому валидному клиентскому инпуту уходит **1‑е письмо ≤15 мин** (с учётом humanized задержек).
    
- Запланированный звонок автоматически создаёт запись в `bookings` и нотификацию.
    
- NDA отправляется и трекается в `documents`.
    

**Tests:** короткая/длинная заявка, нет email, неверный email, no‑show, отмена.

---

### 6.C) Вакансия (HR)

**Workflow:** `hr.proc.vacancy`

**Trigger:** `crm.in.forms` с `form_code='vacancy'` или email intent=`vacancy`.

**Steps:**

1. **NDA**: сразу отправить ссылку на NDA (Chaindoc) + мягкое вступление.
    
2. **Wait Windows**: nurture в **2–3 недели** (1–2 касания в неделю): сбор CV/портфолио/ставки/локации.
    
3. **Candidate Profile Upsert**: заполнить `candidate_profiles` (skills JSON, rate_min/max, availability).
    
4. **Pools**: добавить в соответствующий пул (напр. `React Senior`, `Solidity Middle`).
    
5. **Tasks**: для живых кандидатов `review_estimate`/`add_to_pool`.
    

**Acceptance:**

- По каждой заявке создан `candidate_profile` (если NDA подписан), иначе 2 напоминания и архив.
    
- Контакт добавлен в пул или обоснованно `archived`.
    

**Tests:** нет/есть CV, отказ от NDA, медленный ответ, разные валюты/ставки.

---

### 6.D) Newsletter подписка

**Workflow:** `mkt.proc.newsletter`

**Trigger:** `crm.in.forms` с `form_code='newsletter'`.

**Steps:**

1. **Upsert Contact** и `newsletter_subscribers(status='subscribed')`.
    
2. (Опционально) **Double Opt‑in** письмо.
    
3. **Welcome** письмо + настройки частоты.
    
4. **Content Digest** (см. 6.H): периодический дайджест новых статей с Chain.do.
    

**Acceptance:**

- Подписчик в БД, welcome/opt‑in ушло, unsubscribe работает (меняет статус и `unsubscribed_at`).
    

---

### 6.E) Инбокс Email (IMAP)

**Workflow:** `crm.in.email`

**Trigger:** `IMAP Email` → парсинг From/To/Subject/Body/Attachments.

**Steps:**

1. **Deduplicate** по `Message‑ID` → `submissions.external_id`.
    
2. **Classify** (LLM) → spam/intent; записи в `classifications`.
    
3. **Create/Link Conversation**: маппинг по адресу; запись `messages` (inbound, medium=email).
    
4. **Route by Intent**: → 6.B/6.C/6.D/6.I.
    

**Acceptance:**

- Сохранение каждого входящего письма и вложений; отсутствие дублей; корректная маршрутизация.
    

---

### 6.F) Букинги (Calendly)

**Workflow:** `ops.in.calendly`

**Trigger:** `Webhook` от Calendly (scheduled/rescheduled/canceled/attended/no_show).

**Steps:**

1. **Upsert Booking**: по `calendly_event_id`.
    
2. **Update Lead Stage**: `scheduled_call` → `attended`/`no_show`.
    
3. **Notify**: Telegram менеджеру с временем и ссылкой.
    

**Acceptance:**

- Любое изменение в Calendly синхронизируется ≤1 мин, стадия лида актуальна.
    

---

### 6.G) Документы (NDA/Partner Agreement)

**Workflow:** `ops.doc.sender`

**Inputs:** lead_id, doc_type(`nda`/`partner_agreement`), provider(`chaindoc`/`docusign`).

**Steps:**

1. **Prepare Payload**: имена/компания/email/шаблон.
    
2. **HTTP Send**: создать документ, сохранить `documents.external_id`, `status='sent'`, `sent_at`.
    
3. **Webhook Receiver** `ops.in.docs`: `status= viewed/signed/rejected/expired` → апдейт `documents` и стадий лида (`sent_nda`→`nda_signed`).
    
4. **Notify**: Telegram.
    

**Acceptance:**

- Любой документ имеет трассировку статусов в `documents`; подписание апдейтит лид.
    

---

### 6.H) Контент‑дайджест (RSS/JSON API Chain.do)

**Workflow:** `mkt.proc.digest`

**Trigger:** `Cron` (еженедельно).

**Steps:**

1. **Fetch New Posts** (HTTP) → фильтр по дате.
    
2. **Compose Email** (multi‑lang) → Humanizer/DeepL.
    
3. **Send** подписчикам пачками (rate‑limit).
    

**Acceptance:**

- Письмо с 3–7 материалами уходит подписчикам; отписка работает.
    

---

### 6.I) Партнёрский аутрич (3‑шаговая кампания)

**Workflow:** `mkt.camp.partners`

**Steps:**

1. **Campaign & Steps**: заводим кампанию `type='partner'` и шаги: Initial → FollowUp1 (3–4 дня) → FollowUp2 (5–7 дней).
    
2. **Templates**: импортируем шаблоны писем; персонализация по компании и стэку.
    
3. **Sequencer**: отправка по шагам с трекингом ответов (reply → ветка «негатив/позитив»).
    
4. **If Positive**: запрос данных для партнёрки → отправка соглашения (6.G) → welcome‑пакет.
    
5. **Update DB**: `partner_profiles`, `documents(doc_type='partner_agreement')`.
    

**Acceptance:**

- Все исходящие письма логируются в `messages`; ответы правильно прекращают/переводят кампанию; документ подписан → welcome.
    

---

### 6.J) «Fake‑client» аутрич для получения оценок

**Workflow:** `mkt.camp.fake_client`

**Steps:**

1. **Target List**: импорт адресов компаний (CSV) → `contacts/companies` с тегом `fake_client`.
    
2. **RFP Template**: письмо‑задача на оценку (варианты по доменам: web3, fintech, AI).
    
3. **Sequencer**: 2–3 касания с периодами.
    
4. **Intake Replies**: парсинг ответов → `messages` + извлечение оценок/сроков → `pipeline_events`.
    
5. **Internal Report**: еженедельный отчёт с рейтингом ответов (скорость, полнота, цена).
    

**Acceptance:**

- Все ответы сохранены; отчёт формируется; можно фильтровать лучших поставщиков.
    

---

## 7) Маппинг данных (поле‑в‑поле)

### 7.1. Forms/Webhooks → submissions

|Источник|Поле|Куда|
|---|---|---|
|Header|X-Form-Code|submissions.form_id (lookup по forms.code)|
|Header|X-Resource|submissions.resource|
|Body|email/full_name/message/json|submissions.email/full_name/message/raw_payload|
|Body|external_id (если есть)|submissions.external_id|

### 7.2. Submissions/Email → contacts/companies/leads

- **contacts**: upsert по email; `preferred_lang`, `timezone` если есть; multi‑email/phone в `contact_emails/phones`.
    
- **companies**: по домену email либо payload.website.
    
- **leads**: `type` из intent; `owner_user_id` по роутингу; `source_id` из headers (chain_do/main_site/email_inbox).
    

### 7.3. Conversations/Messages

- Первое входящее кладём как `messages(direction='inbound', medium='webhook|email')`.
    
- Все исходящие письма из n8n пишем как `messages(direction='outbound', medium='email')` c body/body_html.
    

### 7.4. Documents/Bookings/Tasks

- `documents`: doc_type (`nda`, `partner_agreement`), provider, status/urls/timestamps.
    
- `bookings`: calendly ids, status.
    
- `tasks`: типы `followup|send_nda|review_estimate|schedule_call|add_to_pool`.
    

---

## 8) Шаблоны контента (библиотека)

- **Партнёрский Initial / Followups** — тексты готовы (адаптируем переменные: имя, компания, стэк, ссылка на соглашение).
    
- **Welcome to Partner Network** — письмо‑подтверждение.
    
- **NDA request** (client/candidate) — кратко и по делу.
    
- **Dev‑request Initial** — «приняли заявку + вопросы + Calendly».
    
- **Vacancy nurture** — 1–2 касания в неделю, 2–3 недели (сбор CV, ставки, стек).
    
- **Newsletter welcome/digest** — базовые шаблоны и слоты для статей.
    

> Все шаблоны храним в таблице `templates` и вызываем по имени; переменные — `{{ }}`.

---

## 9) Мониторинг, алерты, отчётность

- **Error‑handler**: глобальный воркфлоу `ops.util.on_error` (catch → Telegram/Email + pipeline_events).
    
- **Здоровье**: `ops.util.healthcheck` (cron) — проверка доступности IMAP/SMTP/Calendly/Chaindoc/DB.
    
- **Еженедельный отчёт**: новый лиды/стадии, подписчики, успех кампаний.
    

---

## 10) Внедрение: пошаговый план (атомарные задачи)

### Этап 0 — Инфраструктура (0.1)

-  Поднять n8n (prod + staging), настроить TLS/домены.
    
-  Завести Credentials: IMAP/SMTP, Calendly, Chaindoc/DocuSign, DeepL, Telegram/Slack, DB.
    
-  Применить SQL схему; создать readonly роль для аналитики.
    
-  Создать Telegram канал `#sales_ops`, добавить менеджеров.
    

### Этап 1 — Универсальный инбокс (forms + email)

-  `crm.in.forms`: вебхуки, запись в `submissions`, классификация, ветвление.
    
-  `crm.in.email`: IMAP → submissions/messages, классификация, роутинг.
    
-  Прослойка idempotency (external_id/dedupe_key).
    
-  Просмотр вьюшки `view_inbound_inbox` для QA.
    

### Этап 2 — Клиентский флоу (dev_request)

-  `crm.proc.dev_request`: автоответ, вопросы, Calendly, follow‑ups.
    
-  `ops.in.calendly`: букинги и статусы.
    
-  `ops.doc.sender` + `ops.in.docs`: NDA отправка и статусы.
    
-  Telegram нотификации менеджерам.
    

### Этап 3 — HR флоу (vacancy)

-  `hr.proc.vacancy`: NDA → nurture 2–3 недели → candidate_profile → pools.
    
-  Шаблоны nurture и формы запроса CV/ставок/локации.
    

### Этап 4 — Newsletter

-  `mkt.proc.newsletter`: подписка, welcome, (опц.) double opt‑in.
    
-  `mkt.proc.digest`: еженедельный дайджест контента.
    

### Этап 5 — Партнёрский аутрич

-  `mkt.camp.partners`: кампания + шаблоны + шаги + ветки ответов.
    
-  Автоотправка соглашения и welcome после подписания.
    

### Этап 6 — «Fake‑client» кампания

-  `mkt.camp.fake_client`: импорт таргетов, RFP письма, приём ответов.
    
-  Отчёт о полученных оценках (скорость/полнота/цена).
    

### Этап 7 — Документация и handover

-  Wiki с картой воркфлоу, точками интеграций и SLA.
    
-  Чек‑листы на ручные процедуры (override, re‑play, emergency stop).
    

---

## 11) Критерии готовности (Definition of Done)

- Все воркфлоу наименованы и версионируются (экспорт в Git).
    
- Для каждого воркфлоу: тесты, сценарии отказов, алерты.
    
- Данные устойчиво записываются в БД, дубликаты подавляются.
    
- Менеджеры получают нотификации и видят одну «картину мира» по лидам/кандидатам/партнёрам.
    

---

## 12) Предположения и плейсхолдеры

- Chaindoc/DocuSign имеют готовые шаблоны NDA/Partner Agreement (IDs будут добавлены).
    
- Calendly уже настроен и выдаёт ID событий и вебхуки на наш URL.
    
- Humanizer доступен как HTTP API; та же история для LLM провайдера.
    

---

## Приложение A — Полезные SQL для отладки

```sql
-- Последние немусорные входящие
select * from view_inbound_inbox limit 50;

-- Лиды на стадии scheduled_call за неделю
select * from leads where stage='scheduled_call' and created_at>now()-interval '7 days';

-- Подписчики без отписки
select * from newsletter_subscribers where status='subscribed' and unsubscribed_at is null;

-- Последние событий пайплайна по сущности
select * from pipeline_events where entity_id = $1 order by occurred_at desc limit 100;
```

---

## Приложение B — Переменные шаблонов писем

- Общие: `{{name}}`, `{{company}}`, `{{timezone}}`, `{{calendly_url}}`, `{{nda_url}}`, `{{partner_agreement_url}}`, `{{unsubscribe_url}}`.
    
- Технические: `{{lead_id}}`, `{{conversation_id}}`, `{{doc_id}}`, `{{booking_id}}`.
    

---

## Приложение C — Соглашения по тегам

- Источники: `source:chain_do/main_site/email_inbox` (в `sources` уже есть коды).
    
- Кампании: `camp:partners`, `camp:fake_client`.
    
- HR: `pool:*`, `role:*`, `seniority:*`.
    

---

## Приложение D — Словарь стадий и переходов

- **Client**: `new → contacted → scheduled_call → sent_nda → nda_signed → kyc_paid → qualified → won/lost`.
    
- **Vacancy**: `new → contacted → sent_nda → nda_signed → in_pool → archived`.
    
- **Partner**: `new → contacted → sent_nda/partner_agreement → signed → active`.
    

---

### Конец документа