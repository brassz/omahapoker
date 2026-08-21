-- Consultores + % de comissão (gerente e consultor)
-- Rode DEPOIS de managers.sql no SQL Editor.

alter table public.profiles
  add column if not exists is_consultant boolean not null default false;

alter table public.profiles
  add column if not exists managed_by uuid references public.profiles (id) on delete set null;

alter table public.profiles
  add column if not exists commission_percent numeric(5,2) not null default 0
    check (commission_percent >= 0 and commission_percent <= 100);

create index if not exists profiles_is_consultant_idx
  on public.profiles (is_consultant)
  where is_consultant = true;

create index if not exists profiles_managed_by_idx
  on public.profiles (managed_by);

-- Helpers
create or replace function public.is_consultant()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select is_consultant from public.profiles where id = auth.uid()),
    false
  );
$$;

revoke all on function public.is_consultant() from public;
grant execute on function public.is_consultant() to authenticated, anon;

-- Dono do link (gerente ou seus consultores)
create or replace function public.staff_referrer_ids(p_staff_id uuid)
returns table (id uuid)
language sql
stable
security definer
set search_path = public
as $$
  select p_staff_id
  union
  select c.id
  from public.profiles c
  where c.managed_by = p_staff_id
    and c.is_consultant = true
    and exists (
      select 1 from public.profiles m
      where m.id = p_staff_id and m.is_manager = true
    );
$$;

create or replace function public.consultants_percent_sum(p_manager_id uuid, p_exclude uuid default null)
returns numeric
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(sum(commission_percent), 0)
  from public.profiles
  where managed_by = p_manager_id
    and is_consultant = true
    and (p_exclude is null or id <> p_exclude);
$$;

-- Cadastro: ref de gerente OU consultor
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  ref_code text;
  owner_id uuid;
  phone_meta text;
begin
  ref_code := nullif(upper(trim(coalesce(new.raw_user_meta_data->>'ref', ''))), '');
  owner_id := null;
  if ref_code is not null then
    select id into owner_id
    from public.profiles
    where referral_code = ref_code
      and coalesce(is_admin, false) = false
      and (is_manager = true or is_consultant = true)
    limit 1;
  end if;

  phone_meta := nullif(regexp_replace(coalesce(new.raw_user_meta_data->>'phone', ''), '\D', '', 'g'), '');

  insert into public.profiles (
    id, email, display_name, player_credits, bank_credits,
    is_admin, is_manager, is_consultant, phone, referred_by
  )
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)),
    0,
    0,
    false,
    false,
    false,
    phone_meta,
    owner_id
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

