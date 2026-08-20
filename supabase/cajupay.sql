-- Depósitos PIX automáticos (CajuPay) + colunas de saque automático.
-- 1) Rode este SQL no Supabase (depois de withdrawals.sql).
-- 2) No terminal, na pasta do projeto:
--    npx supabase login
--    npx supabase link --project-ref zwtvqpnpuahcuhodroib
--    npx supabase secrets set CAJUPAY_API_KEY=gpk_... CAJUPAY_API_SECRET=gsk_... CAJUPAY_WEBHOOK_SECRET=cwhsec_...
--    npx supabase functions deploy cajupay --no-verify-jwt
--    npx supabase functions deploy cajupay-webhook --no-verify-jwt
-- 3) Webhook URL na CajuPay:
--    https://zwtvqpnpuahcuhodroib.supabase.co/functions/v1/cajupay-webhook
-- As chaves secretas NÃO devem ir no frontend.

create table if not exists public.deposits (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  amount numeric(14,2) not null check (amount >= 2),
  amount_cents integer not null check (amount_cents >= 200),
  payment_id text unique,
  pix_copy_paste text,
  pix_qr_code text,
  document text,
  status text not null default 'pending'
    check (status in ('pending', 'paid', 'failed', 'expired')),
  created_at timestamptz not null default now(),
  paid_at timestamptz
);

create index if not exists deposits_user_id_created_idx
  on public.deposits (user_id, created_at desc);

create index if not exists deposits_status_created_idx
  on public.deposits (status, created_at desc);

alter table public.deposits enable row level security;

drop policy if exists "deposits_select_own" on public.deposits;
create policy "deposits_select_own"
  on public.deposits for select
  to authenticated
  using (auth.uid() = user_id or public.is_admin());

revoke insert, update, delete on public.deposits from authenticated, anon;
grant select on public.deposits to authenticated;

alter table public.withdrawals
  add column if not exists payout_id text;

alter table public.withdrawals
  add column if not exists pix_key_type text;

alter table public.withdrawals
  add column if not exists document text;

create or replace function public.create_deposit(
  p_amount numeric,
  p_document text
)
returns public.deposits
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  cents integer;
  doc text;
  row public.deposits;
begin
  if uid is null then
    raise exception 'Faça login para depositar';
  end if;

  if p_amount is null or p_amount < 2 then
    raise exception 'Valor mínimo de depósito: 2';
  end if;
  if p_amount > 200 then
    raise exception 'Valor máximo de depósito: 200';
  end if;

  doc := regexp_replace(coalesce(p_document, ''), '\D', '', 'g');
  if length(doc) not in (11, 14) then
    raise exception 'Informe um CPF ou CNPJ válido';
  end if;

  cents := round(p_amount * 100)::integer;
  if cents < 200 then
    raise exception 'Valor mínimo de depósito: 2';
  end if;

  insert into public.deposits (user_id, amount, amount_cents, document, status)
  values (uid, p_amount, cents, doc, 'pending')
  returning * into row;

  return row;
end;
$$;

revoke all on function public.create_deposit(numeric, text) from public;
grant execute on function public.create_deposit(numeric, text) to authenticated;

create or replace function public.attach_deposit_pix(
  p_id uuid,
  p_payment_id text,
  p_pix_copy_paste text,
  p_pix_qr_code text
)
returns public.deposits
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  row public.deposits;
begin
  if uid is not null then
    update public.deposits
    set
      payment_id = p_payment_id,
      pix_copy_paste = p_pix_copy_paste,
      pix_qr_code = p_pix_qr_code
    where id = p_id
      and user_id = uid
      and status = 'pending'
      and payment_id is null
    returning * into row;
  else
    update public.deposits
    set
      payment_id = p_payment_id,
      pix_copy_paste = p_pix_copy_paste,
      pix_qr_code = p_pix_qr_code
    where id = p_id
      and status = 'pending'
      and payment_id is null
    returning * into row;
  end if;

  if row.id is null then
    raise exception 'Depósito não encontrado';
  end if;
  return row;
end;
$$;

