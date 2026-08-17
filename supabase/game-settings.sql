-- Manipulação por RTP (%): chance de vitória do jogador a cada aposta
-- Rode este arquivo no SQL Editor do Supabase (substitui o modelo antigo "1 a cada N").

-- 1) Tabela base (só cria se ainda não existir — estrutura mínima compatível)
create table if not exists public.game_settings (
  id integer primary key default 1 check (id = 1),
  enabled boolean not null default true,
  bets_per_player_win integer not null default 20,
  bet_counter bigint not null default 0,
  updated_at timestamptz not null default now()
);

-- 2) Garante a linha singleton antes de migrar colunas
insert into public.game_settings (id, enabled, bets_per_player_win, bet_counter)
values (1, true, 20, 0)
on conflict (id) do nothing;

-- 3) Migração: adiciona colunas novas se faltarem
alter table public.game_settings
  add column if not exists rtp_percent integer;

alter table public.game_settings
  add column if not exists player_win_counter bigint;

alter table public.game_settings
  add column if not exists maintenance boolean;

-- 4) Preenche valores nulos (migra do modelo antigo: 1/N ≈ 100/N %)
update public.game_settings
set rtp_percent = greatest(
  0,
  least(100, round(100.0 / greatest(1, coalesce(bets_per_player_win, 20)))::integer)
)
where rtp_percent is null;

update public.game_settings
set player_win_counter = 0
where player_win_counter is null;

update public.game_settings
set maintenance = false
where maintenance is null;

-- 5) Defaults + NOT NULL
alter table public.game_settings
  alter column rtp_percent set default 20;

alter table public.game_settings
  alter column player_win_counter set default 0;

alter table public.game_settings
  alter column rtp_percent set not null;

alter table public.game_settings
  alter column player_win_counter set not null;

alter table public.game_settings
  alter column maintenance set default false;

alter table public.game_settings
  alter column maintenance set not null;

-- 6) Check 0–100 (idempotente)
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'game_settings_rtp_percent_check'
  ) then
    alter table public.game_settings
      add constraint game_settings_rtp_percent_check
      check (rtp_percent >= 0 and rtp_percent <= 100);
  end if;
end $$;

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

-- Troca o parâmetro p_bets_per_player_win → p_rtp_percent (exige DROP)
drop function if exists public.admin_update_game_settings(boolean, integer);

create or replace function public.admin_update_game_settings(
  p_enabled boolean,
  p_rtp_percent integer
)
returns public.game_settings
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.game_settings;
  rtp integer;
begin
  if not public.is_admin() then
    raise exception 'Apenas admin';
  end if;

  rtp := coalesce(p_rtp_percent, 20);
  if rtp < 0 or rtp > 100 then
    raise exception 'RTP inválido (use 0 a 100)';
  end if;

  update public.game_settings
  set
    enabled = coalesce(p_enabled, enabled),
    rtp_percent = rtp,
    updated_at = now()
  where id = 1
  returning * into row;

  if not found then
    insert into public.game_settings (id, enabled, rtp_percent)
    values (1, coalesce(p_enabled, true), rtp)
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
  set bet_counter = 0, player_win_counter = 0, updated_at = now()
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

create or replace function public.admin_set_maintenance(p_on boolean)
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
  set maintenance = coalesce(p_on, false), updated_at = now()
  where id = 1
  returning * into row;

  if not found then
    insert into public.game_settings (id, maintenance)
    values (1, coalesce(p_on, false))
    returning * into row;
  end if;

  return row;
end;
$$;

revoke all on function public.admin_set_maintenance(boolean) from public;
grant execute on function public.admin_set_maintenance(boolean) to authenticated;

-- Retorna 'player' | 'bank' | 'fair'
-- Quando ativo: sorteia com probabilidade rtp_percent% de vitória do jogador.
create or replace function public.next_bet_outcome()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  s public.game_settings;
  rtp integer;
  roll double precision;
  outcome text;
begin
  if auth.uid() is null then
    return 'fair';
  end if;

  select * into s from public.game_settings where id = 1 for update;
  if not found then
    insert into public.game_settings (id) values (1)
    returning * into s;
  end if;

  if coalesce(s.maintenance, false) then
    raise exception 'Site em manutenção';
  end if;

  if not s.enabled then
    return 'fair';
  end if;

  rtp := greatest(0, least(100, coalesce(s.rtp_percent, 20)));
  roll := random() * 100.0;

  if roll < rtp then
    outcome := 'player';
  else
    outcome := 'bank';
  end if;

  update public.game_settings
  set
    bet_counter = bet_counter + 1,
    player_win_counter = player_win_counter + case when outcome = 'player' then 1 else 0 end,
    updated_at = now()
  where id = 1;

  return outcome;
end;
$$;

revoke all on function public.next_bet_outcome() from public;
grant execute on function public.next_bet_outcome() to authenticated;
