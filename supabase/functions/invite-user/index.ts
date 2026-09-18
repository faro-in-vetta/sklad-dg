// DG FILATI · склад — запрошення користувача поштою
// Edge Function: invite-user
// Викликає лише адмін або головний бухгалтер. Створює рядок у invites
// і надсилає лист-запрошення; роль і ім'я підхопить тригер handle_new_user.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.58.0'

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const ROLES = ['admin', 'accountant', 'storekeeper', 'manager']

const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  })

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS })
  if (req.method !== 'POST') return reply({ error: 'Тільки POST' }, 405)

  try {
    const URL_ = Deno.env.get('SUPABASE_URL')!
    const ANON = Deno.env.get('SUPABASE_ANON_KEY')!
    const SERVICE = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
    const SITE = (Deno.env.get('SITE_URL') || '').replace(/\/+$/, '')

    // 1. Хто викликає
    const authHeader = req.headers.get('Authorization') || ''
    const asUser = createClient(URL_, ANON, { global: { headers: { Authorization: authHeader } } })
    const { data: { user } } = await asUser.auth.getUser()
    if (!user) return reply({ error: 'Не авторизовано' }, 401)

    const admin = createClient(URL_, SERVICE, { auth: { persistSession: false } })
    const { data: me } = await admin
      .from('profiles').select('role, removed').eq('id', user.id).single()

    if (!me || me.removed || !['admin', 'accountant'].includes(me.role))
      return reply({ error: 'Запрошення надсилає лише адмін або головний бухгалтер' }, 403)

    // 2. Що просять
    const body = await req.json().catch(() => ({}))
    const email = String(body.email || '').trim().toLowerCase()
    const name = String(body.name || '').trim() || null
    const role = String(body.role || 'manager')

    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(email)) return reply({ error: 'Некоректна пошта' }, 400)
    if (!ROLES.includes(role)) return reply({ error: 'Невідома роль' }, 400)

    // 3. Чи вже є такий користувач
    const { data: existing } = await admin
      .from('profiles').select('id, removed').eq('email', email).maybeSingle()
    if (existing && !existing.removed)
      return reply({ error: 'Такий користувач уже є' }, 409)

    // 4. Рядок запрошення (звідси тригер візьме ім'я й роль)
    const { data: open } = await admin
      .from('invites').select('id').eq('email', email).is('accepted_at', null).maybeSingle()

    let invite
    if (open) {
      const { data, error } = await admin
        .from('invites').update({ name, role, created_by: user.id })
        .eq('id', open.id).select().single()
      if (error) throw error
      invite = data
    } else {
      const { data, error } = await admin
        .from('invites').insert({ email, name, role, created_by: user.id }).select().single()
      if (error) throw error
      invite = data
    }

    // 5. Лист
    const { error: mailErr } = await admin.auth.admin.inviteUserByEmail(email, {
      redirectTo: SITE ? `${SITE}/app/` : undefined,
      data: { name, role },
    })

    if (mailErr) {
      const msg = String(mailErr.message || '')
      if (/already been registered|already registered/i.test(msg))
        return reply({ error: 'Ця пошта вже зареєстрована' }, 409)
      return reply({ error: 'Лист не надіслано: ' + msg }, 502)
    }

    return reply({ ok: true, invite_id: invite.id, email, role })
  } catch (e) {
    return reply({ error: String((e as Error)?.message || e) }, 500)
  }
})
