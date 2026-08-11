-- Saques PIX — solicitações do jogador + gestão no admin
-- Rode no Supabase SQL Editor

create table if not exists public.withdrawals (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  amount numeric(14,2) not null check (amount > 0),
  pix_key text not null,
  status text not null default 'pending'
    check (status in ('pending', 'paid', 'rejected')),
  created_at timestamptz not null default now(),
  processed_at timestamptz,
  admin_note text
);

create index if not exists withdrawals_status_created_idx
  on public.withdrawals (status, created_at desc);

create index if not exists withdrawals_user_id_created_idx
  on public.withdrawals (user_id, created_at desc);

alter table public.withdrawals enable row level security;

drop policy if exists "withdrawals_select_own" on public.withdrawals;
create policy "withdrawals_select_own"
  on public.withdrawals for select
  to authenticated
  using (auth.uid() = user_id or public.is_admin());

revoke insert, update, delete on public.withdrawals from authenticated, anon;
grant select on public.withdrawals to authenticated;

-- Jogador solicita saque: debita saldo e cria pedido pending
create or replace function public.request_withdrawal(
  p_amount numeric,
  p_pix_key text
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

  -- trava o perfil do jogador
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

  insert into public.withdrawals (user_id, amount, pix_key, status)
  values (uid, p_amount, key, 'pending')
  returning * into row;

  return row;
end;
$$;

revoke all on function public.request_withdrawal(numeric, text) from public;
grant execute on function public.request_withdrawal(numeric, text) to authenticated;

-- Lista saques do próprio jogador
create or replace function public.list_my_withdrawals()
returns setof public.withdrawals
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Não autenticado';
  end if;

  return query
  select w.*
  from public.withdrawals w
  where w.user_id = auth.uid()
  order by w.created_at desc
  limit 50;
end;
$$;

revoke all on function public.list_my_withdrawals() from public;
grant execute on function public.list_my_withdrawals() to authenticated;

-- Admin lista todos (com dados do jogador)
create or replace function public.admin_list_withdrawals()
returns table (
  id uuid,
  user_id uuid,
  amount numeric,
  pix_key text,
  status text,
  created_at timestamptz,
  processed_at timestamptz,
  admin_note text,
  display_name text,
  email text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores';
  end if;

  return query
  select
    w.id,
    w.user_id,
    w.amount,
    w.pix_key,
    w.status,
    w.created_at,
    w.processed_at,
    w.admin_note,
    p.display_name,
    p.email
  from public.withdrawals w
  join public.profiles p on p.id = w.user_id
  order by
    case when w.status = 'pending' then 0 else 1 end,
    w.created_at desc
  limit 200;
end;
$$;

revoke all on function public.admin_list_withdrawals() from public;
grant execute on function public.admin_list_withdrawals() to authenticated;

-- Admin marca como pago
create or replace function public.admin_mark_withdrawal_paid(p_id uuid)
returns public.withdrawals
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.withdrawals;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores';
  end if;

  update public.withdrawals
  set status = 'paid', processed_at = now()
  where id = p_id and status = 'pending'
  returning * into row;

  if row.id is null then
    raise exception 'Saque não encontrado ou já processado';
  end if;

  return row;
end;
$$;

revoke all on function public.admin_mark_withdrawal_paid(uuid) from public;
grant execute on function public.admin_mark_withdrawal_paid(uuid) to authenticated;

-- Admin rejeita e devolve o saldo
create or replace function public.admin_reject_withdrawal(p_id uuid, p_note text default null)
returns public.withdrawals
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.withdrawals;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores';
  end if;

  select * into row
  from public.withdrawals
  where id = p_id and status = 'pending'
  for update;

  if row.id is null then
    raise exception 'Saque não encontrado ou já processado';
  end if;

  update public.profiles
  set player_credits = player_credits + row.amount
  where id = row.user_id;

  update public.withdrawals
  set
    status = 'rejected',
    processed_at = now(),
    admin_note = nullif(trim(coalesce(p_note, '')), '')
  where id = p_id
  returning * into row;

  return row;
end;
$$;

revoke all on function public.admin_reject_withdrawal(uuid, text) from public;
grant execute on function public.admin_reject_withdrawal(uuid, text) to authenticated;
