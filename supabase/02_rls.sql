-- =====================================================================
-- DG FILATI · Складський облік пряжі
-- Крок 2: правила доступу (RLS)
-- Запускати ПІСЛЯ 01_schema.sql у тому самому проєкті.
--
-- Ролі:
--   admin, accountant — усе: ціни, дозволи, оплати, доставка, видалення SKU
--   storekeeper       — SKU без цін, прихід, коригування, списання, збірка, відвантаження
--   manager           — заявки, пробники, дебіторка; бачить лише ціну продажу
-- =====================================================================

-- ---------- допоміжні функції ----------
create or replace function my_role() returns user_role
language sql stable security definer set search_path = public as $$
  select role from profiles where id = auth.uid() and not removed;
$$;

create or replace function is_fin() returns boolean
language sql stable security definer set search_path = public as $$
  select my_role() in ('admin','accountant');
$$;

create or replace function is_store() returns boolean
language sql stable security definer set search_path = public as $$
  select my_role() in ('admin','accountant','storekeeper');
$$;

create or replace function is_sales() returns boolean
language sql stable security definer set search_path = public as $$
  select my_role() in ('admin','accountant','manager');
$$;

create or replace function is_member() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from profiles where id = auth.uid() and not removed);
$$;

-- ---------- вмикаємо RLS ----------
alter table profiles      enable row level security;
alter table invites       enable row level security;
alter table skus          enable row level security;
alter table sku_costs     enable row level security;
alter table orders        enable row level security;
alter table order_lines   enable row level security;
alter table payments      enable row level security;
alter table returns       enable row level security;
alter table return_lines  enable row level security;
alter table order_events  enable row level security;
alter table ops           enable row level security;
alter table audit         enable row level security;

-- ---------- profiles ----------
drop policy if exists profiles_read on profiles;
create policy profiles_read on profiles for select using (is_member());

drop policy if exists profiles_self on profiles;
create policy profiles_self on profiles for update
  using (id = auth.uid()) with check (id = auth.uid() and role = my_role());

drop policy if exists profiles_admin on profiles;
create policy profiles_admin on profiles for all using (is_fin()) with check (is_fin());

-- ---------- invites: лише адмін і бухгалтер ----------
drop policy if exists invites_fin on invites;
create policy invites_fin on invites for all using (is_fin()) with check (is_fin());

-- ---------- каталог SKU ----------
drop policy if exists skus_read on skus;
create policy skus_read on skus for select using (is_member());

drop policy if exists skus_write on skus;
create policy skus_write on skus for insert with check (is_store());

drop policy if exists skus_update on skus;
create policy skus_update on skus for update using (is_store()) with check (is_store());
-- Примітка: колонку sale (ціна продажу) захищає тригер нижче — комірник її не змінить.

drop policy if exists skus_delete on skus;
create policy skus_delete on skus for delete using (is_fin());

-- ---------- ціни закупівлі: лише адмін і бухгалтер, і читання теж ----------
drop policy if exists costs_fin on sku_costs;
create policy costs_fin on sku_costs for all using (is_fin()) with check (is_fin());

-- ---------- рух товару ----------
drop policy if exists ops_read on ops;
create policy ops_read on ops for select using (is_member());

drop policy if exists ops_insert on ops;
create policy ops_insert on ops for insert with check (
  is_member() and (
    (type in ('in','adj','wrt') and is_store()) or      -- склад
    (type in ('out','smp','ret') and is_member())       -- через заявки
  )
);
-- рух не редагується й не видаляється: помилки виправляються коригуванням
drop policy if exists ops_no_update on ops;
drop policy if exists ops_no_delete on ops;

-- ---------- заявки ----------
drop policy if exists orders_read on orders;
create policy orders_read on orders for select using (is_member());

drop policy if exists orders_create on orders;
create policy orders_create on orders for insert with check (is_sales() or is_store());

drop policy if exists orders_update on orders;
create policy orders_update on orders for update using (
  is_fin()                                                        -- усе
  or (is_store() and status = 'active')                           -- збірка, відвантаження
  or (created_by = auth.uid() and status = 'active'               -- автор, поки не в роботі
      and pick_at is null and approved_at is null)
) with check (
  is_fin()
  or (is_store() and status in ('active','shipped'))
  or (created_by = auth.uid() and status = 'active')
);

drop policy if exists orders_delete on orders;
create policy orders_delete on orders for delete using (false);  -- не видаляємо, лише анулюємо

drop policy if exists lines_read on order_lines;
create policy lines_read on order_lines for select using (is_member());

drop policy if exists lines_write on order_lines;
create policy lines_write on order_lines for all using (
  exists (select 1 from orders o where o.id = order_id and (
    is_fin() or (is_store() and o.status='active')
    or (o.created_by = auth.uid() and o.status='active' and o.pick_at is null)))
) with check (
  exists (select 1 from orders o where o.id = order_id and (
    is_fin() or (is_store() and o.status='active')
    or (o.created_by = auth.uid() and o.status='active' and o.pick_at is null)))
);

-- ---------- гроші: лише адмін і бухгалтер ----------
drop policy if exists payments_read on payments;
create policy payments_read on payments for select using (is_sales());

drop policy if exists payments_write on payments;
create policy payments_write on payments for all using (is_fin()) with check (is_fin());

drop policy if exists returns_read on returns;
create policy returns_read on returns for select using (is_member());
drop policy if exists returns_write on returns;
create policy returns_write on returns for all using (is_fin()) with check (is_fin());

drop policy if exists rlines_read on return_lines;
create policy rlines_read on return_lines for select using (is_member());
drop policy if exists rlines_write on return_lines;
create policy rlines_write on return_lines for all using (is_fin()) with check (is_fin());

-- ---------- історія ----------
drop policy if exists events_read on order_events;
create policy events_read on order_events for select using (is_member());
drop policy if exists events_write on order_events;
create policy events_write on order_events for insert with check (is_member());

drop policy if exists audit_read on audit;
create policy audit_read on audit for select using (is_member());
drop policy if exists audit_write on audit;
create policy audit_write on audit for insert with check (is_member());

-- =====================================================================
-- Захист цін на рівні колонок
-- =====================================================================

-- комірник не може змінювати прайсову ціну продажу
create or replace function guard_sku_sale() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not is_fin() and new.sale is distinct from old.sale then
    raise exception 'Ціну продажу змінює лише адмін або головний бухгалтер';
  end if;
  return new;
end $$;

drop trigger if exists skus_guard_sale on skus;
create trigger skus_guard_sale before update on skus
for each row execute function guard_sku_sale();

-- ціна в операції приходу: вносить лише адмін або бухгалтер
create or replace function guard_op_price() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.type = 'in' and not is_fin() and coalesce(new.price,0) <> 0 then
    raise exception 'Ціну закупівлі вносить лише адмін або головний бухгалтер';
  end if;
  new.created_by := auth.uid();
  return new;
end $$;

drop trigger if exists ops_guard_price on ops;
create trigger ops_guard_price before insert on ops
for each row execute function guard_op_price();

-- =====================================================================
-- Перевірка (запустити під різними користувачами після наповнення даними)
-- =====================================================================
-- select my_role();                       -- має повернути роль
-- select * from sku_costs limit 1;        -- для комірника: 0 рядків
-- insert into ops(sku_id,type,kg,price,happened_on) values (…,'in',10,14.5,current_date);
--   для комірника з ціною → помилка, без ціни → ок
