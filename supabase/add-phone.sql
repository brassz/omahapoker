-- Adiciona telefone/celular ao perfil do jogador
-- Rode no Supabase SQL Editor

alter table public.profiles
  add column if not exists phone text;

-- Atualiza trigger de novo usuário para gravar o celular do metadata
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, display_name, phone, player_credits, bank_credits, is_admin)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)),
    nullif(trim(coalesce(new.raw_user_meta_data->>'phone', '')), ''),
    0,
    0,
    false
  )
  on conflict (id) do update
  set
    email = excluded.email,
    display_name = coalesce(nullif(excluded.display_name, ''), public.profiles.display_name),
    phone = coalesce(nullif(excluded.phone, ''), public.profiles.phone);
  return new;
end;
$$;

-- Inclui telefone na listagem do admin
drop function if exists public.admin_list_players();

create or replace function public.admin_list_players()
returns table (
  id uuid,
  email text,
  display_name text,
  phone text,
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
    p.phone::text,
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
