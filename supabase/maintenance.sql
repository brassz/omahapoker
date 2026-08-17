-- Modo manutenção: fecha todos os jogos para os jogadores.
-- Rode este arquivo no SQL Editor do Supabase.

alter table public.game_settings
  add column if not exists maintenance boolean;

update public.game_settings
set maintenance = false
where maintenance is null;

alter table public.game_settings
  alter column maintenance set default false;

alter table public.game_settings
  alter column maintenance set not null;

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
