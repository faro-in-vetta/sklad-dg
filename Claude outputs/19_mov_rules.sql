-- =====================================================================
-- DG FILATI · Складський облік пряжі
-- Крок 19: правила для переміщення між складами
--
-- Виконувати ПІСЛЯ 18_mov_enum.sql — окремо від нього, бо нові значення
-- типу можна використати лише в новій транзакції.
-- Файл можна виконувати повторно.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. Хто може проводити переміщення: ті самі, хто веде склад
-- ---------------------------------------------------------------------
drop policy if exists ops_insert on ops;
create policy ops_insert on ops for insert with check (
  is_member() and (
    (type in ('in','adj','wrt','mov_out','mov_in') and is_store())   -- склад
    or (type in ('out','smp','ret') and is_member())                 -- через заявки
  )
);


-- ---------------------------------------------------------------------
-- 2. Рух товару читається лише по «своїх» складах
--    (доповнюємо правило з кроку 11: клієнтові ops закриті повністю)
-- ---------------------------------------------------------------------
do $$
declare p record;
begin
  for p in select policyname from pg_policies
            where schemaname = 'public' and tablename = 'ops' and cmd = 'SELECT'
  loop
    execute format('drop policy %I on ops', p.policyname);
  end loop;
end $$;

create policy ops_select on ops for select using (
  is_member() and not is_client()
  and exists (select 1 from skus s where s.id = ops.sku_id and sees_site(s.site))
);


-- ---------------------------------------------------------------------
-- 3. Перевірка
-- ---------------------------------------------------------------------
select policyname, cmd, qual, with_check
  from pg_policies where schemaname='public' and tablename='ops' order by cmd, policyname;
