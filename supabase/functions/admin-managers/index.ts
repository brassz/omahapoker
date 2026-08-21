// Cria gerente (auth.admin) + ativa is_manager / referral_code.
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

    const { data: isAdmin, error: admErr } = await userSb.rpc('is_admin');
    if (admErr) throw admErr;
    if (!isAdmin) return json({ error: 'Apenas administradores' }, 403);

    const body = await req.json().catch(() => ({}));
    const email = String(body.email || '').trim().toLowerCase();
    const password = String(body.password || '');
    const displayName = String(body.displayName || body.display_name || '').trim()
      || (email ? email.split('@')[0] : 'Gerente');
    const phone = String(body.phone || '').replace(/\D/g, '');

    if (!email || !email.includes('@')) return json({ error: 'E-mail inválido' }, 400);
    if (password.length < 6) return json({ error: 'Senha mínima: 6 caracteres' }, 400);

    const admin = serviceClient();
    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,
      user_metadata: {
        display_name: displayName,
        phone: phone || null,
        role: 'manager',
      },
    });

    if (createErr) {
      const msg = createErr.message || 'Falha ao criar usuário';
      if (/already|registered|exists/i.test(msg)) {
        return json({
          error: 'E-mail já cadastrado. Use "Promover" na lista de jogadores ou no painel de gerentes.',
        }, 409);
      }
      return json({ error: msg }, 400);
    }

    const userId = created.user?.id;
    if (!userId) return json({ error: 'Usuário criado sem id' }, 500);

    // Garante perfil (trigger pode ter rodado)
    await admin.from('profiles').upsert({
      id: userId,
      email,
      display_name: displayName,
      phone: phone || null,
      player_credits: 0,
      bank_credits: 0,
      is_admin: false,
      is_manager: false,
    }, { onConflict: 'id' });

    const { data: setup, error: setupErr } = await admin.rpc('admin_finish_manager_setup', {
      p_user_id: userId,
    });
    if (setupErr) throw setupErr;

    return json({ ok: true, manager: setup });
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    return json({ error: message || 'Erro interno' }, 500);
  }
});
