// DG FILATI · склад — створення доступу співробітнику
// Edge Function: invite-user
//
// Пошта не використовується. Адмін задає логін і пароль, передає їх людині сам.
// Supabase Auth вимагає email, тому логін перетворюється на службову адресу
// вигляду <логін>@sklad.faroinvetta.com. Листи на неї ніколи не йдуть.
//
// Режими:
//   { mode:'create',   login, name, role, password, client }
//   { mode:'password', user_id, password }
//   { mode:'login',    user_id, login }
//   { mode:'remove',   user_id }
//   { mode:'debug',     on }                 — перемикач режиму налагодження
//   { mode:'purge_order', order_id }         — видалити заявку назавжди
//   { mode:'purge_sku',   sku_id }           — видалити SKU назавжди
//   { mode:'purge_user',  user_id }          — видалити акаунт назавжди
//
// Видалення назавжди робить лише адмін. Поки ввімкнений режим налагодження —
// будь-що; після вимкнення — лише те, за чим не стоїть рух товару чи гроші.
//
// Видалення не стирає профіль: ім'я лишається в історії складу, а логін
// звільняється — службова адреса перейменовується, і той самий логін можна
// віддати новій людині.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.58.0'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const ROLES = ['admin', 'accountant', 'storekeeper', 'manager', 'client']
const DOMAIN = 'sklad.faroinvetta.com'

const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  })

const cleanLogin = (v: unknown) => String(v ?? '').trim().toLowerCase()
const mailOf = (login: string) => login.includes('@') ? login : `${login}@${DOMAIN}`

