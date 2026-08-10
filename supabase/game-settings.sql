-- Configuração de manipulação: a cada N apostas, 1 vitória do jogador
create table if not exists public.game_settings (
  id integer primary key default 1 check (id = 1),
  enabled boolean not null default true,
  bets_per_player_win integer not null default 20 check (bets_per_player_win >= 1),
  bet_counter bigint not null default 0,
  updated_at timestamptz not null default now()
);

insert into public.game_settings (id, enabled, bets_per_player_win, bet_counter)
values (1, true, 20, 0)
on conflict (id) do nothing;

alter table public.game_settings enable row level security;

drop policy if exists "settings_select_authenticated" on public.game_settings;
create policy "settings_select_authenticated"
  on public.game_settings for select
  to authenticated
  using (true);

revoke insert, update, delete on public.game_settings from authenticated, anon;
grant select on public.game_settings to authenticated;

create or replace function public.get_game_settings()
returns public.game_settings
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.game_settings;
begin
  select * into row from public.game_settings where id = 1;
  if not found then
    insert into public.game_settings (id) values (1)
    returning * into row;
  end if;
  return row;
end;
$$;

revoke all on function public.get_game_settings() from public;
grant execute on function public.get_game_settings() to authenticated;

create or replace function public.admin_update_game_settings(
  p_enabled boolean,
  p_bets_per_player_win integer
)
returns public.game_settings
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.game_settings;
begin
  if not public.is_admin() then
    raise exception 'Apenas admin';
  end if;
  if p_bets_per_player_win is null or p_bets_per_player_win < 1 then
    raise exception 'Intervalo inválido';
  end if;

  update public.game_settings
  set
    enabled = coalesce(p_enabled, enabled),
    bets_per_player_win = p_bets_per_player_win,
    updated_at = now()
  where id = 1
  returning * into row;

  if not found then
    insert into public.game_settings (id, enabled, bets_per_player_win)
    values (1, coalesce(p_enabled, true), p_bets_per_player_win)
    returning * into row;
  end if;

  return row;
end;
$$;

revoke all on function public.admin_update_game_settings(boolean, integer) from public;
grant execute on function public.admin_update_game_settings(boolean, integer) to authenticated;

create or replace function public.admin_reset_bet_counter()
returns public.game_settings
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.game_settings;
begin
  if not public.is_admin() then
    raise exception 'Apenas admin';
  end if;

  update public.game_settings
  set bet_counter = 0, updated_at = now()
  where id = 1
  returning * into row;

  if not found then
    insert into public.game_settings (id) values (1)
    returning * into row;
  end if;

  return row;
end;
$$;

revoke all on function public.admin_reset_bet_counter() from public;
grant execute on function public.admin_reset_bet_counter() to authenticated;

-- Retorna 'player' | 'bank' | 'fair'
-- Quando ativo: a cada N apostas, exatamente 1 é vitória do jogador (a N-ésima).
create or replace function public.next_bet_outcome()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.game_settings;
  n integer;
begin
  if auth.uid() is null then
    return 'fair';
  end if;

  select * into s from public.game_settings where id = 1 for update;
  if not found then
    insert into public.game_settings (id) values (1)
    returning * into s;
  end if;

  if not s.enabled then
    return 'fair';
  end if;

  n := greatest(1, s.bets_per_player_win);

  update public.game_settings
  set bet_counter = bet_counter + 1, updated_at = now()
  where id = 1
  returning * into s;

  if (s.bet_counter % n) = 0 then
    return 'player';
  end if;

  return 'bank';
end;
$$;

revoke all on function public.next_bet_outcome() from public;
grant execute on function public.next_bet_outcome() to authenticated;
