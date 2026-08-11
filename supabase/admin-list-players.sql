-- Lista todos os clientes no painel admin + cria profiles faltantes
-- (contas em auth.users sem linha em public.profiles deixavam de aparecer)
-- Rode este SQL no Supabase SQL Editor.

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
set search_path = public, auth
as $$
begin
  if not public.is_admin() then
    raise exception 'Apenas administradores podem listar jogadores';
  end if;

  -- Recupera contas órfãs: existem no Auth, mas não têm profile
  insert into public.profiles (id, email, display_name, player_credits, bank_credits, is_admin)
  select
    u.id,
    u.email,
    coalesce(
      nullif(u.raw_user_meta_data->>'display_name', ''),
      nullif(split_part(coalesce(u.email, ''), '@', 1), ''),
      'Jogador'
    ),
    0,
    0,
    false
  from auth.users u
  where not exists (
    select 1 from public.profiles p where p.id = u.id
  )
  on conflict (id) do nothing;

  -- Atualiza e-mail/nome vazios a partir do Auth
  update public.profiles p
  set
    email = coalesce(nullif(p.email, ''), u.email, p.email),
    display_name = coalesce(
      nullif(p.display_name, ''),
      nullif(u.raw_user_meta_data->>'display_name', ''),
      nullif(split_part(coalesce(u.email, p.email, ''), '@', 1), ''),
      p.display_name
    )
  from auth.users u
  where u.id = p.id
    and (
      p.email is null or p.email = ''
      or p.display_name is null or p.display_name = ''
    );

  return query
  select
    p.id,
    p.email,
    p.display_name,
    p.player_credits,
    p.is_admin,
    p.created_at,
    p.updated_at
  from public.profiles p
  order by p.created_at desc nulls last, p.email asc nulls last;
end;
$$;

revoke all on function public.admin_list_players() from public;
grant execute on function public.admin_list_players() to authenticated;
