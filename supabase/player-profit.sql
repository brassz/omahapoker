-- Sistema de lucro do jogador + tokens Expo para alertas admin.
-- lucro = (créditos atuais + saques pagos) − depósitos pagos
-- Alerta ao cruzar R$ 600 (rearma se cair abaixo e subir de novo).
-- Rode no SQL Editor do Supabase.

create extension if not exists pg_net with schema extensions;

create table if not exists public.admin_push_tokens (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  expo_push_token text not null,
  updated_at timestamptz not null default now()
);

create table if not exists public.profit_alerts (
  id bigserial primary key,
  user_id uuid not null references public.profiles (id) on delete cascade,
  threshold numeric(14,2) not null default 600,
  profit_snapshot numeric(14,2) not null,
  triggered_at timestamptz not null default now(),
  active boolean not null default true,
  notified boolean not null default false
);

create index if not exists profit_alerts_user_active_idx
  on public.profit_alerts (user_id, active)
  where active = true;

alter table public.admin_push_tokens enable row level security;
alter table public.profit_alerts enable row level security;

drop policy if exists "admin_push_tokens_admin" on public.admin_push_tokens;
create policy "admin_push_tokens_admin"
  on public.admin_push_tokens for all
  to authenticated
  using (public.is_admin())
  with check (public.is_admin() and user_id = auth.uid());

drop policy if exists "profit_alerts_admin_select" on public.profit_alerts;
create policy "profit_alerts_admin_select"
  on public.profit_alerts for select
  to authenticated
  using (public.is_admin());

revoke all on public.admin_push_tokens from anon;
revoke all on public.profit_alerts from anon;
grant select, insert, update, delete on public.admin_push_tokens to authenticated;
grant select on public.profit_alerts to authenticated;
grant usage, select on sequence public.profit_alerts_id_seq to authenticated;

-- Lucro líquido de um jogador
create or replace function public.compute_player_profit(p_user_id uuid)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select
    coalesce((select player_credits from public.profiles where id = p_user_id), 0)
    + coalesce((
        select sum(amount) from public.withdrawals
        where user_id = p_user_id and status = 'paid'
      ), 0)
    - coalesce((
        select sum(amount) from public.deposits
        where user_id = p_user_id and status = 'paid'
      ), 0);
$$;

revoke all on function public.compute_player_profit(uuid) from public;
grant execute on function public.compute_player_profit(uuid) to authenticated;

create or replace function public.admin_register_push_token(p_token text)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Faça login';
  end if;
  if not public.is_admin() then
    raise exception 'Apenas admin';
  end if;
  if coalesce(trim(p_token), '') = '' then
    raise exception 'Token inválido';
  end if;

  insert into public.admin_push_tokens (user_id, expo_push_token, updated_at)
  values (auth.uid(), trim(p_token), now())
  on conflict (user_id) do update
  set expo_push_token = excluded.expo_push_token,
      updated_at = now();

  return json_build_object('ok', true);
end;
$$;

revoke all on function public.admin_register_push_token(text) from public;
grant execute on function public.admin_register_push_token(text) to authenticated;

