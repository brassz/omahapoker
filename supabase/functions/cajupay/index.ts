import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  corsHeaders,
  json,
  cajuFetch,
  cajuKeysOk,
  detectPixKey,
  paymentIdOf,
  ensureWebhookRegistered,
} from '../_shared/cajupay.ts';

function rpcHint(msg) {
  const m = String(msg || '');
  if (/create_deposit|deposits|list_my_deposits|attach_deposit/i.test(m)) {
    return ' Rode o SQL supabase/cajupay.sql no Supabase.';
  }
  return '';
}

function cajuErr(data, status) {
  const parts = [
    data?.user_message,
    data?.message,
    data?.error,
    typeof data?.raw === 'string' ? data.raw.slice(0, 180) : '',
  ].filter(Boolean);
  const base = parts[0] || `CajuPay respondeu ${status || 'erro'}`;
  return base;
}

function fmtPhone(raw) {
  const digits = String(raw || '').replace(/\D/g, '');
  if (digits.length < 10) return '';
  return digits.startsWith('55') ? `+${digits}` : `+55${digits}`;
}

function userClient(req) {
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
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'method_not_allowed' }, 405);

  try {
    const body = await req.json().catch(() => ({}));
    const action = String(body.action || '');
    const userSb = userClient(req);
    const { data: userData, error: userErr } = await userSb.auth.getUser();
    if (userErr || !userData?.user) return json({ error: 'unauthorized' }, 401);

    if (action === 'create-pix') return await createPix(userSb, userData.user, body);
    if (action === 'check-pix') return await checkPix(body);
    if (action === 'payout') return await createPayout(userSb, userData.user, body);
    return json({ error: 'unknown_action' }, 400);
  } catch (err) {
    return json({ error: err?.message || 'server_error' }, 500);
  }
});

async function createPix(sb, user, body) {
  if (!cajuKeysOk()) {
    return json({
      error: 'Chaves CajuPay inválidas no Supabase. Configure CAJUPAY_API_KEY e CAJUPAY_API_SECRET (sem "...") nos secrets e faça deploy de novo.',
    }, 400);
  }

  const amount = Number(body.amount);
  const document = String(body.document || '').replace(/\D/g, '');
  if (!(amount >= 2 && amount <= 200)) return json({ error: 'Valor de depósito: 2 a 200.' }, 400);
  if (document.length !== 11 && document.length !== 14) {
    return json({ error: 'Informe um CPF ou CNPJ válido.' }, 400);
  }

  const { data: depRaw, error } = await sb.rpc('create_deposit', {
    p_amount: amount,
    p_document: document,
  });
  if (error) {
    return json({ error: error.message + rpcHint(error.message) }, 400);
  }
  const dep = Array.isArray(depRaw) ? depRaw[0] : depRaw;
  if (!dep?.id) return json({ error: 'Falha ao criar depósito' }, 500);

  const { data: profile } = await sb.from('profiles')
    .select('display_name,email,phone')
    .eq('id', user.id)
    .maybeSingle();
  const name = profile?.display_name || user.email?.split('@')[0] || 'Jogador';
  const phone = fmtPhone(body.phone || profile?.phone);
  if (!phone) {
    return json({ error: 'Informe um celular com DDD para gerar o PIX.' }, 400);
  }

  const checkoutUrl = String(body.checkout_url || Deno.env.get('CAJUPAY_CHECKOUT_URL') || '').trim()
    || 'http://localhost:8080/lobby.html';

  await ensureWebhookRegistered();

  const caju = await cajuFetch('/api/payments/pix', {
    method: 'POST',
    idempotencyKey: dep.id,
    body: {
      amount_cents: dep.amount_cents,
      currency: 'BRL',
      description: `Saldo CLUBEDEJOGOSCAIPIRA #${String(dep.id).slice(0, 8)}`,
      product_ref: String(dep.id),
      customer_ref: String(user.id),
      partner_checkout_url: checkoutUrl,
      consumer: {
        name,
        email: user.email || profile?.email || `player-${user.id.slice(0, 8)}@clubedejogos.caipira`,
        document,
        phone,
      },
    },
  });

  if (!caju.ok) {
    return json({
      error: cajuErr(caju.data, caju.status),
      detail: caju.data,
    }, 400);
  }

  const paymentId = paymentIdOf(caju.data);
  const pix = caju.data?.pix_copy_paste || caju.data?.emv || caju.data?.qr_code || '';
  const qr = caju.data?.pix_qr_code || caju.data?.qr_code_base64 || '';
  if (!paymentId || !pix) {
    return json({
      error: 'CajuPay não retornou payment_id ou código PIX.',
      detail: caju.data,
    }, 400);
  }

  const admin = serviceClient();
  const { error: attachErr } = await admin.rpc('attach_deposit_pix', {
    p_id: dep.id,
    p_payment_id: paymentId,
    p_pix_copy_paste: pix,
    p_pix_qr_code: qr,
  });
  if (attachErr) {
    return json({ error: attachErr.message + rpcHint(attachErr.message) }, 400);
  }

  return json({
    id: dep.id,
    payment_id: paymentId,
    amount: dep.amount,
    pix_copy_paste: pix,
    pix_qr_code: qr,
    status: 'pending',
  });
}

