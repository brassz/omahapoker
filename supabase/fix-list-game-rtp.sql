-- Corrige "column reference game_id is ambiguous" em list_game_rtp.
-- Rode de novo no SQL Editor do Supabase.

create table if not exists public.game_rtp (
  game_id text primary key,
  enabled boolean not null default false,
  rtp_percent integer not null default 20
    check (rtp_percent >= 0 and rtp_percent <= 100),
  bet_counter bigint not null default 0,
  player_win_counter bigint not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.game_rtp
  add column if not exists bet_counter bigint not null default 0,
  add column if not exists player_win_counter bigint not null default 0,
  add column if not exists updated_at timestamptz not null default now();

alter table public.game_rtp enable row level security;

drop policy if exists "game_rtp_select_authenticated" on public.game_rtp;
create policy "game_rtp_select_authenticated"
  on public.game_rtp for select
  to authenticated
  using (true);

revoke insert, update, delete on public.game_rtp from authenticated, anon;
grant select on public.game_rtp to authenticated;

insert into public.game_settings (id)
values (1)
on conflict (id) do nothing;

delete from public.game_rtp gr
where gr.game_id in ('maquininha', 'chuvadepremios', 'flyx', 'minas');

insert into public.game_rtp as gr (game_id, enabled, rtp_percent)
select g.id, false, coalesce((select s.rtp_percent from public.game_settings s where s.id = 1), 20)
from unnest(array[
  'omaha','crep','bacatela','roleta',
  'bacbo','ronda','caipira','21'
]) as g(id)
on conflict on constraint game_rtp_pkey do nothing;

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

revoke all on function public.list_game_rtp() from public;
grant execute on function public.list_game_rtp() to authenticated;
