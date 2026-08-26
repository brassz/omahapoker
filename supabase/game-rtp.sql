-- Manipulação por jogo: RTP (%) independente para cada sala.
-- Rode no SQL Editor do Supabase DEPOIS de game-settings.sql.

create table if not exists public.game_rtp (
  game_id text primary key,
  enabled boolean not null default false,
  rtp_percent integer not null default 20
    check (rtp_percent >= 0 and rtp_percent <= 100),
  bet_counter bigint not null default 0,
  player_win_counter bigint not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.game_rtp enable row level security;

drop policy if exists "game_rtp_select_authenticated" on public.game_rtp;
create policy "game_rtp_select_authenticated"
  on public.game_rtp for select
  to authenticated
  using (true);

revoke insert, update, delete on public.game_rtp from authenticated, anon;
grant select on public.game_rtp to authenticated;

insert into public.game_rtp (game_id, enabled, rtp_percent)
select g.id, false, coalesce((select rtp_percent from public.game_settings where id = 1), 20)
from (
  values
    ('omaha'),
    ('crep'),
    ('bolaquente'),
    ('roleta'),
    ('bacbo'),
    ('ronda'),
    ('caipira'),
    ('21'),
    ('trincacaipira')
) as g(id)
on conflict (game_id) do nothing;

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
  if key in ('trinca', 'trinca-caipira', 'trincacaipira') then
    return 'trincacaipira';
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
    'omaha','crep','bolaquente','roleta',
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
  order by 1;
end;
$$;

revoke all on function public.list_game_rtp() from public;
grant execute on function public.list_game_rtp() to authenticated;

-- Troca o retorno (composite → json) exige DROP antes do CREATE.
drop function if exists public.admin_upsert_game_rtp(text, boolean, integer);

create or replace function public.admin_upsert_game_rtp(
  p_game_id text,
  p_enabled boolean,
  p_rtp_percent integer
)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  gid text;
  rtp integer;
  rec public.game_rtp;
begin
  if not public.is_admin() then
    raise exception 'Apenas admin';
  end if;

  gid := public.normalize_game_id(p_game_id);
  if gid is null or gid = '' then
    raise exception 'Jogo inválido';
  end if;

  rtp := coalesce(p_rtp_percent, 20);
  if rtp < 0 or rtp > 100 then
    raise exception 'RTP inválido (use 0 a 100)';
  end if;

  insert into public.game_rtp (game_id, enabled, rtp_percent, updated_at)
  values (gid, coalesce(p_enabled, true), rtp, now())
  on conflict (game_id) do update
  set
    enabled = excluded.enabled,
    rtp_percent = excluded.rtp_percent,
    updated_at = now()
  returning * into rec;

  return json_build_object(
    'game_id', rec.game_id,
    'enabled', rec.enabled,
    'rtp_percent', rec.rtp_percent,
    'bet_counter', rec.bet_counter,
    'player_win_counter', rec.player_win_counter
  );
end;
$$;

revoke all on function public.admin_upsert_game_rtp(text, boolean, integer) from public;
grant execute on function public.admin_upsert_game_rtp(text, boolean, integer) to authenticated;

drop function if exists public.next_bet_outcome();
drop function if exists public.next_bet_outcome(text);

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

  -- Mesmo padrão da geral: chance rtp% de 'player', senão 'bank'.
  -- Próprio=SIM → usa o RTP % daquele jogo.
  -- Próprio=NÃO → só se a geral estiver ligada (RTP da geral).
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

  -- Contador global só quando a decisão veio da geral
  if not use_own then
    update public.game_settings
    set
      bet_counter = bet_counter + 1,
      player_win_counter = player_win_counter + case when outcome = 'player' then 1 else 0 end,
      updated_at = now()
    where id = 1;
  end if;

  -- Contador do jogo só quando próprio=SIM (estatística por sala)
  if use_own and g.game_id is not null then
    update public.game_rtp
    set
      bet_counter = bet_counter + 1,
      player_win_counter = player_win_counter + case when outcome = 'player' then 1 else 0 end,
      updated_at = now()
    where game_id = gid;
  elsif not use_own and gid is not null and gid <> '' and g.game_id is not null then
    -- Geral ativa: também registra no jogo para o painel (sem misturar RTP)
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
