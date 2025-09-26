# Кейс 1.1 — Обработка заявки на разработку/консультацию

Документ описывает связку воркфлоу n8n, которые закрывают весь путь лида из формы до подписанного NDA.

## Общая цепочка

| Шаг | Воркфлоу | Назначение |
| --- | --- | --- |
| 1 | `crm.in.forms` | Принимает вебхуки/почту, нормализует заявку и создаёт базовые сущности в БД. |
| 2 | `crm.proc.dev_request` | Отправляет первичный ответ и подготавливает данные для асинхронных follow-up через крон. |
| 3 | `mkt.proc.sequencer` | Крон-процесс, который подхватывает лидов без ответа и рассылает follow-up письма. |
| 4 | `ops.in.calendly` | Регистрирует бронь звонка и переключает состояние лида. |
| 5 | `ops.doc.send_nda` | Отправляет NDA через Chaindoc и фиксирует событие в БД. |

Ключевые таблицы PostgreSQL: `submissions`, `classifications`, `contacts`, `leads`, `conversations`, `messages`, `bookings`, `documents`, `tasks`.

---

## `crm.in.forms`

**Триггеры:**
- Webhook (`/crm.in.forms`) с заголовками `X-Resource`, `X-Form-Code`.
- Gmail trigger — e2e приём писем, идентичных по обработке.

**Что делает:**
1. Сбор "конверта" (метаданные источника) и запуск Anthropic для извлечения/классификации.
2. Жёсткая проверка политики intake: для клиентских форм фильтруем всё, что не `intent=client|partner|newsletter` → спам.
3. Идемпотентная запись в `submissions` + `classifications`.
4. Апсерты `companies`/`contacts` (учёт дополнительных email через `contact_emails`).
5. Создание `leads` (тип/owner определяется по intent), старт `conversations`, запись первого `messages` и вложений.
6. Telegram-нотификация в канал `#sales_ops` с кратким summary (`sales_summary` из AI).
7. Маршрутизация по типу формы: для `dev_request` формируем payload и вызываем `crm.proc.dev_request` как саб-флоу (через `Execute Workflow`). Кандидатские формы обслуживает отдельный `hr.in.candidates`.

**Выходные данные:** объект с `lead_id`, `contact_id`, `conversation_id`, email/имя/таймзона — используется дальше.

---

## `crm.proc.dev_request`

**Триггер:** вызов из `crm.in.forms` (или другого intake) через `Execute Workflow`.

**Основной сценарий:**
1. **Контекст и конфиг** — выбираем язык шаблона (`ru|en|pl`), базовые переменные (Calendly, имя отправителя).
2. **Шаблон первого ответа** — берём из таблицы `templates` (`dev_request.initial.<lang>`), при отсутствии локали делаем машинный перевод через Anthropic. Плейсхолдеры `{{name}}`, `{{calendly_url}}`, `{{from_name}}` заменяются в `Code`-ноду.
3. **Humanizer** — небольшая случайная задержка 1–5 минут перед отправкой Gmail.
4. **Отправка письма** — Gmail node, затем логируем в `messages` (direction=`outbound`, medium=`email`) и обновляем:
   - `tasks` (создаём задачу "проверить букинг" с дедлайном +24h),
   - `leads.stage = contacted`,
   - `conversations.last_message_at`.
5. **Синхронизация с кроном:** после успешной отправки письма сбрасываем теги `followup_*`, пишем событие `dev_request_followup_scheduled` и завершаем выполнение. Follow-up цепочку подхватывает `mkt.proc.sequencer`.

**Итого:** воркфлоу обрабатывает только первичный ответ, не зависая в `Wait`-нодах и не теряя лидов при рестартах n8n.

---

## `mkt.proc.sequencer`

**Триггер:** `Schedule Trigger` (ежечасно).

**Что делает:**
1. Ищет лидов с событием `dev_request_followup_scheduled`, у которых нет букинга и входящих ответов после первичного письма.
2. Формирует списки для Follow-up #1 и Follow-up #2:
   - первый ориентируется на возраст события (≥24h) и отсутствие тега `followup_1_sent`;
   - второй — на фактическое время письма с тегом `followup_1_sent` (≥48h) и отсутствие `followup_2_sent`.