create or replace function public.claim_referral(p_code text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  code text;
  owner_id uuid;
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
  if coalesce(rec.is_admin, false) or coalesce(rec.is_manager, false) or coalesce(rec.is_consultant, false) then
    raise exception 'Staff não pode ser indicado';
  end if;

  select id into owner_id
  from public.profiles
  where referral_code = code
    and coalesce(is_admin, false) = false
    and (is_manager = true or is_consultant = true)
    and id <> uid
  limit 1;

  if owner_id is null then
    raise exception 'Link de indicação inválido';
  end if;

  update public.profiles
  set referred_by = owner_id
  where id = uid
  returning * into rec;

  return json_build_object('ok', true, 'referred_by', owner_id);
end;
$$;

revoke all on function public.claim_referral(text) from public;
grant execute on function public.claim_referral(text) to authenticated;

-- ========== ADMIN: gerente com % ==========

drop function if exists public.admin_set_manager(uuid, boolean);
drop function if exists public.admin_set_manager(uuid, boolean, numeric);

create or replace function public.admin_set_manager(
  p_user_id uuid,
  p_on boolean,
  p_percent numeric default 0
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  rec public.profiles;
  code text;
  pct numeric;
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
    pct := coalesce(p_percent, 0);
    if pct < 0 or pct > 100 then
      raise exception 'Porcentagem do gerente deve ser entre 0 e 100';
    end if;
    if coalesce(rec.is_consultant, false) then
      raise exception 'Remova o cargo de consultor antes de tornar gerente';
    end if;
    code := coalesce(rec.referral_code, public.gen_referral_code());
    update public.profiles
    set
      is_manager = true,
      is_consultant = false,
      managed_by = null,
      referral_code = code,
      commission_percent = pct
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
    'referral_code', rec.referral_code,
    'commission_percent', rec.commission_percent
  );
end;
$$;

revoke all on function public.admin_set_manager(uuid, boolean, numeric) from public;
grant execute on function public.admin_set_manager(uuid, boolean, numeric) to authenticated;

drop function if exists public.admin_finish_manager_setup(uuid);

create or replace function public.admin_finish_manager_setup(
  p_user_id uuid,
  p_percent numeric default 0
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  rec public.profiles;
  code text;
  pct numeric;
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'Apenas administradores';
  end if;

  pct := coalesce(p_percent, 0);
  if pct < 0 or pct > 100 then
    raise exception 'Porcentagem do gerente deve ser entre 0 e 100';
  end if;

  select * into rec from public.profiles where id = p_user_id for update;
  if rec.id is null then
    raise exception 'Perfil não encontrado';
  end if;

  code := coalesce(rec.referral_code, public.gen_referral_code());
  update public.profiles
  set
    is_manager = true,
    is_consultant = false,
    managed_by = null,
    referral_code = code,
    is_admin = false,
    commission_percent = pct
  where id = p_user_id
  returning * into rec;

  return json_build_object(
    'id', rec.id,
    'email', rec.email,
    'display_name', rec.display_name,
    'is_manager', rec.is_manager,
    'referral_code', rec.referral_code,
    'commission_percent', rec.commission_percent
  );
end;
$$;

revoke all on function public.admin_finish_manager_setup(uuid, numeric) from public;
grant execute on function public.admin_finish_manager_setup(uuid, numeric) to authenticated, service_role;

drop function if exists public.admin_list_managers();

create or replace function public.admin_list_managers()
returns table (
  user_id uuid,
  email text,
  display_name text,
  phone text,
  referral_code text,
  commission_percent numeric,
  consultants_count bigint,
  consultants_percent numeric,
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
    m.commission_percent::numeric,
    coalesce((
      select count(*) from public.profiles c
      where c.managed_by = m.id and c.is_consultant = true
    ), 0)::bigint,
    public.consultants_percent_sum(m.id)::numeric,
    coalesce((
      select count(*) from public.profiles p
      where p.referred_by in (select s.id from public.staff_referrer_ids(m.id) s)
    ), 0)::bigint,
    coalesce((
      select sum(d.amount) from public.deposits d
      join public.profiles p on p.id = d.user_id
      where p.referred_by in (select s.id from public.staff_referrer_ids(m.id) s)
        and d.status = 'paid'
    ), 0)::numeric,
    coalesce((
      select sum(w.amount) from public.withdrawals w
      join public.profiles p on p.id = w.user_id
      where p.referred_by in (select s.id from public.staff_referrer_ids(m.id) s)
        and w.status = 'paid'
    ), 0)::numeric,
    coalesce((
      select sum(p.player_credits) from public.profiles p
      where p.referred_by in (select s.id from public.staff_referrer_ids(m.id) s)
    ), 0)::numeric,
    coalesce((
      select sum(public.player_net_profit(p.id)) from public.profiles p
      where p.referred_by in (select s.id from public.staff_referrer_ids(m.id) s)
    ), 0)::numeric,
    m.created_at
  from public.profiles m
  where m.is_manager = true
  order by m.created_at desc nulls last;
end;
$$;

revoke all on function public.admin_list_managers() from public;
grant execute on function public.admin_list_managers() to authenticated;

drop function if exists public.admin_list_manager_players(uuid);

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
  referred_by uuid,
  referrer_name text,
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
    p.referred_by,
    r.display_name::text,
    p.created_at
  from public.profiles p
  left join public.profiles r on r.id = p.referred_by
  where p.referred_by in (select s.id from public.staff_referrer_ids(p_manager_id) s)
  order by p.created_at desc nulls last;
end;
$$;

revoke all on function public.admin_list_manager_players(uuid) from public;
grant execute on function public.admin_list_manager_players(uuid) to authenticated;

create or replace function public.admin_list_manager_consultants(p_manager_id uuid)
returns table (
  user_id uuid,
  email text,
  display_name text,
  phone text,
  referral_code text,
  commission_percent numeric,
  referred_count bigint,
  total_deposits numeric,
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
    c.id,
    c.email::text,
    c.display_name::text,
    c.phone::text,
    c.referral_code::text,
    c.commission_percent::numeric,
    coalesce((select count(*) from public.profiles p where p.referred_by = c.id), 0)::bigint,
    coalesce((
      select sum(d.amount) from public.deposits d
      join public.profiles p on p.id = d.user_id
      where p.referred_by = c.id and d.status = 'paid'
    ), 0)::numeric,
    coalesce((
      select sum(public.player_net_profit(p.id)) from public.profiles p where p.referred_by = c.id
    ), 0)::numeric,
    c.created_at
  from public.profiles c
  where c.managed_by = p_manager_id and c.is_consultant = true
  order by c.created_at desc nulls last;
end;
$$;

revoke all on function public.admin_list_manager_consultants(uuid) from public;
grant execute on function public.admin_list_manager_consultants(uuid) to authenticated;

-- ========== GERENTE: downline + consultores ==========

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
  if not public.is_manager() or public.is_admin() then
    raise exception 'Apenas gerentes';
  end if;

  select * into rec from public.profiles where id = auth.uid() for update;
  code := coalesce(rec.referral_code, public.gen_referral_code());
  if rec.referral_code is null then
    update public.profiles set referral_code = code where id = auth.uid();
  end if;

  return json_build_object(
    'referral_code', code,
    'display_name', rec.display_name,
    'email', rec.email,
    'commission_percent', rec.commission_percent,
    'consultants_percent', public.consultants_percent_sum(auth.uid()),
    'remaining_percent', greatest(0, coalesce(rec.commission_percent, 0) - public.consultants_percent_sum(auth.uid()))
  );
end;
$$;

create or replace function public.manager_summary()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  pct numeric;
begin
  if not public.is_manager() or public.is_admin() then
    raise exception 'Apenas gerentes';
  end if;

  select commission_percent into pct from public.profiles where id = uid;

  return json_build_object(
    'commission_percent', coalesce(pct, 0),
    'consultants_percent', public.consultants_percent_sum(uid),
    'remaining_percent', greatest(0, coalesce(pct, 0) - public.consultants_percent_sum(uid)),
    'consultants_count', coalesce((
      select count(*) from public.profiles where managed_by = uid and is_consultant = true
    ), 0),
    'referred_count', coalesce((
      select count(*) from public.profiles
      where referred_by in (select s.id from public.staff_referrer_ids(uid) s)
    ), 0),
    'total_deposits', coalesce((
      select sum(d.amount) from public.deposits d
      join public.profiles p on p.id = d.user_id
      where p.referred_by in (select s.id from public.staff_referrer_ids(uid) s)
        and d.status = 'paid'
    ), 0),
    'total_withdrawals', coalesce((
      select sum(w.amount) from public.withdrawals w
      join public.profiles p on p.id = w.user_id
      where p.referred_by in (select s.id from public.staff_referrer_ids(uid) s)
        and w.status = 'paid'
    ), 0),
    'total_credits', coalesce((
      select sum(p.player_credits) from public.profiles p
      where p.referred_by in (select s.id from public.staff_referrer_ids(uid) s)
    ), 0),
    'portfolio_profit', coalesce((
      select sum(public.player_net_profit(p.id)) from public.profiles p
      where p.referred_by in (select s.id from public.staff_referrer_ids(uid) s)
    ), 0)
  );
end;
$$;

drop function if exists public.manager_list_players();

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
  referred_by uuid,
  referrer_name text,
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
    p.referred_by,
    r.display_name::text,
    p.created_at
  from public.profiles p
  left join public.profiles r on r.id = p.referred_by
  where p.referred_by in (select s.id from public.staff_referrer_ids(uid) s)
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
    d.id, d.user_id, d.amount, d.status::text, d.payment_id::text,
    d.created_at, d.paid_at, p.display_name::text, p.email::text
  from public.deposits d
  join public.profiles p on p.id = d.user_id
  where p.referred_by in (select s.id from public.staff_referrer_ids(uid) s)
  order by d.created_at desc
  limit 200;
end;
$$;

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
    w.id, w.user_id, w.amount, w.pix_key::text, w.status::text,
    w.created_at, w.processed_at, p.display_name::text, p.email::text
  from public.withdrawals w
  join public.profiles p on p.id = w.user_id
  where p.referred_by in (select s.id from public.staff_referrer_ids(uid) s)
  order by w.created_at desc
  limit 200;
end;
$$;

create or replace function public.manager_set_consultant(
  p_user_id uuid,
  p_on boolean,
  p_percent numeric default 0
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  mgr public.profiles;
  rec public.profiles;
  code text;
  pct numeric;
  used numeric;
begin
  if not public.is_manager() or public.is_admin() then
    raise exception 'Apenas gerentes';
  end if;

  select * into mgr from public.profiles where id = uid for update;
  select * into rec from public.profiles where id = p_user_id for update;
  if rec.id is null then
    raise exception 'Jogador não encontrado';
  end if;
  if coalesce(rec.is_admin, false) or coalesce(rec.is_manager, false) then
    raise exception 'Não é possível tornar este usuário consultor';
  end if;
  if p_user_id = uid then
    raise exception 'Você não pode ser consultor de si mesmo';
  end if;

  if coalesce(p_on, false) then
    pct := coalesce(p_percent, 0);
    if pct <= 0 or pct > 100 then
      raise exception 'Informe uma porcentagem maior que 0 e até 100';
    end if;
    if coalesce(rec.is_consultant, false) and rec.managed_by is distinct from uid then
      raise exception 'Consultor pertence a outro gerente';
    end if;
    used := public.consultants_percent_sum(uid, p_user_id);
    if used + pct > coalesce(mgr.commission_percent, 0) + 0.0001 then
      raise exception 'Soma dos consultores (%%) não pode passar de % (restam %)',
        mgr.commission_percent,
        greatest(0, coalesce(mgr.commission_percent, 0) - used);
    end if;
    code := coalesce(rec.referral_code, public.gen_referral_code());
    update public.profiles
    set
      is_consultant = true,
      managed_by = uid,
      referral_code = code,
      commission_percent = pct,
      is_manager = false
    where id = p_user_id
    returning * into rec;
  else
    if not coalesce(rec.is_consultant, false) or rec.managed_by is distinct from uid then
      raise exception 'Consultor não encontrado na sua equipe';
    end if;
    update public.profiles
    set is_consultant = false, managed_by = null, commission_percent = 0
    where id = p_user_id
    returning * into rec;
  end if;

  return json_build_object(
    'id', rec.id,
    'email', rec.email,
    'display_name', rec.display_name,
    'is_consultant', rec.is_consultant,
    'referral_code', rec.referral_code,
    'commission_percent', rec.commission_percent,
    'managed_by', rec.managed_by
  );
end;
$$;

revoke all on function public.manager_set_consultant(uuid, boolean, numeric) from public;
grant execute on function public.manager_set_consultant(uuid, boolean, numeric) to authenticated;

create or replace function public.manager_finish_consultant_setup(
  p_user_id uuid,
  p_percent numeric
)
returns json
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is not null then
    return public.manager_set_consultant(p_user_id, true, p_percent);
  end if;
  raise exception 'Use autenticação do gerente';
end;
$$;

-- Edge function (service_role): cria consultor já validado pelo JWT do gerente
create or replace function public.service_attach_consultant(
  p_manager_id uuid,
  p_user_id uuid,
  p_percent numeric
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  mgr public.profiles;
  rec public.profiles;
  code text;
  pct numeric;
  used numeric;
begin
  if auth.uid() is not null and not public.is_admin() then
    raise exception 'Apenas service/admin';
  end if;

  select * into mgr from public.profiles where id = p_manager_id for update;
  if mgr.id is null or not coalesce(mgr.is_manager, false) then
    raise exception 'Gerente inválido';
  end if;

  select * into rec from public.profiles where id = p_user_id for update;
  if rec.id is null then
    raise exception 'Perfil não encontrado';
  end if;
  if coalesce(rec.is_admin, false) or coalesce(rec.is_manager, false) then
    raise exception 'Não é possível tornar este usuário consultor';
  end if;

  pct := coalesce(p_percent, 0);
  if pct <= 0 or pct > 100 then
    raise exception 'Informe uma porcentagem maior que 0 e até 100';
  end if;

  used := public.consultants_percent_sum(p_manager_id, p_user_id);
  if used + pct > coalesce(mgr.commission_percent, 0) + 0.0001 then
    raise exception 'Soma dos consultores (%%) não pode passar de % (restam %)',
      mgr.commission_percent,
      greatest(0, coalesce(mgr.commission_percent, 0) - used);
  end if;

  code := coalesce(rec.referral_code, public.gen_referral_code());
  update public.profiles
  set
    is_consultant = true,
    managed_by = p_manager_id,
    referral_code = code,
    commission_percent = pct,
    is_manager = false
  where id = p_user_id
  returning * into rec;

  return json_build_object(
    'id', rec.id,
    'email', rec.email,
    'display_name', rec.display_name,
    'is_consultant', rec.is_consultant,
    'referral_code', rec.referral_code,
    'commission_percent', rec.commission_percent,
    'managed_by', rec.managed_by
  );
end;
$$;

revoke all on function public.service_attach_consultant(uuid, uuid, numeric) from public;
grant execute on function public.service_attach_consultant(uuid, uuid, numeric) to service_role;

-- Lista jogadores do clube para o gerente promover (somente não-staff)
create or replace function public.manager_search_players(p_q text default '')
returns table (
  user_id uuid,
  email text,
  display_name text,
  phone text,
  is_consultant boolean,
  commission_percent numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  q text := lower(trim(coalesce(p_q, '')));
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
    coalesce(p.is_consultant, false),
    p.commission_percent::numeric
  from public.profiles p
  where coalesce(p.is_admin, false) = false
    and coalesce(p.is_manager, false) = false
    and (
      (coalesce(p.is_consultant, false) = false)
      or p.managed_by = uid
    )
    and (
      q = ''
      or lower(coalesce(p.email, '')) like '%' || q || '%'
      or lower(coalesce(p.display_name, '')) like '%' || q || '%'
      or coalesce(p.phone, '') like '%' || q || '%'
    )
  order by p.display_name nulls last
  limit 40;
end;
$$;

revoke all on function public.manager_search_players(text) from public;
grant execute on function public.manager_search_players(text) to authenticated;

create or replace function public.manager_list_consultants()
returns table (
  user_id uuid,
  email text,
  display_name text,
  phone text,
  referral_code text,
  commission_percent numeric,
  referred_count bigint,
  total_deposits numeric,
  total_withdrawals numeric,
  portfolio_profit numeric,
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
    c.id,
    c.email::text,
    c.display_name::text,
    c.phone::text,
    c.referral_code::text,
    c.commission_percent::numeric,
    coalesce((select count(*) from public.profiles p where p.referred_by = c.id), 0)::bigint,
    coalesce((
      select sum(d.amount) from public.deposits d
      join public.profiles p on p.id = d.user_id
      where p.referred_by = c.id and d.status = 'paid'
    ), 0)::numeric,
    coalesce((
      select sum(w.amount) from public.withdrawals w
      join public.profiles p on p.id = w.user_id
      where p.referred_by = c.id and w.status = 'paid'
    ), 0)::numeric,
    coalesce((
      select sum(public.player_net_profit(p.id)) from public.profiles p where p.referred_by = c.id
    ), 0)::numeric,
    c.created_at
  from public.profiles c
  where c.managed_by = uid and c.is_consultant = true
  order by c.created_at desc nulls last;
end;
$$;

revoke all on function public.manager_list_consultants() from public;
grant execute on function public.manager_list_consultants() to authenticated;

-- ========== CONSULTOR ==========

create or replace function public.consultant_my_code()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  rec public.profiles;
  code text;
begin
  if not public.is_consultant() or public.is_admin() or public.is_manager() then
    raise exception 'Apenas consultores';
  end if;

  select * into rec from public.profiles where id = auth.uid() for update;
  code := coalesce(rec.referral_code, public.gen_referral_code());
  if rec.referral_code is null then
    update public.profiles set referral_code = code where id = auth.uid();
  end if;

  return json_build_object(
    'referral_code', code,
    'display_name', rec.display_name,
    'email', rec.email,
    'commission_percent', rec.commission_percent,
    'managed_by', rec.managed_by
  );
end;
$$;

revoke all on function public.consultant_my_code() from public;
grant execute on function public.consultant_my_code() to authenticated;

create or replace function public.consultant_summary()
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  pct numeric;
begin
  if not public.is_consultant() or public.is_admin() or public.is_manager() then
    raise exception 'Apenas consultores';
  end if;
  select commission_percent into pct from public.profiles where id = uid;

  return json_build_object(
    'commission_percent', coalesce(pct, 0),
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

revoke all on function public.consultant_summary() from public;
grant execute on function public.consultant_summary() to authenticated;

create or replace function public.consultant_list_players()
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
  if not public.is_consultant() or public.is_admin() or public.is_manager() then
    raise exception 'Apenas consultores';
  end if;

  return query
  select
    p.id, p.email::text, p.display_name::text, p.phone::text, p.player_credits::numeric,
    coalesce((select sum(d.amount) from public.deposits d where d.user_id = p.id and d.status = 'paid'), 0)::numeric,
    coalesce((select sum(w.amount) from public.withdrawals w where w.user_id = p.id and w.status = 'paid'), 0)::numeric,
    public.player_net_profit(p.id)::numeric,
    p.created_at
  from public.profiles p
  where p.referred_by = uid
  order by p.created_at desc nulls last;
end;
$$;

revoke all on function public.consultant_list_players() from public;
grant execute on function public.consultant_list_players() to authenticated;

create or replace function public.consultant_list_deposits()
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
  if not public.is_consultant() or public.is_admin() or public.is_manager() then
    raise exception 'Apenas consultores';
  end if;

  return query
  select
    d.id, d.user_id, d.amount, d.status::text, d.payment_id::text,
    d.created_at, d.paid_at, p.display_name::text, p.email::text
  from public.deposits d
  join public.profiles p on p.id = d.user_id
  where p.referred_by = uid
  order by d.created_at desc
  limit 200;
end;
$$;

revoke all on function public.consultant_list_deposits() from public;
grant execute on function public.consultant_list_deposits() to authenticated;

create or replace function public.consultant_list_withdrawals()
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
  if not public.is_consultant() or public.is_admin() or public.is_manager() then
    raise exception 'Apenas consultores';
  end if;

  return query
  select
    w.id, w.user_id, w.amount, w.pix_key::text, w.status::text,
    w.created_at, w.processed_at, p.display_name::text, p.email::text
  from public.withdrawals w
  join public.profiles p on p.id = w.user_id
  where p.referred_by = uid
  order by w.created_at desc
  limit 200;
end;
$$;

revoke all on function public.consultant_list_withdrawals() from public;
grant execute on function public.consultant_list_withdrawals() to authenticated;

-- admin_list_players: flag consultor
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
  is_consultant boolean,
  commission_percent numeric,
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
    coalesce(p.is_consultant, false),
    p.commission_percent::numeric,
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
