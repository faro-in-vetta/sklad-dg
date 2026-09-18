-- =====================================================================
-- DG FILATI · Складський облік пряжі
-- Крок 3: виправлення після звірки коду з правилами (18.09.2026)
-- Запускати ПІСЛЯ 01_schema.sql і 02_rls.sql у SQL Editor проєкту sklad-dg.
-- Файл можна виконувати повторно.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Реєстрація лише за запрошенням
--    Було: хто завгодно реєструється і автоматично стає менеджером,
--    тобто бачить увесь каталог, заявки й дебіторку.
-- ---------------------------------------------------------------------
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv invites%rowtype;
begin
  select * into inv from invites
   where lower(email) = lower(new.email) and accepted_at is null
   order by created_at desc limit 1;

  -- перший акаунт у порожній базі — адмін (щоб було кому запрошувати)
  if inv.id is null and exists (select 1 from profiles) then
    raise exception 'Реєстрація лише за запрошенням';
  end if;

  insert into profiles (id, email, name, role)
  values (new.id, new.email,
          coalesce(inv.name, split_part(new.email,'@',1)),
          coalesce(inv.role, case when exists (select 1 from profiles) then 'manager' else 'admin' end::user_role));

  if inv.id is not null then
    update invites set accepted_at = now() where id = inv.id;
  end if;
  return new;
end $$;


-- ---------------------------------------------------------------------
-- 2. Видалення ціни закупівлі більше не падає з помилкою
--    Було: тригер звертався до NEW і на DELETE, де NEW не існує.
-- ---------------------------------------------------------------------
create or replace function set_active_cost() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_sku uuid;
begin
  v_sku := coalesce(new.sku_id, old.sku_id);
  update sku_costs set active = false where sku_id = v_sku and active;
  update sku_costs c set active = true
   where c.id = (select id from sku_costs where sku_id = v_sku
                  order by date desc, created_at desc limit 1);
  return coalesce(new, old);
end $$;

drop trigger if exists sku_costs_activate on sku_costs;
create trigger sku_costs_activate
after insert or delete on sku_costs
for each row execute function set_active_cost();

-- окремо на зміну дати ціни. Умова WHEN обов'язкова: сама функція оновлює
-- колонку active, і без неї тригер викликав би сам себе до переповнення стека.
drop trigger if exists sku_costs_reactivate on sku_costs;
create trigger sku_costs_reactivate
after update on sku_costs
for each row when (
  new.date is distinct from old.date or new.sku_id is distinct from old.sku_id
) execute function set_active_cost();


-- ---------------------------------------------------------------------
-- 3. Менеджер може анулювати власну заявку
--    Було: WITH CHECK вимагав status='active', тому 'cancelled' не проходив
--    і автор заявки не міг її анулювати взагалі.
--    Редагувати позиції після початку збірки він і далі не може —
--    це тримає політика order_lines нижче.
-- ---------------------------------------------------------------------
drop policy if exists orders_update on orders;
create policy orders_update on orders for update using (
  is_fin()
  or (is_store()  and status = 'active')
  or (created_by = auth.uid() and status = 'active')
) with check (
  is_fin()
  or (is_store()  and status in ('active','shipped'))
  or (created_by = auth.uid() and status in ('active','cancelled'))
);


-- ---------------------------------------------------------------------
-- 4. Комірник не чіпає гроші й дозволи
--    Було: комірник міг оновити будь-яку колонку заявки, зокрема суму
--    доставки, відмітку оплати й дозвіл на відвантаження.
-- ---------------------------------------------------------------------
create or replace function guard_order_money() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not is_fin() then
    if new.delivery    is distinct from old.delivery
    or new.paid        is distinct from old.paid
    or new.paid_at     is distinct from old.paid_at
    or new.approved_at is distinct from old.approved_at
    or new.approved_by is distinct from old.approved_by then
      raise exception 'Доставку, оплату й дозвіл на відвантаження вносить лише адмін або головний бухгалтер';
    end if;
  end if;

  if my_role() = 'storekeeper' then
    if new.terms is distinct from old.terms
    or new.days  is distinct from old.days
    or new.client is distinct from old.client then
      raise exception 'Умови оплати й клієнта комірник не змінює';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists orders_guard_money on orders;