3. Для каждого лида вызывает саб-флоу `sub.mkt.send_sequence_step`, который подбирает шаблон и отправляет письмо через Gmail.
4. После Follow-up #2 добавляет тег `followup_sequence_done` и пишет событие `dev_request_followup_completed`.

**Почему так:** логика follow-up переехала из `crm.proc.dev_request`, чтобы не держать активные исполнения n8n и не терять таймеры при падении сервера.

---

## `ops.in.calendly`

**Триггер:** вебхук Calendly (`invitee.created`, `invitee.canceled`).

**Invitee created:**
1. `Validate & Parse` — приводим payload к консистентному виду (email, URI, время, таймзона).
2. `Find Lead by Email` — расширенный SQL:
   - ищет `lead_id`, `contact_id`, имя;
   - подтягивает рабочий email (приоритет: `contacts.email` → `contact_emails.is_primary` → payload).
3. При отсутствии лида — Telegram-алерт про "не распознан".
4. При наличии:
   - Upsert `bookings` (обновление даты/статуса),
   - `leads.stage = scheduled_call`,
   - Telegram с деталями слота.
5. **NDA** — новый блок:
   - `Prepare NDA Payload` собирает lead/contact/email, передаёт в саб-флоу `ops.doc.send_nda` (синхронно, `waitForSubWorkflow=true`).

**Invitee canceled:**
- `bookings.status = canceled`,
- `leads.stage = contacted`,
- Telegram о том, что слот снят.

---

## `ops.doc.send_nda`

**Триггер:** `Execute Workflow` из `ops.in.calendly` (можно переиспользовать и из других флоу).

**Шаги:**
1. `Prepare Context` — валидация входа (`lead_id`, `email`), вычисление `external_id = nda-<lead_id>` и дефолтной ссылки `https://chain.do/doc/<external_id>`.
2. `Upsert Document` — идемпотентная запись в `documents` (если Chain.do уже создало документ, просто обновляем статус/ссылку).
3. `Update Lead Stage` — переводим лида в `sent_nda`, если он ещё не `nda_signed|won|lost`.
4. `Notify Team (NDA)` — Telegram-алерт с ссылкой для отслеживания.

**Результат:** после брони звонка NDA автоматически улетает клиенту, статус фиксируется в БД, команда видит ссылку и может контролировать подписание.

---

## Как использовать BA/оператору

- **Проверить, что лид завёлся:** таблица `view_inbound_inbox`/`leads` должна содержать запись после `crm.in.forms`. Если нет — смотреть `submissions` и алерты спама.
- **Понять, что отправлено клиенту:** открыть `messages` по `conversation_id` — видно первичное письмо и follow-up'ы с метками `kind`.
- **Понять, есть ли звонок:** `bookings` + Telegram-уведомления от `ops.in.calendly`.
- **NDA статус:** `documents` (по `lead_id`), стадия лида (`sent_nda`) и Telegram нотификация.
- **Настроить тексты:** изменяем шаблоны в таблице `templates` либо тексты в `Code` нодах follow-up'ов.

Диагностика: все ветки защищены идемпотентными INSERT/UPDATE, поэтому повторный запуск воркфлоу безопасен (дубли не создаются).

---

# Кейс 1.2 — Обработка отклика на вакансию

Ниже описана связка воркфлоу, которая превращает входящее резюме в «управляемый» HR-пайплайн с NDA, задачами и отложенными фоллоуапами.

## Общая цепочка

| Шаг | Воркфлоу | Назначение |
| --- | --- | --- |
| 1 | `hr.in.candidates` | Принимает заявку кандидата, нормализует профиль и создаёт сущности в БД. |
| 2 | `hr.proc.vacancy` | Создаёт/обновляет профиль кандидата, отправляет NDA, шлёт первичное письмо и ставит фоллоу-апы в очередь. |
| 3 | `hr.proc.sequencer` | Крон-сборщик: каждые N часов проверяет кандидатов без ответа и рассылает follow-up 1/2 либо завершает пайплайн. |
| 4 | `ops.doc.send_nda` | Повторно используется для генерации и логирования NDA (Chaindoc) по входящему lead_id. |

