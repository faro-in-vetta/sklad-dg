// DG FILATI · склад — створення доступу співробітнику
// Edge Function: invite-user
//
// Пошта не використовується. Адмін задає логін і пароль, передає їх людині сам.
// Supabase Auth вимагає email, тому логін перетворюється на службову адресу
// вигляду <логін>@sklad.faroinvetta.com. Листи на неї ніколи не йдуть.
//
// Режими:
//   { mode:'create',   login, name, role, password }
//   { mode:'password', user_id, password }
//   { mode:'login',    user_id, login }

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.58.0'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const ROLES = ['admin', 'accountant', 'storekeeper', 'manager']
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
    if (!me || me.removed || !['admin', 'accountant'].includes(me.role))
      return reply({ error: 'Доступи створює лише адмін або головний бухгалтер' }, 403)

    const body = await req.json().catch(() => ({}))
    const mode = String(body.mode || 'create')

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

    const bad = badLogin(login)
    if (bad) return reply({ error: bad }, 400)
    if (!ROLES.includes(role)) return reply({ error: 'Невідома роль' }, 400)
    if (password.length < 8) return reply({ error: 'Пароль — щонайменше 8 символів' }, 400)

    const email = mailOf(login)

    const { data: exists } = await admin
      .from('profiles').select('id, removed').eq('email', email).maybeSingle()
    if (exists) return reply({ error: exists.removed ? 'Такий логін уже був і вимкнений' : 'Такий логін уже зайнятий' }, 409)

    // рядок invites — звідси тригер handle_new_user візьме ім'я й роль
    const { data: open } = await admin
      .from('invites').select('id').eq('email', email).is('accepted_at', null).maybeSingle()

    let inviteId = open?.id
    if (inviteId) {
      await admin.from('invites').update({ name, role, created_by: user.id }).eq('id', inviteId)
    } else {
      const { data, error } = await admin
        .from('invites').insert({ email, name, role, created_by: user.id }).select('id').single()
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

    return reply({ ok: true, user_id: created.user?.id, login, name, role })
  } catch (e) {
    return reply({ error: String((e as Error)?.message || e) }, 500)
  }
})
