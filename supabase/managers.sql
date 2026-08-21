-- Gerentes + links de indicação
-- 1) Rode este SQL no Supabase (SQL Editor).
-- 2) (Opcional, para criar gerente por e-mail/senha no painel)
--    npx supabase link --project-ref zwtvqpnpuahcuhodroib
--    npx supabase functions deploy admin-managers
-- Sem a Edge Function, ainda dá para promover jogador existente: VIRAR GERENTE.

alter table public.profiles
  add column if not exists is_manager boolean not null default false;

alter table public.profiles
  add column if not exists referral_code text;

alter table public.profiles
  add column if not exists referred_by uuid references public.profiles (id) on delete set null;

create unique index if not exists profiles_referral_code_uidx
  on public.profiles (referral_code)
  where referral_code is not null;

create index if not exists profiles_referred_by_idx
  on public.profiles (referred_by);

create index if not exists profiles_is_manager_idx
  on public.profiles (is_manager)
  where is_manager = true;

-- Helpers
create or replace function public.is_manager()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select is_manager from public.profiles where id = auth.uid()),
    false
  );
$$;

revoke all on function public.is_manager() from public;
grant execute on function public.is_manager() to authenticated, anon;

create or replace function public.gen_referral_code()
returns text
language plpgsql
as $$
declare
  chars text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
  code text;
  i int;
begin
  loop
    code := '';
    for i in 1..8 loop
      code := code || substr(chars, 1 + floor(random() * length(chars))::int, 1);
    end loop;
    exit when not exists (select 1 from public.profiles where referral_code = code);
  end loop;
  return code;
end;
$$;

-- Lucro líquido (mesma fórmula do player-profit)
create or replace function public.player_net_profit(p_user_id uuid)
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

revoke all on function public.player_net_profit(uuid) from public;
grant execute on function public.player_net_profit(uuid) to authenticated;

-- Cadastro: grava telefone + indicação (ref)
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  ref_code text;
  mgr_id uuid;
  phone_meta text;
begin
  ref_code := nullif(upper(trim(coalesce(new.raw_user_meta_data->>'ref', ''))), '');
  mgr_id := null;
  if ref_code is not null then
    select id into mgr_id
    from public.profiles
    where referral_code = ref_code
      and is_manager = true
      and coalesce(is_admin, false) = false
    limit 1;
  end if;

  phone_meta := nullif(regexp_replace(coalesce(new.raw_user_meta_data->>'phone', ''), '\D', '', 'g'), '');

  insert into public.profiles (
    id, email, display_name, player_credits, bank_credits,
    is_admin, is_manager, phone, referred_by
  )
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)),
    0,
    0,
    false,
    false,
    phone_meta,
    mgr_id
  )
  on conflict (id) do update
  set
    email = excluded.email,
    display_name = coalesce(public.profiles.display_name, excluded.display_name),
    phone = coalesce(public.profiles.phone, excluded.phone),
    referred_by = coalesce(public.profiles.referred_by, excluded.referred_by);

  return new;
end;
$$;

-- ========== ADMIN ==========

create or replace function public.admin_set_manager(p_user_id uuid, p_on boolean)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  rec public.profiles;
  code text;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores';
  end if;
  if p_user_id is null then
    raise exception 'Usuário inválido';
  end if;

  select * into rec from public.profiles where id = p_user_id for update;
  if rec.id is null then
    raise exception 'Jogador não encontrado';
  end if;
  if coalesce(rec.is_admin, false) then
    raise exception 'Não é possível tornar admin em gerente';
  end if;

  if coalesce(p_on, false) then
    code := coalesce(rec.referral_code, public.gen_referral_code());
    update public.profiles
    set is_manager = true, referral_code = code
    where id = p_user_id
    returning * into rec;
  else
    update public.profiles
    set is_manager = false
    where id = p_user_id
    returning * into rec;
  end if;

  return json_build_object(
    'id', rec.id,
    'email', rec.email,
    'display_name', rec.display_name,
    'is_manager', rec.is_manager,
    'referral_code', rec.referral_code
  );
end;
$$;

revoke all on function public.admin_set_manager(uuid, boolean) from public;
grant execute on function public.admin_set_manager(uuid, boolean) to authenticated;

-- Chamado pela Edge Function após criar o user (service_role)
create or replace function public.admin_finish_manager_setup(p_user_id uuid)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  rec public.profiles;
  code text;
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'Apenas administradores';
  end if;

  select * into rec from public.profiles where id = p_user_id for update;
  if rec.id is null then
    raise exception 'Perfil não encontrado';
  end if;

  code := coalesce(rec.referral_code, public.gen_referral_code());
  update public.profiles
  set is_manager = true, referral_code = code, is_admin = false
  where id = p_user_id
  returning * into rec;

  return json_build_object(
    'id', rec.id,
    'email', rec.email,
    'display_name', rec.display_name,
    'is_manager', rec.is_manager,
    'referral_code', rec.referral_code
  );
