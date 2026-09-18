# Складський облік DG Filati

Застосунок складського обліку пряжі для Diamant Group Filati.
Фронтенд — один файл `app/index.html`, база — Supabase (проєкт `sklad-dg`, Frankfurt).

## Розгортання

1. GitHub Pages: гілка `main`, корінь репозиторію.
2. Домен: `sklad.faroinvetta.com` (файл `CNAME`), у Cloudflare запис CNAME на `<user>.github.io`, HTTPS примусовий.
3. У Supabase → Authentication → URL Configuration:
   - Site URL: `https://sklad.faroinvetta.com`
   - Redirect URLs: `https://sklad.faroinvetta.com/app/`

## База

SQL у теці `supabase/`, виконувати по порядку:

- `01_schema.sql` — таблиці, представлення `sku_levels` і `order_totals`, функції, тригери.
- `02_rls.sql` — ролі та правила доступу, захист цін на рівні колонок.

Сховище фото: bucket `sku-photos`, приватний, ліміт 2 MB, типи image/jpeg,image/png,image/webp.

## Ролі

| Роль | Доступ |
|---|---|
| admin | усе |
| accountant | усе: ціни, дозволи, оплати, доставка |
| storekeeper | SKU без цін, прихід, коригування, списання, збірка, відвантаження |
| manager | заявки, пробники, дебіторка; лише ціна продажу |

## Ключі

У `app/index.html` використовується публічний ключ Supabase (`sb_publishable_…`) — він призначений для браузера, доступ обмежують правила RLS. Ключ `service_role` у репозиторії не зберігається ніколи.
