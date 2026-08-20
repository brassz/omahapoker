import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import {
  json,
  corsHeaders,
  verifyWebhook,
  paymentIdOf,
  payoutIdOf,
} from '../_shared/cajupay.ts';

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

  const raw = await req.text();
  const sig = req.headers.get('X-CajuPay-Signature') || req.headers.get('x-cajupay-signature') || '';
  const ok = await verifyWebhook(raw, sig);
  if (!ok) return json({ error: 'invalid_signature' }, 401);

  let event;
  try { event = JSON.parse(raw); } catch (_) {
    return json({ error: 'invalid_json' }, 400);
  }

  const type = String(event.type || event.event || '').toLowerCase();
  const obj = event.data?.object || event.data || event.object || {};
  const admin = serviceClient();

  try {
    if (type.includes('pix.payment.paid') || (type.includes('pix') && String(obj.status || '').toLowerCase() === 'paid')) {
      const id = paymentIdOf(obj);
      if (id) await admin.rpc('credit_paid_deposit', { p_payment_id: id });
    } else if (type.includes('pix.payment.failed') || type.includes('pix.payment.expired')) {
      const id = paymentIdOf(obj);
      if (id) await admin.rpc('fail_deposit', { p_payment_id: id });
    } else if (type.includes('payout.paid')) {
      const id = payoutIdOf(obj);
      if (id) await admin.rpc('complete_payout', { p_payout_id: id });
    } else if (type.includes('payout.failed') || type.includes('payout.cancelled')) {
      const id = payoutIdOf(obj);
      if (id) {
        await admin.rpc('fail_payout', {
          p_payout_id: id,
          p_note: obj.last_error || obj.cancel_message || 'Falha no PIX automático. Saldo devolvido.',
        });
      }
    }
  } catch (err) {
    return json({ error: err?.message || 'handler_error' }, 500);
  }

  return json({ ok: true });
});