create trigger orders_guard_money before update on orders
for each row execute function guard_order_money();


-- ---------------------------------------------------------------------
-- 5. Видаляти SKU можуть лише адмін і бухгалтер — також і «м'яким» способом
--    Було: політика на DELETE стояла, а прапорець deleted комірник
--    міг поставити звичайним оновленням.
--    Сюди ж — стара перевірка ціни продажу.
-- ---------------------------------------------------------------------
create or replace function guard_sku_sale() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not is_fin() and new.sale is distinct from old.sale then
    raise exception 'Ціну продажу змінює лише адмін або головний бухгалтер';
  end if;
  if not is_fin() and new.deleted is distinct from old.deleted then
    raise exception 'Видаляє SKU лише адмін або головний бухгалтер';
  end if;
  return new;
end $$;


-- ---------------------------------------------------------------------
-- 6. Не можна зарезервувати більше, ніж вільно — перевірка на сервері
--    Було: обмеження лише в браузері. Двоє менеджерів одночасно могли
--    забрати той самий товар і вигнати залишок у мінус.
--    Блокування рядка SKU серіалізує одночасні заявки по цьому SKU.
-- ---------------------------------------------------------------------
create or replace function guard_line_free() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_status order_status;
  stock_kg numeric := 0; stock_cn integer := 0;
  res_kg   numeric := 0; res_cn   integer := 0;
begin
  select status into v_status from orders where id = new.order_id;
  if v_status is distinct from 'active' then return new; end if;

  perform 1 from skus where id = new.sku_id for update;   -- черга по цьому SKU

  select coalesce(sum(case when type in ('out','smp','wrt') then -kg    else kg    end), 0),
         coalesce(sum(case when type in ('out','smp','wrt') then -cones else cones end), 0)
    into stock_kg, stock_cn
    from ops where sku_id = new.sku_id;

  select coalesce(sum(l.kg), 0), coalesce(sum(l.cones), 0)
    into res_kg, res_cn
    from order_lines l
    join orders o on o.id = l.order_id and o.status = 'active'
   where l.sku_id = new.sku_id and l.id is distinct from new.id;

  if res_kg + new.kg > stock_kg + 0.0005 then
    raise exception 'Вільно лише % кг, у заявці %', round(stock_kg - res_kg, 2), new.kg;
  end if;
  if res_cn + new.cones > stock_cn then
    raise exception 'Вільно лише % конусів, у заявці %', stock_cn - res_cn, new.cones;
  end if;
  return new;
end $$;

drop trigger if exists order_lines_guard_free on order_lines;
create trigger order_lines_guard_free before insert on order_lines
for each row execute function guard_line_free();

-- на оновленні перевіряємо лише тоді, коли міняється сама кількість у заявці.
-- Під час відвантаження комірник заповнює ship_kg/ship_cones уже після того,
-- як списання пішло в ops, — там перевіряти вільний залишок не можна.
drop trigger if exists order_lines_guard_free_upd on order_lines;
create trigger order_lines_guard_free_upd before update on order_lines
for each row when (
  new.kg     is distinct from old.kg
  or new.cones  is distinct from old.cones
  or new.sku_id is distinct from old.sku_id
) execute function guard_line_free();


-- ---------------------------------------------------------------------
-- 7. Номер заявки не злітає, коли двоє зберігають одночасно
--    Було: select max(no)+1 без блокування; другий отримував помилку
--    унікальності й заявка не зберігалася.
-- ---------------------------------------------------------------------
create or replace function next_order_no(p_yy smallint)
returns integer language plpgsql security definer set search_path = public as $$
declare v integer;
begin
  perform pg_advisory_xact_lock(778801, p_yy);
  select coalesce(max(no), 0) + 1 into v from orders where yy = p_yy;
  return v;
