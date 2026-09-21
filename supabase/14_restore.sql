-- =====================================================================
-- DG FILATI · Складський облік пряжі
-- Крок 14: відновлення з резервної копії
--
-- Виконувати ПІСЛЯ 13_no_cancel_after_ship.sql. Файл можна виконувати повторно.
--
-- Принцип: повертаємо лише те, чого в базі НЕМАЄ. Рядок, чий ключ уже є,
-- не чіпаємо — навіть якщо в копії він інший. Тому відновлення можна
-- запускати скільки завгодно разів: задвоєнь не буде, а все втрачене
-- повернеться. Якщо зникло все — повернеться все.
--
-- Застосунок викликає функцію таблиця за таблицею, порціями по кількасот
-- рядків, у правильному порядку (спершу картки, потім заявки, потім рух).
-- Кожна порція — окрема транзакція: або вся лягає, або жодна.
-- =====================================================================

create or replace function restore_rows(p_table text, p_rows jsonb)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  allowed text[] := array['profiles','app_settings','invites','skus','sku_costs','orders','ops',
                          'order_lines','payments','returns','return_lines','order_events','audit'];
  pk      text := case when p_table = 'app_settings' then 'key' else 'id' end;
  cols    text;
  r       jsonb;
  ex      boolean;
  ins     int := 0;
  skip    int := 0;
  tries   int;
  notes   jsonb := '[]'::jsonb;
  errs    jsonb := '[]'::jsonb;
  cname   text;
  newno   int;
  newcode text;
begin
  if my_role() is distinct from 'admin' then
    raise exception 'Відновлювати дані може лише адмін';
  end if;
  if not (p_table = any(allowed)) then
    raise exception 'Невідома таблиця: %', p_table;
  end if;
  if to_regclass('public.' || p_table) is null then
    return jsonb_build_object('inserted',0,'skipped',0,
      'notes', jsonb_build_array('Таблиці ' || p_table || ' немає в базі'), 'errors','[]'::jsonb);
  end if;
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    return jsonb_build_object('inserted',0,'skipped',0,'notes','[]'::jsonb,'errors','[]'::jsonb);
  end if;

  -- Колонки — лише ті, що є і в копії, і в таблиці: схема могла змінитися
  -- після копії, і нова колонка тоді візьме своє значення за замовчуванням.
  select string_agg(quote_ident(a.attname), ',' order by a.attnum) into cols
    from pg_attribute a
   where a.attrelid = ('public.' || p_table)::regclass
     and a.attnum > 0 and not a.attisdropped and a.attgenerated = ''
     and exists (select 1 from jsonb_object_keys(p_rows->0) k where k = a.attname);

  -- Тригери вимикаємо на час вставки: вони для живої роботи, а не для
  -- повернення історії. Інакше, наприклад, перевірка вільного залишку не
  -- пустила б давно відвантажену позицію, а нумерація переписала б номер.
  -- Це все в одній транзакції: інші користувачі вимкнених тригерів не бачать,
  -- а якщо щось впаде — зміна скасується разом із вставкою.
  -- Зовнішні ключі при цьому діють, тож «сиріт» не буде.
  execute format('alter table %I disable trigger user', p_table);

  for r in select value from jsonb_array_elements(p_rows) loop
    execute format('select exists(select 1 from %I where %I::text = $1)', p_table, pk)
      into ex using r->>pk;
    if ex then skip := skip + 1; continue; end if;

    -- профіль прив'язаний до облікового запису входу; якщо того вже немає,
    -- профіль повернути неможливо — лише повідомляємо
    if p_table = 'profiles'
       and not exists (select 1 from auth.users u where u.id = (r->>'id')::uuid) then
      notes := notes || to_jsonb('Профіль «' || coalesce(r->>'name','?')
               || '» не відновлено: його обліковий запис видалено з системи входу');
      continue;
    end if;

    tries := 0;
    <<attempt>>
    loop
      tries := tries + 1;
      begin
        execute format('insert into %I (%s) select %s from jsonb_populate_record(null::%I, $1)',
                       p_table, cols, cols, p_table) using r;
        ins := ins + 1;
        exit attempt;
      exception
        when unique_violation then
          get stacked diagnostics cname = constraint_name;
          if tries > 3 then
            errs := errs || jsonb_build_object('id', r->>pk, 'error', sqlerrm);
            exit attempt;
          elsif p_table = 'orders' and cname = 'orders_yy_no_key' then
            -- номер уже віддали новій заявці — повертаємо стару під наступним вільним
            select coalesce(max(no),0) + 1 into newno from orders where yy = (r->>'yy')::int;
            notes := notes || to_jsonb(format(
              'Заявку %s/%s відновлено під номером %s/%s — старий номер уже зайнятий',
              r->>'yy', lpad(r->>'no',7,'0'), r->>'yy', lpad(newno::text,7,'0')));
            r := jsonb_set(r, '{no}', to_jsonb(newno));
          elsif p_table = 'skus' and cname = 'skus_code_live_idx' then
            -- штрихкод уже носить інша картка — даємо наступний вільний
            select 'DG' || lpad((coalesce(max(nullif(regexp_replace(code,'\D','','g'),'')::bigint),0) + 1)::text, 7, '0')
              into newcode from skus where code ~ '^DG[0-9]+$';
            notes := notes || to_jsonb(format(
              'SKU %s %s відновлено зі штрихкодом %s — %s уже зайнятий. Переклейте етикетку.',
              r->>'art', coalesce(r->>'color',''), newcode, r->>'code'));
            r := jsonb_set(r, '{code}', to_jsonb(newcode));
          elsif p_table = 'sku_costs' and cname = 'sku_costs_one_active_idx' then
            -- активна ціна в картки вже є — стару повертаємо в історію неактивною
            r := jsonb_set(r, '{active}', 'false'::jsonb);
          else
            errs := errs || jsonb_build_object('id', r->>pk, 'error', sqlerrm);
            exit attempt;
          end if;
        when others then
          errs := errs || jsonb_build_object('id', r->>pk, 'error', sqlerrm);
          exit attempt;
      end;
    end loop;
  end loop;

  execute format('alter table %I enable trigger user', p_table);

  return jsonb_build_object('inserted', ins, 'skipped', skip, 'notes', notes, 'errors', errs);
end $$;

revoke all on function restore_rows(text, jsonb) from public, anon;
grant execute on function restore_rows(text, jsonb) to authenticated;


-- перевірка: функція є
select proname, prosecdef as security_definer
  from pg_proc where proname = 'restore_rows';
