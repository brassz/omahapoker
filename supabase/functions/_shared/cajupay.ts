export const CAJU_API = 'https://api.cajupay.com.br';

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers':
    'authorization, x-client-info, apikey, content-type, x-cajupay-signature',
  'Access-Control-Allow-Methods': 'POST, GET, OPTIONS',
};

export function json(data, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

export function cajuKeys() {
  return {
    key: (Deno.env.get('CAJUPAY_API_KEY') || '').trim(),
    secret: (Deno.env.get('CAJUPAY_API_SECRET') || '').trim(),
  };
}

export function cajuKeysOk() {
  const { key, secret } = cajuKeys();
  if (!key || !secret) return false;
  if (key.includes('...') || secret.includes('...')) return false;
  return key.startsWith('gpk_') && secret.startsWith('gsk_') && key.length > 12 && secret.length > 20;
}

export function cajuHeaders(idempotencyKey) {
  const { key, secret } = cajuKeys();
  const headers = {
    'Content-Type': 'application/json',
    'X-API-Key': key,
    'X-API-Secret': secret,
  };
  if (idempotencyKey) headers['Idempotency-Key'] = idempotencyKey;
  return headers;
}

export async function cajuFetch(path, { method = 'GET', body, idempotencyKey } = {}) {
  const res = await fetch(`${CAJU_API}${path}`, {
    method,
    headers: cajuHeaders(idempotencyKey),
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch (_) { data = { raw: text }; }
  return { ok: res.ok, status: res.status, data };
}

export function detectPixKey(raw) {
  const key = String(raw || '').trim();
  const digits = key.replace(/\D/g, '');
  if (key.includes('@')) {
    return { pix_key: key.toLowerCase(), pix_key_type: 'email' };
  }
  if (/^\d{11}$/.test(digits) && !/[a-zA-Z]/.test(key.replace(/[.\-\s]/g, ''))) {
    return { pix_key: digits, pix_key_type: 'cpf' };
  }
  if (/^\d{14}$/.test(digits)) {
    return { pix_key: digits, pix_key_type: 'cnpj' };
  }
  if (digits.length >= 10 && digits.length <= 13) {
    const e164 = digits.startsWith('55') ? `+${digits}` : `+55${digits}`;
    return { pix_key: e164, pix_key_type: 'phone' };
  }
  return { pix_key: key, pix_key_type: 'evp' };
}

export function paymentIdOf(obj = {}) {
  return obj.cajupay_payment_id || obj.payment_id || obj.id || '';
}

export function payoutIdOf(obj = {}) {
  return obj.cajupay_payout_id || obj.payout_id || obj.id || '';
}

/** Taxa fixa de saque PIX (centavos). Padrão R$ 4,50. Ajuste via CAJUPAY_PAYOUT_FEE_CENTS. */
export function payoutFeeCents() {
  const raw = Number(Deno.env.get('CAJUPAY_PAYOUT_FEE_CENTS') || '450');
  return Number.isFinite(raw) && raw >= 0 ? Math.round(raw) : 450;
}

/** Valor bruto enviado à CajuPay para o jogador receber `netCents` líquidos na chave PIX. */
export function grossPayoutCents(netCents) {
  const net = Math.max(0, Math.round(Number(netCents) || 0));
  return net + payoutFeeCents();
}

export async function hmacHex(secret, message) {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(message));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, '0')).join('');
}

export function timingSafeEqual(a, b) {
  if (typeof a !== 'string' || typeof b !== 'string' || a.length !== b.length) return false;
  let out = 0;
  for (let i = 0; i < a.length; i++) out |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return out === 0;
}

export async function verifyWebhook(rawBody, signatureHeader) {
  const secret = Deno.env.get('CAJUPAY_WEBHOOK_SECRET') || '';
  if (!secret) return false;
  const hdr = String(signatureHeader || '');
  const parts = Object.fromEntries(
    hdr.split(',').map((p) => {
      const [k, ...rest] = p.trim().split('=');
      return [k, rest.join('=')];
    }),
  );
  const ts = parts.t || '';
  const sig = parts.v1 || '';
  if (!ts || !sig) return false;
  const age = Math.abs(Date.now() / 1000 - Number(ts));
  if (Number.isFinite(age) && age > 600) return false;
  const expected = await hmacHex(secret, `${ts}.${rawBody}`);
  if (timingSafeEqual(expected, sig)) return true;
  const stripped = secret.replace(/^cwhsec_/, '');
  if (stripped !== secret) {
    const alt = await hmacHex(stripped, `${ts}.${rawBody}`);
    if (timingSafeEqual(alt, sig)) return true;
  }
  return false;
}

export async function ensureWebhookRegistered() {
  const url = `${Deno.env.get('SUPABASE_URL')}/functions/v1/cajupay-webhook`;
  try {
    await cajuFetch('/api/webhooks/endpoints/register', {
      method: 'POST',
      body: {
        url,
        description: 'CLUBEDEJOGOSCAIPIRA',
        event_types: ['pix.payment.*', 'payout.*'],
      },
    });
  } catch (_) {}
}
