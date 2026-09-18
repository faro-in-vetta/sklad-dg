-- =====================================================================
-- DG FILATI · склад — очищення бази перед реальним наповненням
--
-- Лишає ЛИШЕ чотири активні профілі (removed = false) і їхні акаунти входу.
-- Видаляє: усі SKU, ціни, рух товару, заявки, оплати, повернення,
-- журнали, запрошення, а також усі вимкнені (тестові) профілі.
--
-- ЦЕ НЕЗВОРОТНО. Відновити видалене не вийде.
-- Запускати у SQL Editor проєкту sklad-dg.
-- =====================================================================


-- ---------------------------------------------------------------------
-- КРОК 1. Спершу подивитися, що буде видалено. Нічого не змінює.
-- Запустіть окремо цей блок і звірте цифри.
-- ---------------------------------------------------------------------
select 'SKU'                as "що",  count(*) as "буде видалено" from skus
union all select 'ціни закупівлі',    count(*) from sku_costs
union all select 'рух товару',        count(*) from ops
union all select 'заявки',            count(*) from orders
union all select 'позиції заявок',    count(*) from order_lines
union all select 'оплати',            count(*) from payments
union all select 'повернення',        count(*) from returns
union all select 'події заявок',      count(*) from order_events
union all select 'журнал карток',     count(*) from audit
union all select 'запрошення',        count(*) from invites
union all select 'вимкнені профілі',  count(*) from profiles where removed;

-- і хто лишиться:
select name as "лишається", role as "роль", email as "логін"
  from profiles where not removed order by role::text;


-- ---------------------------------------------------------------------
-- КРОК 2. Саме очищення. Запускати після того, як звірили КРОК 1.
-- ---------------------------------------------------------------------
begin;

-- запобіжник: якщо активних профілів не рівно 4 — нічого не робимо
do $$
declare n integer;
begin
  select count(*) into n from profiles where not removed;
  if n <> 4 then
    raise exception 'Активних профілів %, очікувалося 4. Очищення скасовано.', n;
  end if;
end $$;

-- документи й рух (у порядку залежностей)
delete from order_events;
delete from payments;
delete from return_lines;
delete from returns;
delete from order_lines;
delete from orders;
delete from ops;
delete from audit;

-- каталог
delete from sku_costs;
delete from skus;

-- незакриті запрошення (службові рядки механізму створення доступів)
delete from invites;

-- вимкнені профілі разом з їхніми акаунтами входу.
-- profiles зникнуть каскадом слідом за auth.users.
delete from auth.users u
 where exists (select 1 from profiles p where p.id = u.id and p.removed);

commit;


-- ---------------------------------------------------------------------
-- КРОК 3. Перевірка після очищення.
-- ---------------------------------------------------------------------
select 'SKU' as "що", count(*) as "лишилось" from skus
union all select 'рух товару', count(*) from ops
union all select 'заявки',     count(*) from orders
union all select 'профілі',    count(*) from profiles;

select name as "людина", role as "роль", email as "логін",
       last_seen as "останній вхід"
  from profiles order by role::text;
