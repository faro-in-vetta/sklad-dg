-- =====================================================================
-- DG FILATI · склад — хто саме вніс запис
--
-- Автор губився: застосунок не передавав його при записі, і в базі
-- лишався NULL. Тепер його передає застосунок, а база підставляє
-- автора сама — на випадок, якщо десь знову забудемо.
--
-- Запускати у SQL Editor. Наявні дані не чіпає.
-- =====================================================================

alter table orders        alter column created_by set default auth.uid();
alter table order_events  alter column created_by set default auth.uid();
alter table audit         alter column created_by set default auth.uid();
alter table payments      alter column created_by set default auth.uid();
alter table returns       alter column created_by set default auth.uid();
alter table sku_costs     alter column created_by set default auth.uid();
alter table skus          alter column created_by set default auth.uid();
alter table invites       alter column created_by set default auth.uid();

-- Заявки без автора не дають менеджеру редагувати власну заявку
-- (правило доступу звіряє created_by з тим, хто зайшов).
-- Показуємо, скільки таких лишилося з часів помилки.
select
  (select count(*) from orders       where created_by is null) as "заявки без автора",
  (select count(*) from order_events where created_by is null) as "події без автора",
  (select count(*) from audit        where created_by is null) as "журнал без автора",
  (select count(*) from payments     where created_by is null) as "оплати без автора";
