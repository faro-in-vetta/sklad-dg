-- =====================================================================
-- DG FILATI · Складський облік пряжі
-- Крок 20: ВІДКАТ поділу на склади (запасний файл)
--
-- Виконувати ЛИШЕ якщо після 17–19 щось читається не так, як треба.
-- Файл можна виконувати повторно.
--
-- Що робить: повертає правила читання до стану «склад не враховується»
-- (як було до кроку 17) і знімає перевірку складу в позиціях заявки.
-- Клієнтське обмеження (кожен бачить лише свої заявки) ЛИШАЄТЬСЯ.
--
-- Чого НЕ робить: не видаляє колонки site і sites і не чіпає дані.
-- Тому нічого не втрачається — після відкату можна спокійно розібратися
-- й виконати 17 ще раз.
--
-- Після відкату застосунок теж треба повернути на попередню версію:
-- backup/index-2026-09-26-before-sites.html
-- =====================================================================

do $$
declare p record;
begin
  for p in select tablename, policyname from pg_policies
            where schemaname = 'public'
              and tablename in ('skus','orders','order_lines','payments','returns','order_events','ops')
              and cmd = 'SELECT'
  loop
    execute format('drop policy %I on %I', p.policyname, p.tablename);
  end loop;
end $$;

-- каталог і рух — як було
create policy skus_select on skus for select using (is_member());
create policy ops_select  on ops  for select using (is_member() and not is_client());

-- заявки — як після кроку 10 (тільки клієнтське обмеження)
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

-- запис — як було
drop policy if exists skus_write on skus;
create policy skus_write on skus for insert with check (is_store());

drop policy if exists skus_update on skus;
create policy skus_update on skus for update using (is_store()) with check (is_store());

drop policy if exists orders_create on orders;
create policy orders_create on orders for insert with check (is_sales() or is_store());

-- позиція заявки більше не звіряється зі складом
drop trigger if exists order_lines_site_guard on order_lines;

-- перевірка
select tablename, policyname, cmd from pg_policies
 where schemaname='public'
   and tablename in ('skus','orders','order_lines','payments','returns','order_events','ops')
 order by tablename, cmd, policyname;