revoke all on function public.attach_deposit_pix(uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.attach_deposit_pix(uuid, text, text, text) to service_role;

create or replace function public.list_my_deposits()
returns setof public.deposits
language sql
security definer
set search_path = public
as $$
  select *
  from public.deposits
  where user_id = auth.uid()
  order by created_at desc
  limit 20;
$$;

revoke all on function public.list_my_deposits() from public;
grant execute on function public.list_my_deposits() to authenticated;

-- Só service_role (Edge Function) credita saldo
create or replace function public.credit_paid_deposit(p_payment_id text)
returns public.deposits
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.deposits;
begin
  if coalesce(p_payment_id, '') = '' then
    raise exception 'payment_id vazio';
  end if;

  update public.deposits
  set status = 'paid', paid_at = now()
  where payment_id = p_payment_id
    and status = 'pending'
  returning * into row;

  if row.id is null then
    select * into row from public.deposits where payment_id = p_payment_id;
    return row;
  end if;

  update public.profiles
  set player_credits = player_credits + row.amount
  where id = row.user_id;

  return row;
end;
$$;

revoke all on function public.credit_paid_deposit(text) from public, anon, authenticated;
grant execute on function public.credit_paid_deposit(text) to service_role;

create or replace function public.fail_deposit(p_payment_id text)
returns public.deposits
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.deposits;
begin
  update public.deposits
  set status = 'failed'
  where payment_id = p_payment_id
    and status = 'pending'
  returning * into row;

  if row.id is null then
    select * into row from public.deposits where payment_id = p_payment_id;
  end if;
  return row;
end;
$$;

revoke all on function public.fail_deposit(text) from public, anon, authenticated;
grant execute on function public.fail_deposit(text) to service_role;

drop function if exists public.request_withdrawal(numeric, text);

create or replace function public.request_withdrawal(
  p_amount numeric,
  p_pix_key text,
  p_document text default null
)
returns public.withdrawals
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  bal numeric;
  row public.withdrawals;
  key text;
  doc text;
begin
  if uid is null then
    raise exception 'Faça login para solicitar saque';
  end if;

  key := trim(coalesce(p_pix_key, ''));
  if length(key) < 5 then
    raise exception 'Informe uma chave PIX válida';
  end if;

  if p_amount is null or p_amount < 2 then
    raise exception 'Valor mínimo de saque: 2';
  end if;

  doc := regexp_replace(coalesce(p_document, ''), '\D', '', 'g');
  if doc <> '' and length(doc) not in (11, 14) then
    raise exception 'Informe um CPF ou CNPJ válido do titular da chave';
  end if;
  if doc = '' then
    doc := null;
  end if;

  select player_credits into bal
  from public.profiles
  where id = uid
  for update;

  if not found then
    raise exception 'Perfil não encontrado';
  end if;

  if bal < p_amount then
    raise exception 'Saldo insuficiente';
  end if;

  if exists (
    select 1 from public.withdrawals
    where user_id = uid and status = 'pending'
  ) then
    raise exception 'Você já tem um saque pendente. Aguarde o pagamento.';
  end if;

  update public.profiles
  set player_credits = player_credits - p_amount
  where id = uid;

  insert into public.withdrawals (user_id, amount, pix_key, status, document)
  values (uid, p_amount, key, 'pending', doc)
  returning * into row;

  return row;
end;
$$;

revoke all on function public.request_withdrawal(numeric, text, text) from public;
grant execute on function public.request_withdrawal(numeric, text, text) to authenticated;

create or replace function public.attach_withdrawal_payout(p_id uuid, p_payout_id text, p_pix_key_type text)
returns public.withdrawals
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.withdrawals;
begin
  update public.withdrawals
  set payout_id = p_payout_id, pix_key_type = p_pix_key_type
  where id = p_id
    and status = 'pending'
  returning * into row;

  if row.id is null then
    raise exception 'Saque não encontrado';
  end if;
  return row;
end;
$$;

revoke all on function public.attach_withdrawal_payout(uuid, text, text) from public, anon, authenticated;
grant execute on function public.attach_withdrawal_payout(uuid, text, text) to service_role;

create or replace function public.complete_payout(p_payout_id text)
returns public.withdrawals
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.withdrawals;
begin
  update public.withdrawals
  set status = 'paid', processed_at = now(), admin_note = coalesce(admin_note, 'Pago automaticamente via CajuPay')
  where payout_id = p_payout_id
    and status = 'pending'
  returning * into row;

  if row.id is null then
    select * into row from public.withdrawals where payout_id = p_payout_id;
  end if;
  return row;
end;
$$;

revoke all on function public.complete_payout(text) from public, anon, authenticated;
grant execute on function public.complete_payout(text) to service_role;

create or replace function public.fail_payout(p_payout_id text, p_note text default null)
returns public.withdrawals
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.withdrawals;
begin
  select * into row
  from public.withdrawals
  where payout_id = p_payout_id
  for update;

  if row.id is null then
    return null;
  end if;

  if row.status <> 'pending' then
    return row;
  end if;

  update public.profiles
  set player_credits = player_credits + row.amount
  where id = row.user_id;

  update public.withdrawals
  set
    status = 'rejected',
    processed_at = now(),
    admin_note = coalesce(nullif(trim(p_note), ''), 'Falha no PIX automático. Saldo devolvido.')
  where id = row.id
  returning * into row;

  return row;
end;
$$;

revoke all on function public.fail_payout(text, text) from public, anon, authenticated;
grant execute on function public.fail_payout(text, text) to service_role;
