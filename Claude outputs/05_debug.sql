-- =====================================================================
-- DG FILATI · склад — режим налагодження
--
-- Поки система не запущена в роботу, адміну можна видаляти назавжди
-- будь-що: заявки, SKU, акаунти. Після старту перемикач вимикається,
-- і лишається тільки безпечне прибирання — те, що не тягне за собою
-- залишків і грошей.
--
-- Перемикач спільний для всіх: лежить у базі, а не в браузері.
-- Саме видалення виконує Edge Function invite-user під службовим ключем,
-- тому правила доступу нижче навмисно не відкривають видалення напряму.
--
-- Запускати у SQL Editor проєкту sklad-dg після 01, 02 і 03.
-- =====================================================================

create table if not exists app_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now(),
  updated_by uuid references profiles(id)
);
comment on table app_settings is 'Спільні налаштування застосунку';

insert into app_settings (key, value) values ('debug_mode', 'true'::jsonb)
on conflict (key) do nothing;

alter table app_settings enable row level security;

-- читають усі, хто має доступ: інтерфейс має знати, який зараз режим
drop policy if exists settings_read on app_settings;
create policy settings_read on app_settings for select using (is_member());

-- перемикає лише адмін
drop policy if exists settings_write on app_settings;
create policy settings_write on app_settings for all
  using (my_role() = 'admin') with check (my_role() = 'admin');

-- чи ввімкнений режим налагодження
create or replace function debug_on() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select value = 'true'::jsonb from app_settings where key = 'debug_mode'), false);
$$;

select key, value, 'готово' as "—" from app_settings;
