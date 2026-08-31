-- Adiciona MINES ao RTP e à manutenção.
-- Rode no SQL Editor do Supabase.

insert into public.game_rtp (game_id, enabled, rtp_percent)
select 'mines', false, coalesce((select s.rtp_percent from public.game_settings s where s.id = 1), 20)
where not exists (select 1 from public.game_rtp where game_id = 'mines');

create or replace function public.normalize_game_id(p_id text)
returns text
language plpgsql
immutable
as $$
declare
  key text;
begin
  key := lower(trim(coalesce(p_id, '')));
  key := regexp_replace(key, '\.html$', '');
  if key in ('bagatela', 'bacatela', 'bolaquente') then
    return 'bolaquente';
  end if;
  if key in ('21_index', '21', '21caipira', '21-caipira') then
    return '21';
  end if;
  if key in ('flyx', 'ponto-maior', 'pontomaior', 'bacbo') then
    return 'bacbo';
  end if;
  if key in ('minas', 'mine') then
    return 'mines';
  end if;
  if key in ('trinca', 'trinca-caipira', 'trincacaipira') then
    return 'trincacaipira';
  end if;
  if key in ('bacara', 'baccarat', 'bakara') then
    return 'baccarat';
  end if;
  if key in ('caribbean', 'caribbeanstud', 'caribbean-stud', 'caribe') then
    return 'caribbean';
  end if;
  return key;
end;
$$;

drop function if exists public.list_game_rtp();

create or replace function public.list_game_rtp()
returns table (
  game_id text,
  enabled boolean,
  rtp_percent integer,
  bet_counter bigint,
  player_win_counter bigint
)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  insert into public.game_rtp as gr (game_id, enabled, rtp_percent)
  select g.id, false, coalesce((select s.rtp_percent from public.game_settings s where s.id = 1), 20)
  from unnest(array[
    'omaha','crep','bolaquente','roleta',
    'bacbo','ronda','caipira','21','trincacaipira','baccarat','caribbean','mines'
  ]) as g(id)
  on conflict on constraint game_rtp_pkey do nothing;

  return query
  select
    gr.game_id,
    gr.enabled,
    gr.rtp_percent,
    gr.bet_counter,
    gr.player_win_counter
  from public.game_rtp as gr
  where gr.game_id = any(array[
    'omaha','crep','bolaquente','roleta',
    'bacbo','ronda','caipira','21','trincacaipira','baccarat','caribbean','mines'
  ])
  order by 1;
end;
$$;

revoke all on function public.list_game_rtp() from public;
grant execute on function public.list_game_rtp() to authenticated;

create or replace function public.admin_set_maintenance_games(p_games text[])
returns public.game_settings
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.game_settings;
  allowed text[] := array[
    'omaha', 'crep', 'bolaquente', 'roleta',
    'bacbo', 'ronda', 'caipira', '21', 'trincacaipira', 'baccarat', 'caribbean', 'mines'
  ];
  cleaned text[];
begin
  if not public.is_admin() then
    raise exception 'Apenas admin';
  end if;

  select coalesce(array_agg(distinct g order by g), '{}')
  into cleaned
  from unnest(coalesce(p_games, '{}'::text[])) as g
  where g = any(allowed);

  update public.game_settings
  set
    maintenance_games = coalesce(cleaned, '{}'),
    maintenance = coalesce(array_length(cleaned, 1), 0) > 0,
    updated_at = now()
  where id = 1
  returning * into row;

  if not found then
    insert into public.game_settings (id, maintenance_games, maintenance)
    values (1, coalesce(cleaned, '{}'), coalesce(array_length(cleaned, 1), 0) > 0)
    returning * into row;
  end if;

  return row;
end;
$$;
