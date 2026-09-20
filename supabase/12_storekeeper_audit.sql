-- =====================================================================
-- DG FILATI · Складський облік пряжі
-- Крок 12: комірник не читає журнал змін карток
--
-- Виконувати ПІСЛЯ 11_client_guards.sql. Файл можна виконувати повторно.
--
-- В інтерфейсі історія комірникові вже не показується. Тут закриваємо її
-- і на рівні бази — принаймні ту частину, яку можна закрити без наслідків.
--
-- Чому не всю: залишки в каталозі рахуються з таблиці ops, і комірник сам
-- же туди й пише (прихід, коригування, відвантаження). Відрізати йому ops
-- означало б залишити склад без цифр. Тож рух товару лишається читаним —
-- це його власна робота, — а журнал змін карток закривається повністю.
-- =====================================================================

do $$
declare p record;
begin
  for p in select policyname from pg_policies
            where schemaname = 'public' and tablename = 'audit' and cmd = 'SELECT'
  loop
    execute format('drop policy %I on audit', p.policyname);
  end loop;
end $$;

create policy audit_select on audit for select
  using (is_member() and not is_client() and my_role() <> 'storekeeper');


-- перевірка
select policyname, qual
  from pg_policies
 where schemaname='public' and tablename='audit' and cmd='SELECT';
