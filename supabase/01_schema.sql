-- =====================================================================
-- DG FILATI · Складський облік пряжі
-- Крок 1: схема бази (таблиці, типи, індекси, представлення, функції)
-- Запускати в SQL Editor проєкту sklad-dg.
-- Правила доступу (RLS) — окремим файлом 02_rls.sql ПІСЛЯ цього.
-- =====================================================================

create extension if not exists "pgcrypto";

-- ---------- типи ----------
do $$ begin
  create type user_role as enum ('admin','accountant','storekeeper','manager');
exception when duplicate_object then null; end $$;

do $$ begin
  -- in  = прихід, out = продаж, smp = пробники, adj = коригування залишків,
  -- ret = повернення, wrt = списання (брак/втрата/усадка/пересорт)
  create type op_type as enum ('in','out','smp','adj','ret','wrt');
exception when duplicate_object then null; end $$;

do $$ begin
  create type order_status as enum ('active','shipped','cancelled');
exception when duplicate_object then null; end $$;

do $$ begin
  create type pay_terms as enum ('prepay','deferred','sample');
exception when duplicate_object then null; end $$;

do $$ begin
  create type ship_mode as enum ('us','client');
exception when duplicate_object then null; end $$;

-- ---------- люди ----------
create table if not exists profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  email       text not null,
  name        text not null,
  role        user_role not null default 'manager',
  removed     boolean not null default false,
  removed_at  timestamptz,
  last_seen   timestamptz,
  created_at  timestamptz not null default now()
);
comment on table profiles is 'Користувачі складу; id збігається з auth.users';

create table if not exists invites (
  id          uuid primary key default gen_random_uuid(),
  email       text not null,
  name        text,
  role        user_role not null default 'manager',
  token       text not null unique default encode(gen_random_bytes(16),'hex'),
  created_by  uuid references profiles(id),
  created_at  timestamptz not null default now(),
  accepted_at timestamptz
);
create unique index if not exists invites_email_open_idx
  on invites (lower(email)) where accepted_at is null;

-- ---------- каталог ----------
create table if not exists skus (
  id          uuid primary key default gen_random_uuid(),
  maker       text not null,
  art         text not null,
  color       text,
  hex         text,
  meter       text,                       -- Nm як текст: "2/28"
  code        text not null,              -- штрихкод
  comp        jsonb not null default '[]'::jsonb,  -- [{"f":"WV Merino","p":70}]
  sale        numeric(12,2) not null default 0,    -- прайсова ціна продажу
  note        text,
  photos      text[] not null default '{}',        -- шляхи у Storage
  deleted     boolean not null default false,
  deleted_at  timestamptz,
  deleted_by  uuid references profiles(id),
  created_by  uuid references profiles(id),
  created_at  timestamptz not null default now()
);
create unique index if not exists skus_code_live_idx on skus (code) where not deleted;
create index if not exists skus_search_idx on skus using gin (
  to_tsvector('simple', coalesce(maker,'')||' '||coalesce(art,'')||' '||coalesce(color,'')||' '||coalesce(code,''))
);

-- ціни закупівлі: список по датах, одна активна
create table if not exists sku_costs (
  id          uuid primary key default gen_random_uuid(),
  sku_id      uuid not null references skus(id) on delete cascade,
  price       numeric(12,2) not null check (price > 0),
  date        date not null,
  active      boolean not null default false,
  created_by  uuid references profiles(id),
  created_at  timestamptz not null default now()
);
create index if not exists sku_costs_sku_idx on sku_costs (sku_id, date desc);
create unique index if not exists sku_costs_one_active_idx on sku_costs (sku_id) where active;

-- ---------- заявки ----------
create table if not exists orders (
  id            uuid primary key default gen_random_uuid(),
  yy            smallint not null,        -- 26 → рік 2026
  no            integer  not null,        -- 1..n у межах року
  client        text not null,
  sample        boolean not null default false,   -- усі позиції пробники
  terms         pay_terms not null default 'prepay',
  days          integer not null default 0,
  comment       text,
  ship_mode     ship_mode not null default 'us',
  delivery      numeric(12,2) not null default 0, -- розрахунок перевізника
  carrier_name  text,
  boxes         integer not null default 0,
  box_kg        numeric(10,2) not null default 0,
  status        order_status not null default 'active',
  created_by    uuid references profiles(id),
  created_at    timestamptz not null default now(),
  pick_at       timestamptz, pick_by     uuid references profiles(id),
  picked_at     timestamptz, picked_by   uuid references profiles(id),
  approved_at   timestamptz, approved_by uuid references profiles(id),
  paid          boolean not null default false,
  paid_at       timestamptz,
  due           date,
  shipped_at    timestamptz, shipped_by  uuid references profiles(id),
  cancelled_at  timestamptz, cancelled_by uuid references profiles(id),
  cancel_reason text,
  unique (yy, no)
);
create index if not exists orders_status_idx on orders (status, created_at desc);
create index if not exists orders_client_idx on orders (lower(client));

