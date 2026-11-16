-- Adiciona aposta máxima configurável pelo admin (0 a 5000)
-- Rode este arquivo no SQL Editor do Supabase.

-- 1) Coluna nova
alter table public.game_settings
  add column if not exists max_bet integer;

update public.game_settings
set max_bet = 200
where max_bet is null;

alter table public.game_settings
  alter column max_bet set default 200;

alter table public.game_settings
  alter column max_bet set not null;

-- 2) Check 0–5000
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'game_settings_max_bet_check'
  ) then
    alter table public.game_settings
      add constraint game_settings_max_bet_check
      check (max_bet >= 0 and max_bet <= 5000);
  end if;
end $$;

-- 3) Atualiza a RPC para aceitar p_max_bet
drop function if exists public.admin_update_game_settings(boolean, integer);
drop function if exists public.admin_update_game_settings(boolean, integer, integer);

create or replace function public.admin_update_game_settings(
  p_enabled boolean,
  p_rtp_percent integer,
  p_max_bet integer default null
)
returns public.game_settings
language plpgsql
security definer
set search_path = public
as $$
declare
  row public.game_settings;
  rtp integer;
  mb integer;
begin
  if not public.is_admin() then
    raise exception 'Apenas admin';
  end if;

  rtp := coalesce(p_rtp_percent, 20);
  if rtp < 0 or rtp > 100 then
    raise exception 'RTP inválido (use 0 a 100)';
  end if;

  mb := coalesce(p_max_bet, 200);
  if mb < 0 or mb > 5000 then
    raise exception 'Aposta máxima inválida (use 0 a 5000)';
  end if;

  update public.game_settings
  set
    enabled = coalesce(p_enabled, enabled),
    rtp_percent = rtp,
    max_bet = mb,
    updated_at = now()
  where id = 1
  returning * into row;

  if not found then
    insert into public.game_settings (id, enabled, rtp_percent, max_bet)
    values (1, coalesce(p_enabled, true), rtp, mb)
    returning * into row;
  end if;

  return row;
end;
$$;

revoke all on function public.admin_update_game_settings(boolean, integer, integer) from public;
grant execute on function public.admin_update_game_settings(boolean, integer, integer) to authenticated;
