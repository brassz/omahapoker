// Notifica admins via Expo Push quando um jogador cruza lucro alto.
// Também pode ser chamada manualmente: POST { userId, displayName?, profit? }
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

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return json({ error: 'POST only' }, 405);

  try {
    const body = await req.json().catch(() => ({}));
    const userId = String(body.userId || body.user_id || '');
    if (!userId) return json({ error: 'userId obrigatório' }, 400);

    const admin = createClient(
      Deno.env.get('SUPABASE_URL') || '',
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '',
      { auth: { persistSession: false } }
    );

    let profit = Number(body.profit);
    let displayName = String(body.displayName || body.display_name || '');

    if (!Number.isFinite(profit) || !displayName) {
      const { data: check } = await admin.rpc('check_player_profit_alerts', {
        p_user_id: userId,
      });
      // Recalcula para mensagem
      const { data: list } = await admin.rpc('admin_list_player_profits');
      const row = Array.isArray(list)
        ? list.find((r: { user_id: string }) => r.user_id === userId)
        : null;
      if (row) {
        profit = Number(row.profit);
        displayName = row.display_name || row.email || 'Jogador';
      }
      if (!Number.isFinite(profit)) profit = Number(check?.profit) || 0;
    }

    const { data: tokens, error: tokErr } = await admin
      .from('admin_push_tokens')
      .select('expo_push_token');
    if (tokErr) throw tokErr;

    const messages = (tokens || [])
      .map((t: { expo_push_token: string }) => t.expo_push_token)
      .filter(Boolean)
      .map((to: string) => ({
        to,
        title: 'Lucro alto',
        body: `${displayName || 'Jogador'} está com lucro de R$ ${Number(profit).toFixed(2)}`,
        sound: 'default',
        data: { type: 'profit_alert', userId, profit },
      }));

    if (!messages.length) {
      return json({ ok: true, sent: 0, reason: 'no_tokens' });
    }

    const res = await fetch('https://exp.host/--/api/v2/push/send', {
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(messages),
    });
    const expo = await res.json().catch(() => null);

    return json({ ok: true, sent: messages.length, expo });
  } catch (e) {
    return json({ error: e?.message || String(e) }, 500);
  }
});
