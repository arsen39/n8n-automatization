# Кейс 1.1 — Обработка заявки на разработку/консультацию

Документ описывает связку воркфлоу n8n, которые закрывают весь путь лида из формы до подписанного NDA.

## Общая цепочка

| Шаг | Воркфлоу | Назначение |
| --- | --- | --- |
| 1 | `crm.in.forms` | Принимает вебхуки/почту, нормализует заявку и создаёт базовые сущности в БД. |
| 2 | `crm.proc.dev_request` | Автоматизирует коммуникацию с клиентом: первичный ответ, humanizer, follow-up цепочка. |
| 3 | `ops.in.calendly` | Регистрирует бронь звонка и переключает состояние лида. |
| 4 | `ops.doc.send_nda` | Отправляет NDA через Chaindoc и фиксирует событие в БД. |

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
7. Маршрутизация по типу формы: для `dev_request` формируем payload и вызываем `crm.proc.dev_request` как саб-флоу (через `Execute Workflow`).

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
5. **Follow-up логика (новое):**
   - Через 24 часа (`Wait`) выполняем `5b. Check Engagement`: SQL проверяет наличие свежей записи в `bookings` или входящего ответа (`messages` direction=`inbound`).
   - Если активности нет, формируем Follow-up #1 (локализованные шаблоны в `Code` ноде), делаем humanized задержку 3–8 минут, отправляем Gmail, логируем письмо как `kind=followup_1` в `messages`.
   - Через 48 часов после Follow-up #1 повторяем проверку. При отсутствии активности отправляем Follow-up #2 (отдельный текст, локализация, логирование `kind=followup_2`).
   - Если на любом чекпоинте найден букинг или ответ, цепочка останавливается (ветка `true` в IF).

**Итого:** клиент гарантированно получает первое письмо ≤15 мин и два мягких напоминания, пока не назначит звонок/не ответит.

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
