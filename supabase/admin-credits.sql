-- Admin + saldo inicial 0

alter table public.profiles
  add column if not exists is_admin boolean not null default false;

alter table public.profiles
  alter column player_credits set default 0;

alter table public.profiles
  alter column bank_credits set default 0;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select is_admin from public.profiles where id = auth.uid()),
    false
  );
$$;

revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to authenticated, anon;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, display_name, player_credits, bank_credits, is_admin)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)),
    0,
    0,
    false
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own"
  on public.profiles for select
  to authenticated
  using (auth.uid() = id or public.is_admin());

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id or public.is_admin())
  with check (auth.uid() = id or public.is_admin());

-- Ajuste de créditos só por admin (evita auto-crédito pelo cliente)
create or replace function public.admin_adjust_credits(target_user uuid, delta numeric)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.profiles;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem ajustar créditos';
  end if;

  if delta is null or delta = 0 then
    raise exception 'Informe um valor diferente de zero';
  end if;

  update public.profiles
  set player_credits = greatest(0, player_credits + delta)
  where id = target_user
  returning * into row;

  if row.id is null then
    raise exception 'Jogador não encontrado';
  end if;

  return row;
end;
$$;

revoke all on function public.admin_adjust_credits(uuid, numeric) from public;
grant execute on function public.admin_adjust_credits(uuid, numeric) to authenticated;

create or replace function public.admin_set_credits(target_user uuid, new_amount numeric)
returns public.profiles
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.profiles;
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem definir créditos';
  end if;

  if new_amount is null or new_amount < 0 then
    raise exception 'Valor inválido';
  end if;

  update public.profiles
  set player_credits = new_amount
  where id = target_user
  returning * into row;

  if row.id is null then
    raise exception 'Jogador não encontrado';
  end if;

  return row;
end;
$$;

revoke all on function public.admin_set_credits(uuid, numeric) from public;
grant execute on function public.admin_set_credits(uuid, numeric) to authenticated;

create or replace function public.admin_delete_user(target_user uuid)
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem excluir usuários';
  end if;

  if target_user is null then
    raise exception 'Usuário inválido';
  end if;

  if target_user = auth.uid() then
    raise exception 'Você não pode excluir a si mesmo';
  end if;

  if exists (
    select 1 from public.profiles
    where id = target_user and is_admin = true
  ) then
    raise exception 'Não é permitido excluir outro administrador';
  end if;

  delete from auth.users where id = target_user;

  if not found then
    delete from public.profiles where id = target_user;
  end if;
end;
$$;

revoke all on function public.admin_delete_user(uuid) from public;
grant execute on function public.admin_delete_user(uuid) to authenticated;
