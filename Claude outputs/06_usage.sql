-- =====================================================================
-- DG FILATI · склад — скільки зайнято місця
--
-- Дає застосунку два числа: скільки важать фото у сховищі й скільки
-- займає сама база. Ліміти зберігаються поруч, у app_settings, —
-- при переході на інший тариф достатньо змінити там цифри.
--
-- Запускати у SQL Editor після 05_debug.sql.
-- =====================================================================

-- ліміти тарифу (Free: 1 ГБ сховища, 500 МБ бази)
insert into app_settings (key, value) values
  ('storage_limit_mb', '1024'::jsonb),
  ('db_limit_mb',      '500'::jsonb)
on conflict (key) do nothing;

-- скільки зайнято. Дивитися можуть лише адмін і головний бухгалтер:
-- комірнику й менеджеру ця цифра ні до чого.
create or replace function usage_stats()
returns table (storage_bytes bigint, storage_files bigint, db_bytes bigint)
language plpgsql security definer set search_path = public as $$
begin
  if not is_fin() then
    raise exception 'Доступно лише адміну або головному бухгалтеру';
  end if;

  return query
  select
    coalesce((select sum((o.metadata->>'size')::bigint) from storage.objects o
               where o.bucket_id = 'sku-photos'), 0)::bigint,
    coalesce((select count(*) from storage.objects o
               where o.bucket_id = 'sku-photos'), 0)::bigint,
    pg_database_size(current_database())::bigint;
end $$;

revoke all on function usage_stats() from public;
grant execute on function usage_stats() to authenticated;

select * from usage_stats();
