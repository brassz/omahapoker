-- Manutenção por jogo (selecione quais salas ficam fechadas).
-- Rode no SQL Editor do Supabase.

alter table public.game_settings
  add column if not exists maintenance boolean;

alter table public.game_settings
  add column if not exists maintenance_games text[];

update public.game_settings
set maintenance = false
where maintenance is null;

update public.game_settings
set maintenance_games = '{}'
where maintenance_games is null;

alter table public.game_settings
  alter column maintenance set default false;

alter table public.game_settings
  alter column maintenance_games set default '{}';

alter table public.game_settings
  alter column maintenance set not null;

alter table public.game_settings
  alter column maintenance_games set not null;

-- Migra modo antigo (boolean = todos os jogos)
update public.game_settings
set maintenance_games = array[
  'omaha', 'crep', 'bolaquente', 'roleta',
  'bacbo', 'ronda', 'caipira', '21', 'trincacaipira', 'baccarat', 'caribbean', 'penalti'
]::text[]
where maintenance = true
  and maintenance_games = '{}';

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
    'bacbo', 'ronda', 'caipira', '21', 'trincacaipira', 'baccarat', 'caribbean', 'penalti'
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

revoke all on function public.admin_set_maintenance_games(text[]) from public;
grant execute on function public.admin_set_maintenance_games(text[]) to authenticated;

-- Compat: RPC antigo vira "todos" ou "nenhum"
create or replace function public.admin_set_maintenance(p_on boolean)
returns public.game_settings
language plpgsql
security definer
set search_path = public
as $$
begin
  if coalesce(p_on, false) then
    return public.admin_set_maintenance_games(array[
      'omaha', 'crep', 'bolaquente', 'roleta',
      'bacbo', 'ronda', 'caipira', '21', 'trincacaipira', 'baccarat', 'caribbean', 'penalti'
    ]::text[]);
  end if;
  return public.admin_set_maintenance_games('{}'::text[]);
end;
$$;

revoke all on function public.admin_set_maintenance(boolean) from public;
grant execute on function public.admin_set_maintenance(boolean) to authenticated;
