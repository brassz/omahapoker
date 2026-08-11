-- Painel admin: listar TODOS os profiles (só tabela public.profiles)
-- Bypass do RLS via SECURITY DEFINER — sem usar auth.users
-- Rode este SQL no Supabase → SQL Editor

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

-- Lista direta da tabela profiles (ignora RLS)
drop function if exists public.admin_list_players();

create or replace function public.admin_list_players()
returns table (
  id uuid,
  email text,
  display_name text,
  player_credits numeric,
  is_admin boolean,
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
    p.player_credits::numeric,
    p.is_admin,
    p.created_at,
    p.updated_at
  from public.profiles p
  order by p.created_at desc nulls last;
end;
$$;

revoke all on function public.admin_list_players() from public;
grant execute on function public.admin_list_players() to authenticated;