async function checkPix(body) {
  const paymentId = String(body.payment_id || '');
  if (!paymentId) return json({ error: 'payment_id obrigatório' }, 400);

  let caju = await cajuFetch(`/api/payments/${encodeURIComponent(paymentId)}`);
  let status = String(caju.data?.status || '').toLowerCase();
  if (!caju.ok || !status) {
    const list = await cajuFetch('/api/payments?limit=50');
    const items = Array.isArray(list.data) ? list.data : (list.data?.data || list.data?.payments || []);
    const found = items.find((p) => paymentIdOf(p) === paymentId);
    if (found) {
      caju = { ok: true, status: 200, data: found };
      status = String(found.status || '').toLowerCase();
    }
  }
  const admin = serviceClient();

  if (status === 'paid' || status === 'approved' || status === 'confirmed') {
    const { data } = await admin.rpc('credit_paid_deposit', { p_payment_id: paymentId });
    return json({ status: 'paid', deposit: data });
  }
  if (status === 'failed' || status === 'expired' || status === 'cancelled' || status === 'canceled') {
    await admin.rpc('fail_deposit', { p_payment_id: paymentId });
    return json({ status: 'failed' });
  }
  return json({ status: status || 'pending' });
}

async function createPayout(sb, user, body) {
  if (!cajuKeysOk()) {
    return json({
      error: 'Chaves CajuPay inválidas no Supabase. Configure os secrets e faça deploy de novo.',
    }, 400);
  }

  const withdrawalId = String(body.withdrawal_id || '');
  if (!withdrawalId) return json({ error: 'withdrawal_id obrigatório' }, 400);

  const { data: wd, error } = await sb
    .from('withdrawals')
    .select('*')
    .eq('id', withdrawalId)
    .eq('user_id', user.id)
    .maybeSingle();
  if (error || !wd) return json({ error: 'Saque não encontrado' }, 404);
  if (wd.status !== 'pending') return json({ error: 'Saque já processado', status: wd.status }, 400);

  const detected = detectPixKey(wd.pix_key);
  const cents = Math.round(Number(wd.amount) * 100);
  const payload = {
    amount_cents: cents,
    currency: 'BRL',
    wallet_kind: 'main',
    destination: { method: 'dict' },
    pix_key: detected.pix_key,
    pix_key_type: detected.pix_key_type,
  };
  if (['email', 'phone', 'evp'].includes(detected.pix_key_type)) {
    const doc = String(wd.document || '').replace(/\D/g, '');
    if (doc.length !== 11 && doc.length !== 14) {
      return json({ error: 'Para esta chave PIX informe o CPF/CNPJ do titular.' }, 400);
    }
    payload.key_owner_document = doc;
  }

  await ensureWebhookRegistered();

  const caju = await cajuFetch('/api/payouts', {
    method: 'POST',
    idempotencyKey: wd.id,
    body: payload,
  });

  if (!caju.ok) {
    return json({
      error: cajuErr(caju.data, caju.status),
      detail: caju.data,
    }, 400);
  }

  const payoutId = caju.data?.payout_id || caju.data?.cajupay_payout_id || caju.data?.id || '';
  const admin = serviceClient();
  await admin.rpc('attach_withdrawal_payout', {
    p_id: wd.id,
    p_payout_id: payoutId,
    p_pix_key_type: detected.pix_key_type,
  });

  const st = String(caju.data?.status || '').toLowerCase();
  if (st === 'paid' || st === 'completed' || st === 'success') {
    await admin.rpc('complete_payout', { p_payout_id: payoutId });
    return json({ status: 'paid', payout_id: payoutId });
  }

  return json({ status: 'pending', payout_id: payoutId });
}