end $$;

-- страховка: якщо номер усе ж зайнято, беремо наступний вільний
create or replace function fix_order_no() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform pg_advisory_xact_lock(778801, new.yy);
  if new.no is null or new.no <= 0
     or exists (select 1 from orders where yy = new.yy and no = new.no) then
    select coalesce(max(no), 0) + 1 into new.no from orders where yy = new.yy;
  end if;
  return new;
end $$;

drop trigger if exists orders_fix_no on orders;
create trigger orders_fix_no before insert on orders
for each row execute function fix_order_no();


-- ---------------------------------------------------------------------
-- 8. Представлення не обходять правила доступу
--    Було: sku_levels віддавала ціну закупівлі геть усім, повз RLS
--    таблиці sku_costs (представлення виконувалося від власника).
-- ---------------------------------------------------------------------
drop view if exists sku_levels;
create view sku_levels
with (security_invoker = on) as
select
  s.id as sku_id,
  coalesce(o.kg, 0)::numeric(12,2)  as stock_kg,
  coalesce(o.cones, 0)              as stock_cones,
  coalesce(r.kg, 0)::numeric(12,2)  as reserved_kg,
  coalesce(r.cones, 0)              as reserved_cones,
  (coalesce(o.kg,0) - coalesce(r.kg,0))::numeric(12,2) as free_kg,
  (coalesce(o.cones,0) - coalesce(r.cones,0))          as free_cones
from skus s
left join (
  select sku_id,
         sum(case when type in ('out','smp','wrt') then -kg    else kg    end) as kg,
         sum(case when type in ('out','smp','wrt') then -cones else cones end) as cones
  from ops group by sku_id
) o on o.sku_id = s.id
left join (
  select l.sku_id, sum(l.kg) as kg, sum(l.cones) as cones
  from order_lines l
  join orders ord on ord.id = l.order_id and ord.status = 'active'
  group by l.sku_id
) r on r.sku_id = s.id
where not s.deleted;

-- ціна закупівлі — окремо, під своїм RLS (sku_costs бачать лише адмін і бухгалтер)
create or replace view sku_cost_active
with (security_invoker = on) as
select c.sku_id, c.price, c.date
from sku_costs c where c.active;

drop view if exists order_totals;
create view order_totals
with (security_invoker = on) as
select
  o.id as order_id,
  sum(case when l.sample then 0
           else (coalesce(l.ship_kg, l.kg) - l.ret_kg) * l.price end)::numeric(12,2) as goods,
  (case when o.ship_mode = 'client' then o.delivery else 0 end)::numeric(12,2)       as delivery_client,
  (case when o.ship_mode = 'us'     then o.delivery else 0 end)::numeric(12,2)       as delivery_cost,
  sum(coalesce(l.ship_kg, l.kg) - l.ret_kg)::numeric(12,2)                           as net_kg,
  sum(coalesce(l.ship_cones, l.cones) - l.ret_cones)                                 as net_cones,
  coalesce((select sum(p.amount) from payments p where p.order_id = o.id), 0)::numeric(12,2) as paid
from orders o
left join order_lines l on l.order_id = o.id
group by o.id;


-- =====================================================================
-- Лишається відкритим (потребує зміни застосунку, не самого SQL):
--
--   ops.price для приходу читає будь-хто з доступом, отже менеджер і
--   комірник можуть дістати ціну закупівлі прямим запитом до API.
--   Так само комірник читає skus.sale і order_lines.price.
--   В інтерфейсі ціни сховані, але на рівні бази — ні.
--   Лікується підміною таблиць на представлення з масками по ролі;
--   разом із цим доведеться правити запити в застосунку.
-- =====================================================================
