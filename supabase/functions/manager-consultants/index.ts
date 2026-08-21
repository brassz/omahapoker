// Cria consultor (auth.admin) sob o gerente autenticado + % de comissão.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' },
  });
}

function userClient(req: Request) {
  const auth = req.headers.get('Authorization') || '';
  return createClient(
    Deno.env.get('SUPABASE_URL') || '',
    Deno.env.get('SUPABASE_ANON_KEY') || '',
    { global: { headers: { Authorization: auth } }, auth: { persistSession: false } },
  );
}

function serviceClient() {
  return createClient(
    Deno.env.get('SUPABASE_URL') || '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '',
    { auth: { persistSession: false } },
  );
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);

  try {
    const userSb = userClient(req);
    const { data: userData, error: userErr } = await userSb.auth.getUser();
    if (userErr || !userData?.user) return json({ error: 'Não autenticado' }, 401);

    const { data: isMgr, error: mgrErr } = await userSb.rpc('is_manager');
    if (mgrErr) throw mgrErr;
    if (!isMgr) return json({ error: 'Apenas gerentes' }, 403);

    const { data: isAdm } = await userSb.rpc('is_admin');
    if (isAdm) return json({ error: 'Use o painel admin' }, 403);

    const body = await req.json().catch(() => ({}));
    const email = String(body.email || '').trim().toLowerCase();
    const password = String(body.password || '');
    const displayName = String(body.displayName || body.display_name || '').trim()
      || (email ? email.split('@')[0] : 'Consultor');
    const phone = String(body.phone || '').replace(/\D/g, '');
    const percent = Number(body.percent ?? body.commission_percent);

    if (!email || !email.includes('@')) return json({ error: 'E-mail inválido' }, 400);
    if (password.length < 6) return json({ error: 'Senha mínima: 6 caracteres' }, 400);
    if (!(percent > 0 && percent <= 100)) {
      return json({ error: 'Informe a porcentagem do consultor (maior que 0)' }, 400);
    }

    const admin = serviceClient();
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: {
        display_name: displayName,
        phone: phone || null,
        role: 'consultant',
      },
    });

    if (createErr) {
      const msg = createErr.message || 'Falha ao criar usuário';
      if (/already|registered|exists/i.test(msg)) {
        return json({
          error: 'E-mail já cadastrado. Promova o jogador existente no painel do gerente.',
        }, 409);
      }
      return json({ error: msg }, 400);
    }

    const userId = created.user?.id;
    if (!userId) return json({ error: 'Usuário criado sem id' }, 500);

    await admin.from('profiles').upsert({
      id: userId,
      email,
      display_name: displayName,
      phone: phone || null,
      player_credits: 0,
      bank_credits: 0,
      is_admin: false,
      is_manager: false,
      is_consultant: false,
    }, { onConflict: 'id' });

    const { data: setup, error: setupErr } = await admin.rpc('service_attach_consultant', {
      p_manager_id: userData.user.id,
      p_user_id: userId,
      p_percent: percent,
    });
    if (setupErr) throw setupErr;

    return json({ ok: true, consultant: setup });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return json({ error: message || 'Erro interno' }, 500);
  }
});
