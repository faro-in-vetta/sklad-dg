-- =====================================================================
-- DG FILATI · Складський облік пряжі
-- Крок 11: клієнт не бачить рух товару; ціну продажу в заявці
--          міняє лише адмін або головний бухгалтер
--
-- Виконувати ПІСЛЯ 10_client_rules.sql. Файл можна виконувати повторно.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Залишок підсумком — без жодного рядка історії
--    Рух товару містить назви інших клієнтів, постачальників і
--    закупівельні ціни, тож клієнтові таблиця ops закрита (нижче).
--    Але залишок у каталозі йому потрібен, тому віддаємо дві цифри на SKU.
-- ---------------------------------------------------------------------
drop view if exists sku_stock;
create view sku_stock as
  select s.id as sku_id,
         coalesce(sum(case when o.type in ('out','smp') then -o.kg    else coalesce(o.kg,0)    end), 0)::numeric as kg,
         coalesce(sum(case when o.type in ('out','smp') then -o.cones else coalesce(o.cones,0) end), 0)::numeric as cones,
         coalesce(sum(case when o.type = 'in' then coalesce(o.kg,0)    else 0 end), 0)::numeric as in_kg,
         coalesce(sum(case when o.type = 'in' then coalesce(o.cones,0) else 0 end), 0)::numeric as in_cones
    from skus s
    left join ops o on o.sku_id = s.id
   where is_member()
   group by s.id;

-- навмисно НЕ security_invoker: подання має порахувати по всіх рухах,
-- зокрема тих, які самому клієнтові читати не можна. Назв, сторін і цін тут немає.
alter view sku_stock set (security_invoker = off);
grant select on sku_stock to authenticated;


-- ---------------------------------------------------------------------
-- 2. Рух товару, журнал змін і закупівельні ціни — не для клієнта
--    Як і з заявками: прибираємо всі чинні правила читання й ставимо одне,
--    щоб старіше не лишилося чинним паралельно.
-- ---------------------------------------------------------------------
do $$
declare p record;
begin
  for p in select tablename, policyname from pg_policies
            where schemaname = 'public'
              and tablename in ('ops','audit','sku_costs')
              and cmd = 'SELECT'
  loop
    execute format('drop policy %I on %I', p.policyname, p.tablename);
  end loop;
end $$;

create policy ops_select       on ops       for select using (is_member() and not is_client());
create policy audit_select     on audit     for select using (is_member() and not is_client());
create policy sku_costs_select on sku_costs for select using (is_member() and not is_client());


-- ---------------------------------------------------------------------
-- 3. Ціна продажу в заявці
--    Менеджер і клієнт беруть її з картки товару. Інакше знижку можна
--    поставити собі самому — а для клієнта це просто поле з ціною.
--    Не піднімаємо помилку, а мовчки підставляємо ціну з картки:
--    так старі заявки редагуються без сюрпризів.
-- ---------------------------------------------------------------------
create or replace function guard_line_price() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not is_fin() and not coalesce(new.sample, false) then
    new.price := coalesce((select sale from skus where id = new.sku_id), 0);
  end if;
  return new;
end $$;

drop trigger if exists order_lines_price_guard on order_lines;
create trigger order_lines_price_guard
before insert or update of price, sku_id, sample on order_lines
for each row execute function guard_line_price();


-- ---------------------------------------------------------------------
-- 4. Перевірка
-- ---------------------------------------------------------------------
select tablename, policyname
  from pg_policies
 where schemaname='public' and tablename in ('ops','audit','sku_costs') and cmd='SELECT'
 order by tablename;

select count(*) as позицій_у_поданні_залишків from sku_stock;