create table if not exists order_lines (
  id          uuid primary key default gen_random_uuid(),
  order_id    uuid not null references orders(id) on delete cascade,
  pos         integer not null,
  sku_id      uuid not null references skus(id),
  kg          numeric(12,2) not null check (kg >= 0),
  cones       integer not null default 0 check (cones >= 0),
  price       numeric(12,2) not null default 0,
  sample      boolean not null default false,
  ship_kg     numeric(12,2),
  ship_cones  integer,
  ret_kg      numeric(12,2) not null default 0,
  ret_cones   integer not null default 0,
  unique (order_id, pos)
);
create index if not exists order_lines_sku_idx on order_lines (sku_id);

create table if not exists payments (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references orders(id) on delete cascade,
  amount     numeric(12,2) not null check (amount > 0),
  paid_on    date not null,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists payments_order_idx on payments (order_id);

create table if not exists returns (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references orders(id) on delete cascade,
  returned_on date not null,
  reason     text,
  amount     numeric(12,2) not null default 0,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create table if not exists return_lines (
  id         uuid primary key default gen_random_uuid(),
  return_id  uuid not null references returns(id) on delete cascade,
  sku_id     uuid not null references skus(id),
  kg         numeric(12,2) not null default 0,
  cones      integer not null default 0
);

create table if not exists order_events (
  id         uuid primary key default gen_random_uuid(),
  order_id   uuid not null references orders(id) on delete cascade,
  text       text not null,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists order_events_order_idx on order_events (order_id, created_at);

-- ---------- рух товару ----------
create table if not exists ops (
  id         uuid primary key default gen_random_uuid(),
  sku_id     uuid not null references skus(id),
  type       op_type not null,
  kg         numeric(12,2) not null,
  cones      integer not null default 0,
  price      numeric(12,2) not null default 0,
  party      text,                       -- клієнт або постачальник
  comment    text,
  reason     text,                       -- для wrt: брак / втрата / усадка / пересорт
  sample     boolean not null default false,
  partial    boolean not null default false,
  order_id   uuid references orders(id) on delete set null,
  happened_on date not null,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists ops_sku_idx on ops (sku_id, happened_on desc);
create index if not exists ops_date_idx on ops (happened_on desc);

-- ---------- журнал змін карток ----------
create table if not exists audit (
  id         uuid primary key default gen_random_uuid(),
  sku_id     uuid references skus(id) on delete cascade,
  act        text not null,              -- create | edit | price | delete
  text       text not null,
  created_by uuid references profiles(id),
  created_at timestamptz not null default now()
);
create index if not exists audit_sku_idx on audit (sku_id, created_at desc);

-- =====================================================================
-- Представлення
-- =====================================================================

-- залишки: на складі / у резерві / вільно
create or replace view sku_levels as
select
  s.id as sku_id,
  coalesce(o.kg, 0)::numeric(12,2)  as stock_kg,
  coalesce(o.cones, 0)              as stock_cones,
  coalesce(r.kg, 0)::numeric(12,2)  as reserved_kg,
  coalesce(r.cones, 0)              as reserved_cones,
  (coalesce(o.kg,0) - coalesce(r.kg,0))::numeric(12,2) as free_kg,
  (coalesce(o.cones,0) - coalesce(r.cones,0))          as free_cones,
  c.price as cost_price
from skus s
left join (
  select sku_id,
         sum(case when type in ('out','smp','wrt') then -kg   else kg   end) as kg,
         sum(case when type in ('out','smp','wrt') then -cones else cones end) as cones
  from ops group by sku_id
) o on o.sku_id = s.id
left join (
  select l.sku_id,
         sum(l.kg)    as kg,
         sum(l.cones) as cones
  from order_lines l
  join orders ord on ord.id = l.order_id and ord.status = 'active'
  group by l.sku_id
) r on r.sku_id = s.id
left join sku_costs c on c.sku_id = s.id and c.active
where not s.deleted;

-- суми по заявці
create or replace view order_totals as
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
join order_lines l on l.order_id = o.id
group by o.id;

-- =====================================================================
-- Функції
-- =====================================================================

-- наскрізний номер заявки з річною нумерацією: 26/0000001
create or replace function next_order_no(p_yy smallint)
returns integer language sql security definer set search_path = public as $$
  select coalesce(max(no), 0) + 1 from orders where yy = p_yy;
$$;

-- активна ціна закупівлі: нова ціна з найпізнішою датою стає активною
create or replace function set_active_cost() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update sku_costs set active = false where sku_id = new.sku_id;
  update sku_costs c set active = true
   where c.id = (select id from sku_costs where sku_id = new.sku_id order by date desc, created_at desc limit 1);
  return new;
end $$;

drop trigger if exists sku_costs_activate on sku_costs;
create trigger sku_costs_activate
after insert or delete on sku_costs
for each row execute function set_active_cost();

-- профіль створюється автоматично при реєстрації за запрошенням
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
declare inv invites%rowtype;
begin
  select * into inv from invites
   where lower(email) = lower(new.email) and accepted_at is null
   order by created_at desc limit 1;

  insert into profiles (id, email, name, role)
  values (new.id, new.email,
          coalesce(inv.name, split_part(new.email,'@',1)),
          coalesce(inv.role, 'manager'));

  if inv.id is not null then
    update invites set accepted_at = now() where id = inv.id;
  end if;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function handle_new_user();

-- відмітка присутності («хто в базі зараз»)
create or replace function touch_presence() returns void
language sql security definer set search_path = public as $$
  update profiles set last_seen = now() where id = auth.uid();
$$;
