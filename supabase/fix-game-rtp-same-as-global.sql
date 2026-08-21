-- Manipulação por jogo com RTP próprio, no MESMO padrão da geral
-- (chance = RTP% de 'player', senão 'bank'). Contadores separados.
-- Rode no SQL Editor do Supabase.

create or replace function public.next_bet_outcome(p_game_id text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.game_settings;
  g public.game_rtp;
  gid text;
  rtp integer;
  roll double precision;
  outcome text;
  use_own boolean;
begin
  if auth.uid() is null then
    return 'fair';
  end if;

  select * into s from public.game_settings where id = 1 for update;
  if not found then
    insert into public.game_settings (id) values (1)
    returning * into s;
  end if;

  if coalesce(s.maintenance, false)
     and coalesce(array_length(s.maintenance_games, 1), 0) = 0 then
    raise exception 'Site em manutenção';
  end if;

  gid := public.normalize_game_id(p_game_id);
  use_own := false;

  if gid is not null and gid <> '' then
    insert into public.game_rtp (game_id, enabled, rtp_percent)
    values (gid, false, coalesce(s.rtp_percent, 20))
    on conflict (game_id) do nothing;

    select * into g from public.game_rtp where game_id = gid for update;
    use_own := coalesce(g.enabled, false);
  end if;

  if use_own then
    rtp := greatest(0, least(100, coalesce(g.rtp_percent, 20)));
  elsif coalesce(s.enabled, false) then
    rtp := greatest(0, least(100, coalesce(s.rtp_percent, 20)));
  else
    return 'fair';
  end if;

  roll := random() * 100.0;
  if roll < rtp then
    outcome := 'player';
  else
    outcome := 'bank';
  end if;

  if not use_own then
    update public.game_settings
    set
      bet_counter = bet_counter + 1,
      player_win_counter = player_win_counter + case when outcome = 'player' then 1 else 0 end,
      updated_at = now()
    where id = 1;
  end if;

  if gid is not null and gid <> '' and g.game_id is not null
     and (use_own or coalesce(s.enabled, false)) then
    update public.game_rtp
    set
      bet_counter = bet_counter + 1,
      player_win_counter = player_win_counter + case when outcome = 'player' then 1 else 0 end,
      updated_at = now()
    where game_id = gid;
  end if;

  return outcome;
end;
$$;

revoke all on function public.next_bet_outcome(text) from public;
grant execute on function public.next_bet_outcome(text) to authenticated;

create or replace function public.next_bet_outcome()
returns text
language plpgsql
security definer
set search_path = public
as $$
begin
  return public.next_bet_outcome(null);
end;
$$;

revoke all on function public.next_bet_outcome() from public;
grant execute on function public.next_bet_outcome() to authenticated;
