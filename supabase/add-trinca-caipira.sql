-- Adiciona Trinca Caipira e atualiza lista de jogos (RTP / manutenção).
-- Rode no SQL Editor do Supabase.

insert into public.game_rtp (game_id, enabled, rtp_percent)
select 'trincacaipira', false, coalesce((select s.rtp_percent from public.game_settings s where s.id = 1), 20)
where not exists (select 1 from public.game_rtp where game_id = 'trincacaipira');

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
  if key in ('bagatela', 'bacatela') then
    return 'bacatela';
  end if;
  if key in ('21_index', '21', '21caipira', '21-caipira') then
    return '21';
  end if;
  if key in ('flyx', 'minas', 'ponto-maior', 'pontomaior', 'bacbo') then
    return 'bacbo';
  end if;
  if key in ('trinca', 'trinca-caipira', 'trincacaipira') then
    return 'trincacaipira';
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
    'omaha','crep','bacatela','roleta',
    'bacbo','ronda','caipira','21','trincacaipira'
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
    'omaha','crep','bacatela','roleta',
    'bacbo','ronda','caipira','21','trincacaipira'
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
    'omaha', 'crep', 'bacatela', 'roleta',
    'bacbo', 'ronda', 'caipira', '21', 'trincacaipira'
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