create or replace function public.admin_list_player_profits()
returns table (
  user_id uuid,
  email text,
  display_name text,
  phone text,
  player_credits numeric,
  total_deposits numeric,
  total_withdrawals numeric,
  profit numeric,
  alert_active boolean
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Apenas admin';
  end if;

  return query
  select
    p.id,
    p.email,
    p.display_name,
    p.phone,
    p.player_credits,
    coalesce(d.total, 0)::numeric,
    coalesce(w.total, 0)::numeric,
    (
      p.player_credits
      + coalesce(w.total, 0)
      - coalesce(d.total, 0)
    )::numeric as profit,
    exists (
      select 1 from public.profit_alerts a
      where a.user_id = p.id and a.active = true
    ) as alert_active
  from public.profiles p
  left join lateral (
    select sum(x.amount) as total
    from public.deposits x
    where x.user_id = p.id and x.status = 'paid'
  ) d on true
  left join lateral (
    select sum(x.amount) as total
    from public.withdrawals x
    where x.user_id = p.id and x.status = 'paid'
  ) w on true
  where coalesce(p.is_admin, false) = false
  order by profit desc, p.display_name asc;
end;
$$;

revoke all on function public.admin_list_player_profits() from public;
grant execute on function public.admin_list_player_profits() to authenticated;

-- Envia push Expo (via pg_net) para todos os admins registrados
create or replace function public._send_profit_push(
  p_user_id uuid,
  p_name text,
  p_profit numeric
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  tokens text[];
  payload jsonb;
begin
  select array_agg(distinct t.expo_push_token)
  into tokens
  from public.admin_push_tokens t
  where coalesce(t.expo_push_token, '') <> '';

  if tokens is null or cardinality(tokens) = 0 then
    return;
  end if;

  payload := (
    select jsonb_agg(
      jsonb_build_object(
        'to', tok,
        'title', 'Lucro alto',
        'body', coalesce(nullif(p_name, ''), 'Jogador')
          || ' está com lucro de R$ '
          || to_char(p_profit, 'FM999999990.00'),
        'sound', 'default',
        'data', jsonb_build_object(
          'type', 'profit_alert',
          'userId', p_user_id,
          'profit', p_profit
        )
      )
    )
    from unnest(tokens) as tok
  );

  begin
    perform net.http_post(
      url := 'https://exp.host/--/api/v2/push/send',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Accept', 'application/json'
      ),
      body := payload
    );
  exception when others then
    -- Sem pg_net / falha de rede: alerta continua salvo no banco
    null;
  end;
end;
$$;

revoke all on function public._send_profit_push(uuid, text, numeric) from public;

create or replace function public.check_player_profit_alerts(p_user_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  profit numeric;
  threshold numeric := 600;
  pname text;
  has_active boolean;
  new_id bigint;
begin
  if p_user_id is null then
    return json_build_object('ok', false, 'reason', 'no_user');
  end if;

  if exists (select 1 from public.profiles where id = p_user_id and is_admin = true) then
    return json_build_object('ok', true, 'skipped', 'admin');
  end if;

  profit := public.compute_player_profit(p_user_id);
  select coalesce(display_name, email, 'Jogador') into pname
  from public.profiles where id = p_user_id;

  select exists (
    select 1 from public.profit_alerts
    where user_id = p_user_id and active = true
  ) into has_active;

  -- Rearma se caiu abaixo do limiar
  if profit < threshold and has_active then
    update public.profit_alerts
    set active = false
    where user_id = p_user_id and active = true;
    return json_build_object('ok', true, 'profit', profit, 'disarmed', true);
  end if;

  -- Cruza o limiar: cria alerta + push
  if profit >= threshold and not has_active then
    insert into public.profit_alerts (user_id, threshold, profit_snapshot, active, notified)
    values (p_user_id, threshold, profit, true, true)
    returning id into new_id;

    perform public._send_profit_push(p_user_id, pname, profit);

    return json_build_object(
      'ok', true,
      'profit', profit,
      'alerted', true,
      'alert_id', new_id
    );
  end if;

  return json_build_object('ok', true, 'profit', profit, 'alerted', false);
end;
$$;

revoke all on function public.check_player_profit_alerts(uuid) from public;
grant execute on function public.check_player_profit_alerts(uuid) to authenticated, service_role;

-- Trigger: qualquer mudança de créditos
create or replace function public.trg_profiles_profit_check()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.player_credits is distinct from old.player_credits then
    perform public.check_player_profit_alerts(new.id);
  end if;
  return new;
end;
$$;

drop trigger if exists trg_profiles_profit_check on public.profiles;
create trigger trg_profiles_profit_check
  after update of player_credits on public.profiles
  for each row
  execute function public.trg_profiles_profit_check();

-- Trigger: depósito pago / saque pago ou rejeitado
create or replace function public.trg_money_profit_check()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_table_name = 'deposits' then
    if new.status = 'paid' and (tg_op = 'INSERT' or old.status is distinct from new.status) then
      perform public.check_player_profit_alerts(new.user_id);
    end if;
  elsif tg_table_name = 'withdrawals' then
    if new.status in ('paid', 'rejected')
       and (tg_op = 'INSERT' or old.status is distinct from new.status) then
      perform public.check_player_profit_alerts(new.user_id);
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_deposits_profit_check on public.deposits;
create trigger trg_deposits_profit_check
  after insert or update of status on public.deposits
  for each row
  execute function public.trg_money_profit_check();

drop trigger if exists trg_withdrawals_profit_check on public.withdrawals;
create trigger trg_withdrawals_profit_check
  after insert or update of status on public.withdrawals
  for each row
  execute function public.trg_money_profit_check();
