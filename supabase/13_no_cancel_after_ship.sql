-- =====================================================================
-- DG FILATI · Складський облік пряжі
-- Крок 13: відвантажену заявку анулювати не можна
--
-- Виконувати ПІСЛЯ 12_storekeeper_audit.sql. Файл можна виконувати повторно.
--
-- Товар уже в дорозі до клієнта, тож «анулювати» означало б безслідно
-- стерти продаж. Чесний шлях назад один — повернення: воно заводить
-- кілограми на склад окремим рухом і лишає слід у грошах.
-- =====================================================================

create or replace function guard_no_cancel_shipped() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if old.status = 'shipped' and new.status = 'cancelled' then
    raise exception 'Відвантажену заявку не анулюють — оформіть повернення';
  end if;
  return new;
end $$;

drop trigger if exists orders_no_cancel_shipped on orders;
create trigger orders_no_cancel_shipped
before update of status on orders
for each row
when (old.status = 'shipped' and new.status = 'cancelled')
execute function guard_no_cancel_shipped();


-- перевірка
select tgname, tgenabled
  from pg_trigger
 where tgrelid = 'orders'::regclass and not tgisinternal
 order by tgname;
