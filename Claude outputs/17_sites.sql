-- =====================================================================
-- DG FILATI · Складський облік пряжі
-- Крок 17: два склади — Сан Джованні (sg) і Львів (lv)
--
-- Виконувати ПІСЛЯ 16_next_sku_code.sql. Файл можна виконувати повторно.
-- ПІСЛЯ нього виконати окремо 18_mov_enum.sql.
--
-- Модель проста й надійна: КАРТКА SKU належить одному складу, ЗАЯВКА теж.
-- Товар «переїжджає» окремою операцією переміщення, яка знімає кілограми
-- з картки одного складу й додає на картку-двійника іншого.
--
-- Усе, що вже в базі, лишається на Сан Джованні — це значення за
-- замовчуванням, тож жодного рядка правити руками не треба.
--
-- Хто що бачить: адмін і головний бухгалтер — обидва склади завжди;
-- менеджерам, комірникам і клієнтам склади призначає адмін.
-- Фільтр у застосунку — зручність; справжня межа проходить тут.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Колонки
-- ---------------------------------------------------------------------
alter table skus     add column if not exists site  text not null default 'sg';
alter table orders   add column if not exists site  text not null default 'sg';
alter table profiles add column if not exists sites text[] not null default array['sg','lv'];
alter table invites  add column if not exists sites text[] not null default array['sg','lv'];

do $$ begin
  alter table skus   add constraint skus_site_chk   check (site in ('sg','lv'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table orders add constraint orders_site_chk check (site in ('sg','lv'));
exception when duplicate_object then null; end $$;

comment on column skus.site   is 'Склад картки: sg — Сан Джованні, lv — Львів';
comment on column orders.site is 'Склад, з якого збирається заявка';
comment on column profiles.sites is 'Які склади бачить людина; для admin і accountant не діє';

create index if not exists skus_site_idx   on skus (site) where not deleted;
create index if not exists orders_site_idx on orders (site);


-- ---------------------------------------------------------------------
-- 2. Нова людина отримує склади з рядка запрошення
--    (доповнюємо функцію з кроку 10, решта логіки без змін)
-- ---------------------------------------------------------------------
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv invites%rowtype;
begin
  select * into inv from invites
   where lower(email) = lower(new.email) and accepted_at is null
   order by created_at desc limit 1;

  if inv.id is null and exists (select 1 from profiles) then
    raise exception 'Реєстрація лише за запрошенням';
  end if;

  insert into profiles (id, email, name, role, client, sites)
  values (new.id, new.email,
          coalesce(inv.name, split_part(new.email,'@',1)),
          coalesce(inv.role, case when exists (select 1 from profiles) then 'manager' else 'admin' end::user_role),
          inv.client,
          coalesce(nullif(inv.sites, '{}'), array['sg','lv']));

  if inv.id is not null then
    update invites set accepted_at = now() where id = inv.id;
  end if;
  return new;
end $$;


-- ---------------------------------------------------------------------
-- 3. Помічники
-- ---------------------------------------------------------------------
create or replace function my_sites() returns text[]
language sql stable security definer set search_path = public as $$
  select case
           when my_role() in ('admin','accountant') then array['sg','lv']
           else coalesce(nullif((select sites from profiles
                                  where id = auth.uid() and not coalesce(removed,false)), '{}'),
                         array['sg','lv'])
         end
$$;

-- порожній або невідомий склад вважаємо Сан Джованні: так старі рядки
-- лишаються видимими, навіть якщо колонку колись почистять
create or replace function sees_site(p_site text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(nullif(btrim(coalesce(p_site,'')),''), 'sg') = any (my_sites())
$$;

revoke all on function my_sites()        from public, anon;
revoke all on function sees_site(text)   from public, anon;
grant execute on function my_sites()      to authenticated;
grant execute on function sees_site(text) to authenticated;


-- ---------------------------------------------------------------------
-- 4. Читання: прибираємо ВСІ чинні правила SELECT і ставимо по одному.
--    Правила складаються через АБО — забуте старе мовчки відкрило б
--    доступ до чужого складу.
-- ---------------------------------------------------------------------
do $$
declare p record;
begin
  for p in select tablename, policyname from pg_policies
            where schemaname = 'public'
              and tablename in ('skus','orders','order_lines','payments','returns','order_events')
              and cmd = 'SELECT'
  loop
    execute format('drop policy %I on %I', p.policyname, p.tablename);
  end loop;
end $$;

create policy skus_select on skus for select
  using (is_member() and sees_site(site));

create policy orders_select on orders for select
  using (is_member() and sees_order(client) and sees_site(site));

create policy order_lines_select on order_lines for select
  using (is_member() and exists (
    select 1 from orders o where o.id = order_lines.order_id
       and sees_order(o.client) and sees_site(o.site)));

create policy payments_select on payments for select
  using (is_member() and exists (
    select 1 from orders o where o.id = payments.order_id
       and sees_order(o.client) and sees_site(o.site)));

create policy returns_select on returns for select
  using (is_member() and exists (
    select 1 from orders o where o.id = returns.order_id
       and sees_order(o.client) and sees_site(o.site)));

create policy order_events_select on order_events for select
  using (is_member() and exists (
    select 1 from orders o where o.id = order_events.order_id
       and sees_order(o.client) and sees_site(o.site)));


-- ---------------------------------------------------------------------
-- 5. Запис: картку й заявку можна створити лише на «своєму» складі
-- ---------------------------------------------------------------------
drop policy if exists skus_write on skus;
create policy skus_write on skus for insert
  with check (is_store() and sees_site(site));

drop policy if exists skus_update on skus;
create policy skus_update on skus for update
  using (is_store() and sees_site(site)) with check (is_store() and sees_site(site));

drop policy if exists orders_create on orders;
create policy orders_create on orders for insert
  with check ((is_sales() or is_store()) and sees_site(site));


-- ---------------------------------------------------------------------
-- 6. Позиції заявки — лише з того самого складу, що й заявка
-- ---------------------------------------------------------------------
create or replace function guard_line_site() returns trigger
language plpgsql security definer set search_path = public as $$
declare o_site text; s_site text;
begin
  select site into o_site from orders where id = new.order_id;
  select site into s_site from skus   where id = new.sku_id;
  if coalesce(o_site,'sg') is distinct from coalesce(s_site,'sg') then
    raise exception 'Позиція з іншого складу: заявка — %, картка — %', o_site, s_site;
  end if;
  return new;
end $$;

drop trigger if exists order_lines_site_guard on order_lines;
create trigger order_lines_site_guard
before insert or update of sku_id, order_id on order_lines
for each row execute function guard_line_site();


-- ---------------------------------------------------------------------
-- 7. Перевірка
-- ---------------------------------------------------------------------
select 'skus'     as t, site, count(*) from skus   group by site
union all
select 'orders'   as t, site, count(*) from orders group by site;

select policyname, cmd from pg_policies
 where schemaname='public' and tablename in ('skus','orders') order by tablename, cmd, policyname;
