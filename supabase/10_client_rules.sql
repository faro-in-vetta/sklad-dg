-- =====================================================================
-- DG FILATI · Складський облік пряжі
-- Крок 10: роль «Клієнт» — ЧАСТИНА 2 з 2
--
-- Виконувати ПІСЛЯ 09_client_enum.sql.
-- Файл можна виконувати повторно.
--
-- Суть: клієнт працює як менеджер, але бачить лише ті заявки, що виписані
-- на його компанію. Фільтр у застосунку — це зручність; справжня межа
-- проходить тут, у правилах доступу, інакше її можна було б обійти
-- прямим запитом до API.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Де зберігається прив'язка
-- ---------------------------------------------------------------------
alter table profiles add column if not exists client text;
alter table invites  add column if not exists client text;

comment on column profiles.client is
  'Для ролі client: назва клієнта в заявках. Порівняння без регістру й крайніх пробілів.';


-- ---------------------------------------------------------------------
-- 2. Нова людина отримує прив'язку з рядка запрошення
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

  insert into profiles (id, email, name, role, client)
  values (new.id, new.email,
          coalesce(inv.name, split_part(new.email,'@',1)),
          coalesce(inv.role, case when exists (select 1 from profiles) then 'manager' else 'admin' end::user_role),
          inv.client);

  if inv.id is not null then
    update invites set accepted_at = now() where id = inv.id;
  end if;
  return new;
end $$;


-- ---------------------------------------------------------------------
-- 3. Допоміжні функції
-- ---------------------------------------------------------------------
create or replace function is_client() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = 'client' from profiles
                    where id = auth.uid() and not coalesce(removed,false)), false)
$$;

create or replace function my_client() returns text
language sql stable security definer set search_path = public as $$
  select lower(btrim(coalesce(client,''))) from profiles where id = auth.uid()
$$;

-- клієнт зіставляється із заявкою без урахування регістру й крайніх пробілів;
-- порожня прив'язка не дає доступу до жодної заявки
create or replace function sees_order(p_client text) returns boolean
language sql stable security definer set search_path = public as $$
  select case
           when not is_client() then true
           when coalesce(my_client(),'') = '' then false
           else lower(btrim(coalesce(p_client,''))) = my_client()
         end
$$;


-- ---------------------------------------------------------------------
-- 4. Читання заявок
--    Прибираємо всі чинні правила читання на цих таблицях і ставимо одне
--    явне: так не лишиться старішого дозволу, який мовчки відкривав би
--    клієнтові чужі заявки (правила доступу складаються через АБО).
-- ---------------------------------------------------------------------
do $$
declare p record;
begin
  for p in select tablename, policyname from pg_policies
            where schemaname = 'public'
              and tablename in ('orders','order_lines','payments','returns','order_events')
              and cmd = 'SELECT'
  loop
    execute format('drop policy %I on %I', p.policyname, p.tablename);
  end loop;
end $$;

create policy orders_select on orders for select
  using (is_member() and sees_order(client));

create policy order_lines_select on order_lines for select
  using (is_member() and exists (
    select 1 from orders o where o.id = order_lines.order_id and sees_order(o.client)));

create policy payments_select on payments for select
  using (is_member() and exists (
    select 1 from orders o where o.id = payments.order_id and sees_order(o.client)));

create policy returns_select on returns for select
  using (is_member() and exists (
    select 1 from orders o where o.id = returns.order_id and sees_order(o.client)));

create policy order_events_select on order_events for select
  using (is_member() and exists (
    select 1 from orders o where o.id = order_events.order_id and sees_order(o.client)));


-- ---------------------------------------------------------------------
-- 5. Клієнт виписує заявки тільки на себе
--    Інакше він міг би створити заявку на чужу назву — і побачити чужу
--    ціну, а чужа компанія отримала б рядок у своїй історії.
-- ---------------------------------------------------------------------
create or replace function guard_order_client() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if is_client() then
    if coalesce(my_client(),'') = '' then
      raise exception 'Обліковий запис клієнта не прив''язано до назви клієнта';
    end if;
    if lower(btrim(coalesce(new.client,''))) is distinct from my_client() then
      raise exception 'Заявку можна оформити лише на власну компанію';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists orders_client_guard on orders;
create trigger orders_client_guard
before insert or update of client on orders
for each row execute function guard_order_client();


-- ---------------------------------------------------------------------
-- 6. Скільки товару в резерві — підсумком, без імен і сум
--    Клієнт чужих заявок не бачить, тож самотужки вільний залишок
--    порахувати не може: товар здавався б вільним, хоча він уже за кимось.
--    Віддаємо тільки дві цифри на SKU.
-- ---------------------------------------------------------------------
drop view if exists sku_reserved;
create view sku_reserved as
  select l.sku_id,
         sum(coalesce(l.kg,0))::numeric    as kg,
         sum(coalesce(l.cones,0))::numeric as cones
    from order_lines l
    join orders o on o.id = l.order_id
   where o.status = 'active'
     and is_member()
   group by l.sku_id;

-- навмисно НЕ security_invoker: сенс подання саме в тому, щоб порахувати
-- по всіх заявках, зокрема чужих. Назв клієнтів і грошей тут немає.
alter view sku_reserved set (security_invoker = off);
grant select on sku_reserved to authenticated;


-- ---------------------------------------------------------------------
-- 7. Перевірка
-- ---------------------------------------------------------------------
select unnest(enum_range(null::user_role))::text as ролі;

select tablename, policyname
  from pg_policies
 where schemaname='public'
   and tablename in ('orders','order_lines','payments','returns','order_events')
   and cmd='SELECT'
 order by tablename;