Основные таблицы: `candidate_profiles`, `candidate_pool_members`, `messages`, `tasks`, `pipeline_events`, `leads`.

---

## `hr.in.candidates`

- Отдельный intake для HR: собственный webhook и Gmail-триггер с `source_code = email_inbox_hr`.
- Политика приёма допускает только `intent=candidate` и формы `vacancy|hr_intake|hr_candidate`, остальное маркируется тегом `policy_violation_non_candidate`.
- Создаёт `contacts`/`leads`, сохраняет расширенный `candidate_profile`, пушит уведомление в Telegram и вызывает `hr.proc.vacancy`.
- Ошибки саб-процесса логируются в `pipeline_events` и дублируются в Telegram.

---

## `hr.proc.vacancy`

**Триггер:** `Execute Workflow` из `hr.in.candidates` с намерением `candidate`.

**Что делает:**

1. **Подготовка контекста:** нормализует профиль (skills, ставки, availability), подбирает пул(ы) (`React Senior`, `Middle Talent Pool` и т.п.), генерирует ссылку NDA (`nda-<lead_id>`), фиксирует языковые настройки.
2. **Upsert в БД:**
   - `candidate_profiles` — idempotent upsert по `contact_id`;
   - `candidate_pool_members` — добавляет/обновляет статус (`prospect`/`active`), создаёт пул если его ещё нет;
   - `tasks` — открытые `review_estimate` (+2 дня) и `add_to_pool` (+7 дней) только если их ещё не было.
3. **NDA:** вызывает `ops.doc.send_nda` синхронно (`waitForSubWorkflow=true`) и переводит стадию `leads.stage` → `nurturing`.
4. **Первичный контакт:** humanized `Wait` (4–9 минут), локализованный e-mail (RU/EN) с ссылкой на NDA, лог в `messages`/`pipeline_events`.
5. **Постановка в sequencer:** сразу после отправки письма записывает событие `vacancy_followup_scheduled` (с контекстом: `conversation_id`, `candidate_profile_id`, задержки follow-up) и завершает воркфлоу без длительных `Wait`.

**Выходные данные:**

- Для `Execute Workflow` возвращается статус `scheduled`, `lead_id`, `candidate_profile_id`, а также флаг `followups_scheduled=true`.

**Как использовать HR/оператору:**

- **Профиль кандидата:** таблица `candidate_profiles` + привязанные `candidate_pool_members` показывают актуальный статус.
- **Коммуникация:** вся переписка логируется в `messages` (meta.kind=`hr_initial|hr_followup_1|hr_followup_2`).
- **Задачи:** открытые задачи по лиду (`review_estimate`, `add_to_pool`) сигнализируют, что нужен ручной review или «приземление» в пул.
- **Архив/успех:** события в `pipeline_events` (`vacancy_candidate_engaged` / `vacancy_candidate_archived`) и финальная стадия лида отражают итог nurture-цикла.

---

## `hr.proc.sequencer`

**Триггер:** `Schedule Trigger` (ежечасно, может быть скорректирован под нагрузку).

**Что делает:**

1. **После первичного письма:** ищет лидов с событием `vacancy_followup_scheduled`, у которых прошло ≥5 дней, нет outbound `hr_followup_1`, нет ответа/NDA → либо помечает кандидата как `in_pool`, либо шлёт follow-up #1.
2. **После follow-up #1:** контролирует окна ≥7 дней, отсутствие `hr_followup_2` и свежих ответов → отправляет follow-up #2 или переводит в `in_pool`.
3. **После follow-up #2:** ещё через 7 дней проверяет активность; при успехе — `vacancy_candidate_engaged`, иначе — `vacancy_candidate_archived` с закрытием задач и архивом пула.
4. **Логи и идемпотентность:** каждое действие фиксируется в `messages` (`meta.kind=hr_followup_1|2`) и `pipeline_events` (`vacancy_followup_1_sent`, `vacancy_followup_2_sent`, `vacancy_candidate_*`).

**Зачем выносить в отдельный sequencer:** крон не держит активных исполнений n8n на протяжении недель, переживает рестарты инстанса и одинаково обрабатывает повторные попытки (идемпотентные SQL).