function badLogin(login: string) {
  if (login.includes('@')) return null                       // повна адреса — приймаємо як є
  if (!/^[a-z0-9][a-z0-9._-]{2,31}$/.test(login))
    return 'Логін: 3–32 символи, латиниця, цифри, крапка, дефіс або підкреслення'
  return null
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'POST') return reply({ error: 'Тільки POST' }, 405)

  try {
    const URL_ = Deno.env.get('SUPABASE_URL')!
    const ANON = Deno.env.get('SUPABASE_ANON_KEY')!
    const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    const authHeader = req.headers.get('Authorization') || ''
    const asUser = createClient(URL_, ANON, { global: { headers: { Authorization: authHeader } } })
    const { data: { user } } = await asUser.auth.getUser()
    if (!user) return reply({ error: 'Не авторизовано' }, 401)

    const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } })
    const { data: me } = await admin
      .from('profiles').select('role, removed').eq('id', user.id).single()
    // Доступи роздає тільки адмін. У головного бухгалтера повні робочі
    // права, але ключ від системи — окремо і в одних руках; список людей
    // він бачить, змінювати не може.
    if (!me || me.removed || me.role !== 'admin')
      return reply({ error: 'Створювати й вимикати доступи може лише адмін' }, 403)

    const body = await req.json().catch(() => ({}))
    const mode = String(body.mode || 'create')

    const isAdmin = me.role === 'admin'
    const debugOn = async () => {
      const { data } = await admin.from('app_settings').select('value').eq('key', 'debug_mode').maybeSingle()
      return data?.value === true
    }

    // ---------- перемикач режиму налагодження ----------
    if (mode === 'debug') {
      if (!isAdmin) return reply({ error: 'Режим налагодження перемикає лише адмін' }, 403)
      const on = body.on === true
      const { error } = await admin.from('app_settings')
        .upsert({ key: 'debug_mode', value: on, updated_at: new Date().toISOString(), updated_by: user.id })
      if (error) return reply({ error: error.message }, 400)
      return reply({ ok: true, debug: on })
    }

    // ---------- видалити заявку назавжди ----------
    if (mode === 'purge_order') {
      if (!isAdmin) return reply({ error: 'Видаляє назавжди лише адмін' }, 403)
      const id = String(body.order_id || '')
      if (!id) return reply({ error: 'Не вказано заявку' }, 400)

      const { data: o } = await admin
        .from('orders').select('id, status, pick_at').eq('id', id).single()
      if (!o) return reply({ error: 'Такої заявки немає' }, 404)

      const dbg = await debugOn()
      const { count: opsCount } = await admin
        .from('ops').select('id', { count: 'exact', head: true }).eq('order_id', id)

      if (!dbg) {
        if ((opsCount ?? 0) > 0)
          return reply({ error: 'По заявці був рух товару — її можна лише анулювати, не видалити' }, 400)
        if (!(o.status === 'cancelled' || (o.status === 'active' && !o.pick_at)))
          return reply({ error: 'Видалити можна лише анульовану або ще не взяту в збірку заявку' }, 400)
      }

      if ((opsCount ?? 0) > 0) await admin.from('ops').delete().eq('order_id', id)
      const { error } = await admin.from('orders').delete().eq('id', id)   // рядки, оплати, повернення й події підуть каскадом
      if (error) return reply({ error: error.message }, 400)
      return reply({ ok: true })
    }

    // ---------- видалити SKU назавжди ----------
    if (mode === 'purge_sku') {
      if (!isAdmin) return reply({ error: 'Видаляє назавжди лише адмін' }, 403)
      const id = String(body.sku_id || '')
      if (!id) return reply({ error: 'Не вказано SKU' }, 400)

      const dbg = await debugOn()
      const { count: opsCount } = await admin
        .from('ops').select('id', { count: 'exact', head: true }).eq('sku_id', id)
      const { count: lineCount } = await admin
        .from('order_lines').select('id', { count: 'exact', head: true }).eq('sku_id', id)

      if (!dbg && ((opsCount ?? 0) > 0 || (lineCount ?? 0) > 0))
        return reply({ error: 'По цьому SKU є рух або заявки — картку можна лише прибрати з каталогу' }, 400)

      if ((lineCount ?? 0) > 0) await admin.from('order_lines').delete().eq('sku_id', id)
      if ((opsCount ?? 0) > 0)  await admin.from('ops').delete().eq('sku_id', id)
      await admin.from('sku_costs').delete().eq('sku_id', id)
      await admin.from('audit').delete().eq('sku_id', id)
      const { error } = await admin.from('skus').delete().eq('id', id)
      if (error) return reply({ error: error.message }, 400)
      return reply({ ok: true })
    }

    // ---------- видалити акаунт назавжди ----------
    if (mode === 'purge_user') {
      if (!isAdmin) return reply({ error: 'Видаляє назавжди лише адмін' }, 403)
      const uid = String(body.user_id || '')
      if (!uid) return reply({ error: 'Не вказано користувача' }, 400)
      if (uid === user.id) return reply({ error: 'Себе видалити не можна' }, 400)

      const dbg = await debugOn()

      // де на людину лишилися посилання
      const traces: Array<[string, string]> = [
        ['ops', 'created_by'], ['orders', 'created_by'], ['skus', 'created_by'],
        ['audit', 'created_by'], ['payments', 'created_by'], ['order_events', 'created_by'],
      ]
      let used = 0
      for (const [t, c] of traces) {
        const { count } = await admin.from(t).select('id', { count: 'exact', head: true }).eq(c, uid)
        used += count ?? 0
      }

      if (!dbg && used > 0)
        return reply({ error: 'За цією людиною є записи в історії — доступ можна лише вимкнути' }, 400)

      if (used > 0) {
        // прибираємо підпис, щоб записи не тримали профіль
        for (const [t, c] of traces) await admin.from(t).update({ [c]: null }).eq(c, uid)
        for (const c of ['pick_by', 'picked_by', 'approved_by', 'shipped_by', 'cancelled_by'])
          await admin.from('orders').update({ [c]: null }).eq(c, uid)
        await admin.from('skus').update({ deleted_by: null }).eq('deleted_by', uid)
        await admin.from('sku_costs').update({ created_by: null }).eq('created_by', uid)
        await admin.from('returns').update({ created_by: null }).eq('created_by', uid)
        await admin.from('invites').update({ created_by: null }).eq('created_by', uid)
      }

      const { error } = await admin.auth.admin.deleteUser(uid)   // профіль зникне каскадом
      if (error) return reply({ error: error.message }, 400)
      return reply({ ok: true })
    }

    // ---------- зміна пароля ----------
    if (mode === 'password') {
      const uid = String(body.user_id || '')
      const password = String(body.password || '')
      if (!uid) return reply({ error: 'Не вказано користувача' }, 400)
      if (password.length < 8) return reply({ error: 'Пароль — щонайменше 8 символів' }, 400)

      const { error } = await admin.auth.admin.updateUserById(uid, { password })
      if (error) return reply({ error: error.message }, 400)
      return reply({ ok: true })
    }

    // ---------- вимкнення доступу зі звільненням логіна ----------
    if (mode === 'remove') {
      const uid = String(body.user_id || '')
      if (!uid) return reply({ error: 'Не вказано користувача' }, 400)
      if (uid === user.id) return reply({ error: 'Себе вимкнути не можна' }, 400)

      const { data: target } = await admin
        .from('profiles').select('id, email, role, removed').eq('id', uid).single()
      if (!target) return reply({ error: 'Такого користувача немає' }, 404)
      if (target.removed) return reply({ ok: true })

      // має лишитися хоча б один адмін, інакше систему нікому буде відкрити
      if (target.role === 'admin') {
        const { count } = await admin
          .from('profiles').select('id', { count: 'exact', head: true })
          .eq('role', 'admin').eq('removed', false)
        if ((count ?? 0) <= 1) return reply({ error: 'Має лишитися хоча б один адмін' }, 400)
      }

      // звільняємо логін: службову адресу відводимо вбік, у профілі лишаємо як було
      const tag = Date.now().toString(36) + Math.random().toString(36).slice(2, 6)
      const freed = `freed-${tag}@${DOMAIN}`
      const { error: eMail } = await admin.auth.admin.updateUserById(uid, {
        email: freed, email_confirm: true,
        password: crypto.randomUUID() + crypto.randomUUID(),   // старий пароль більше не діє
      })
      if (eMail) return reply({ error: 'Не вдалося звільнити логін: ' + eMail.message }, 400)

      const { error: eProf } = await admin.from('profiles')
        .update({ removed: true, removed_at: new Date().toISOString() }).eq('id', uid)
      if (eProf) return reply({ error: eProf.message }, 400)

      return reply({ ok: true })
    }

    // ---------- зміна логіна ----------
    if (mode === 'login') {
      const uid = String(body.user_id || '')
      const login = cleanLogin(body.login)
      const bad = badLogin(login)
      if (!uid) return reply({ error: 'Не вказано користувача' }, 400)
      if (bad) return reply({ error: bad }, 400)

      const email = mailOf(login)
      const { error } = await admin.auth.admin.updateUserById(uid, { email, email_confirm: true })
      if (error) {
        if (/already been registered|already exists/i.test(error.message))
          return reply({ error: 'Такий логін уже зайнятий' }, 409)
        return reply({ error: error.message }, 400)
      }
      await admin.from('profiles').update({ email }).eq('id', uid)
      return reply({ ok: true, login, email })
    }

    // ---------- створення доступу ----------
    const login = cleanLogin(body.login)
    const name = String(body.name || '').trim() || login
    const role = String(body.role || 'manager')
    const password = String(body.password || '')
    // назва клієнта, до якої прив'язана роль «Клієнт»: за нею людина
    // бачить свої заявки й більше нічиї
    const client = String(body.client || '').trim().slice(0, 160)

    const bad = badLogin(login)
    if (bad) return reply({ error: bad }, 400)
    if (!ROLES.includes(role)) return reply({ error: 'Невідома роль' }, 400)
    if (role === 'client' && !client) return reply({ error: 'Для ролі «Клієнт» потрібна назва клієнта' }, 400)
    if (password.length < 8) return reply({ error: 'Пароль — щонайменше 8 символів' }, 400)

    const email = mailOf(login)

    // зайнятим логін вважається лише поки людина працює; у вимкнених
    // профілях адреса лишається для історії, але доступ уже звільнений
    const { data: exists } = await admin
      .from('profiles').select('id').eq('email', email).eq('removed', false).maybeSingle()
    if (exists) return reply({ error: 'Такий логін уже зайнятий' }, 409)

    // рядок invites — звідси тригер handle_new_user візьме ім'я й роль
    const { data: open } = await admin
      .from('invites').select('id').eq('email', email).is('accepted_at', null).maybeSingle()

    let inviteId = open?.id
    if (inviteId) {
      await admin.from('invites').update({ name, role, client: client || null, created_by: user.id }).eq('id', inviteId)
    } else {
      const { data, error } = await admin
        .from('invites').insert({ email, name, role, client: client || null, created_by: user.id }).select('id').single()
      if (error) return reply({ error: 'Не вдалося підготувати доступ: ' + error.message }, 500)
      inviteId = data.id
    }

    const { data: created, error: cErr } = await admin.auth.admin.createUser({
      email, password, email_confirm: true,
    })

    if (cErr) {
      await admin.from('invites').delete().eq('id', inviteId)   // прибираємо за собою
      if (/already been registered|already exists/i.test(cErr.message))
        return reply({ error: 'Такий логін уже зайнятий' }, 409)
      return reply({ error: cErr.message }, 400)
    }

    // тригер handle_new_user бере ім'я, роль і прив'язку з рядка invites;
    // дублюємо запис явно, щоб профіль був заповнений навіть якщо тригер
    // колись змінять
    if (created.user?.id) {
      await admin.from('profiles')
        .update({ role, name, client: client || null })
        .eq('id', created.user.id)
    }

    return reply({ ok: true, user_id: created.user?.id, login, name, role, client })
  } catch (e) {
    return reply({ error: String((e as Error)?.message || e) }, 500)
  }
})
