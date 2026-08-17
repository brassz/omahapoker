-- Presença: qual jogo o jogador está na tela agora.
-- Rode no SQL Editor do Supabase.

alter table public.profiles
  add column if not exists current_game text;

alter table public.profiles
  add column if not exists game_seen_at timestamptz;

create or replace function public.set_player_presence(p_game text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  game text;
begin
  if auth.uid() is null then
    raise exception 'Não autenticado';
  end if;

  game := nullif(lower(trim(coalesce(p_game, ''))), '');
  if game is not null and length(game) > 40 then
    game := left(game, 40);
  end if;

  update public.profiles
  set
    current_game = game,
    game_seen_at = case when game is null then null else now() end
  where id = auth.uid();
end;
$$;

revoke all on function public.set_player_presence(text) from public;
grant execute on function public.set_player_presence(text) to authenticated;

drop function if exists public.admin_list_players();

create or replace function public.admin_list_players()
returns table (
  id uuid,
  email text,
  display_name text,
  phone text,
  player_credits numeric,
  is_admin boolean,
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