end;
$$;

revoke all on function public.admin_finish_manager_setup(uuid) from public;
grant execute on function public.admin_finish_manager_setup(uuid) to authenticated, service_role;

create or replace function public.admin_list_managers()
returns table (
  user_id uuid,
  email text,
  display_name text,
  phone text,
  referral_code text,
  referred_count bigint,
  total_deposits numeric,
  total_withdrawals numeric,
  total_credits numeric,
  portfolio_profit numeric,
  created_at timestamptz
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
    m.id,
    m.email::text,
    m.display_name::text,
    m.phone::text,
    m.referral_code::text,
    coalesce((select count(*) from public.profiles p where p.referred_by = m.id), 0)::bigint,
    coalesce((
      select sum(d.amount) from public.deposits d
      join public.profiles p on p.id = d.user_id
      where p.referred_by = m.id and d.status = 'paid'
    ), 0)::numeric,
    coalesce((
      select sum(w.amount) from public.withdrawals w
      join public.profiles p on p.id = w.user_id
      where p.referred_by = m.id and w.status = 'paid'
    ), 0)::numeric,
    coalesce((
      select sum(p.player_credits) from public.profiles p where p.referred_by = m.id
    ), 0)::numeric,
    coalesce((
      select sum(public.player_net_profit(p.id)) from public.profiles p where p.referred_by = m.id
    ), 0)::numeric,
    m.created_at
  from public.profiles m
  where m.is_manager = true
  order by m.created_at desc nulls last;
end;
$$;

revoke all on function public.admin_list_managers() from public;
grant execute on function public.admin_list_managers() to authenticated;

create or replace function public.admin_list_manager_players(p_manager_id uuid)
returns table (
  user_id uuid,
  email text,
  display_name text,
  phone text,
  player_credits numeric,
  total_deposits numeric,
  total_withdrawals numeric,
  profit numeric,
  created_at timestamptz
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
    p.id,
    p.email::text,
    p.display_name::text,
    p.phone::text,
    p.player_credits::numeric,
    coalesce((select sum(d.amount) from public.deposits d where d.user_id = p.id and d.status = 'paid'), 0)::numeric,
    coalesce((select sum(w.amount) from public.withdrawals w where w.user_id = p.id and w.status = 'paid'), 0)::numeric,
    public.player_net_profit(p.id)::numeric,
    p.created_at
  from public.profiles p
  where p.referred_by = p_manager_id
  order by p.created_at desc nulls last;
end;
$$;

revoke all on function public.admin_list_manager_players(uuid) from public;
grant execute on function public.admin_list_manager_players(uuid) to authenticated;

-- ========== GERENTE ==========

create or replace function public.manager_my_code()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  rec public.profiles;
  code text;
begin
  if not public.is_manager() then
    raise exception 'Apenas gerentes';
  end if;
  if public.is_admin() then
    raise exception 'Use o painel admin';
  end if;

  select * into rec from public.profiles where id = auth.uid() for update;
  code := coalesce(rec.referral_code, public.gen_referral_code());
  if rec.referral_code is null then
    update public.profiles set referral_code = code where id = auth.uid();
  end if;

  return json_build_object(
    'referral_code', code,
    'display_name', rec.display_name,
    'email', rec.email
  );
end;
$$;

revoke all on function public.manager_my_code() from public;
grant execute on function public.manager_my_code() to authenticated;

create or replace function public.manager_summary()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if not public.is_manager() or public.is_admin() then
    raise exception 'Apenas gerentes';
  end if;

  return json_build_object(
    'referred_count', coalesce((select count(*) from public.profiles where referred_by = uid), 0),
    'total_deposits', coalesce((
      select sum(d.amount) from public.deposits d
      join public.profiles p on p.id = d.user_id
      where p.referred_by = uid and d.status = 'paid'
    ), 0),
    'total_withdrawals', coalesce((
      select sum(w.amount) from public.withdrawals w
      join public.profiles p on p.id = w.user_id
      where p.referred_by = uid and w.status = 'paid'
    ), 0),
    'total_credits', coalesce((
      select sum(p.player_credits) from public.profiles p where p.referred_by = uid
    ), 0),
    'portfolio_profit', coalesce((
      select sum(public.player_net_profit(p.id)) from public.profiles p where p.referred_by = uid
    ), 0)
  );
end;
$$;

revoke all on function public.manager_summary() from public;
grant execute on function public.manager_summary() to authenticated;

create or replace function public.manager_list_players()
returns table (
  user_id uuid,
  email text,
  display_name text,
  phone text,
  player_credits numeric,
  total_deposits numeric,
  total_withdrawals numeric,
  profit numeric,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if not public.is_manager() or public.is_admin() then
    raise exception 'Apenas gerentes';
  end if;

  return query
  select
    p.id,
    p.email::text,
    p.display_name::text,
    p.phone::text,
    p.player_credits::numeric,
    coalesce((select sum(d.amount) from public.deposits d where d.user_id = p.id and d.status = 'paid'), 0)::numeric,
    coalesce((select sum(w.amount) from public.withdrawals w where w.user_id = p.id and w.status = 'paid'), 0)::numeric,
    public.player_net_profit(p.id)::numeric,
    p.created_at
  from public.profiles p
  where p.referred_by = uid
  order by p.created_at desc nulls last;
end;
$$;

revoke all on function public.manager_list_players() from public;
grant execute on function public.manager_list_players() to authenticated;

create or replace function public.manager_list_deposits()
returns table (
  id uuid,
  user_id uuid,
  amount numeric,
  status text,
  payment_id text,
  created_at timestamptz,
  paid_at timestamptz,
  display_name text,
  email text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if not public.is_manager() or public.is_admin() then
    raise exception 'Apenas gerentes';
  end if;

  return query
  select
    d.id,
    d.user_id,
    d.amount,
    d.status::text,
    d.payment_id::text,
    d.created_at,
    d.paid_at,
    p.display_name::text,
    p.email::text
  from public.deposits d
  join public.profiles p on p.id = d.user_id
  where p.referred_by = uid
  order by d.created_at desc
  limit 200;
end;
$$;

revoke all on function public.manager_list_deposits() from public;
grant execute on function public.manager_list_deposits() to authenticated;

create or replace function public.manager_list_withdrawals()
returns table (
  id uuid,
  user_id uuid,
  amount numeric,
  pix_key text,
  status text,
  created_at timestamptz,
  processed_at timestamptz,
  display_name text,
  email text
)
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
begin
  if not public.is_manager() or public.is_admin() then
    raise exception 'Apenas gerentes';
  end if;

  return query
  select
    w.id,
    w.user_id,
    w.amount,
    w.pix_key::text,
    w.status::text,
    w.created_at,
    w.processed_at,
    p.display_name::text,
    p.email::text
  from public.withdrawals w
  join public.profiles p on p.id = w.user_id
  where p.referred_by = uid
  order by w.created_at desc
  limit 200;
end;
$$;

revoke all on function public.manager_list_withdrawals() from public;
grant execute on function public.manager_list_withdrawals() to authenticated;

-- Jogador vincula indicação no cadastro (se ainda não tiver)
create or replace function public.claim_referral(p_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  code text;
  mgr_id uuid;
  rec public.profiles;
begin
  if uid is null then
    raise exception 'Faça login';
  end if;

  code := nullif(upper(trim(coalesce(p_code, ''))), '');
  if code is null then
    raise exception 'Código inválido';
  end if;

  select * into rec from public.profiles where id = uid for update;
  if rec.id is null then
    raise exception 'Perfil não encontrado';
  end if;
  if rec.referred_by is not null then
    return json_build_object('ok', true, 'already', true, 'referred_by', rec.referred_by);
  end if;
  if coalesce(rec.is_admin, false) or coalesce(rec.is_manager, false) then
    raise exception 'Staff não pode ser indicado';
  end if;

  select id into mgr_id
  from public.profiles
  where referral_code = code
    and is_manager = true
    and coalesce(is_admin, false) = false
    and id <> uid
  limit 1;

  if mgr_id is null then
    raise exception 'Link de indicação inválido';
  end if;

  update public.profiles
  set referred_by = mgr_id
  where id = uid
  returning * into rec;

  return json_build_object('ok', true, 'referred_by', mgr_id);
end;
$$;

revoke all on function public.claim_referral(text) from public;
grant execute on function public.claim_referral(text) to authenticated;

-- Lista de jogadores do admin: inclui flag is_manager
drop function if exists public.admin_list_players();

create or replace function public.admin_list_players()
returns table (
  id uuid,
  email text,
  display_name text,
  phone text,
  player_credits numeric,
  is_admin boolean,
  is_manager boolean,
  current_game text,
  game_seen_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem listar jogadores';
  end if;

  return query
  select
    p.id,
    p.email::text,
    p.display_name::text,
    p.phone::text,
    p.player_credits::numeric,
    p.is_admin,
    coalesce(p.is_manager, false),
    p.current_game::text,
    p.game_seen_at,
    p.created_at,
    p.updated_at
  from public.profiles p
  order by p.created_at desc nulls last;
end;
$$;

revoke all on function public.admin_list_players() from public;
grant execute on function public.admin_list_players() to authenticated;
