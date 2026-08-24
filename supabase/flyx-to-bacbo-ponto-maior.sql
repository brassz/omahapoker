-- FLYX → Bacbo (exibido como Ponto Maior)
-- Rode no SQL Editor do Supabase.

-- Garante linha de RTP do bacbo
insert into public.game_rtp (game_id, enabled, rtp_percent)
select 'bacbo', false, coalesce((select rtp_percent from public.game_settings where id = 1), 20)
where not exists (select 1 from public.game_rtp where game_id = 'bacbo');

-- Se flyx tinha config própria, copia para bacbo (só se bacbo ainda default)
update public.game_rtp b
set
  enabled = f.enabled,
  rtp_percent = f.rtp_percent,
  bet_counter = f.bet_counter,
  player_win_counter = f.player_win_counter,
  updated_at = now()
from public.game_rtp f
where f.game_id = 'flyx'
  and b.game_id = 'bacbo'
  and b.enabled = false
  and b.bet_counter = 0;

delete from public.game_rtp where game_id in ('flyx', 'minas');

-- Manutenção: troca flyx/minas por bacbo
update public.game_settings
set maintenance_games = (
  select coalesce(array_agg(distinct g), '{}')
  from (
    select case
      when x in ('flyx', 'minas') then 'bacbo'
      else x
    end as g
    from unnest(maintenance_games) as x
  ) s
)
where maintenance_games && array['flyx', 'minas']::text[];

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
  if key in ('21_index', '21') then
    return '21';
  end if;
  if key in ('flyx', 'minas', 'ponto-maior', 'pontomaior', 'bacbo') then
    return 'bacbo';
  end if;
  return key;
end;
$$;

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
    'bacbo','ronda','caipira','21'
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
    'bacbo','ronda','caipira','21'
  ])
  order by 1;
end;
$$;
