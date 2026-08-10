-- Omaha Poker — schema inicial
-- Perfis de usuário + histórico de mãos

create extension if not exists "pgcrypto";

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text,
  display_name text,
  player_credits numeric(14,2) not null default 0 check (player_credits >= 0),
  bank_credits numeric(14,2) not null default 0 check (bank_credits >= 0),
  is_admin boolean not null default false,
  hands_played integer not null default 0 check (hands_played >= 0),
  hands_won integer not null default 0 check (hands_won >= 0),
  hands_lost integer not null default 0 check (hands_lost >= 0),
  hands_folded integer not null default 0 check (hands_folded >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.game_hands (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  bet_amount numeric(14,2) not null default 0,
  result text not null check (result in ('player', 'bank', 'tie', 'fold')),
  player_hand jsonb,
  bank_hand jsonb,
  board jsonb,
  player_hand_name text,
  bank_hand_name text,
  fold_fee numeric(14,2) default 0,
  created_at timestamptz not null default now()
);

create index if not exists game_hands_user_id_created_at_idx
  on public.game_hands (user_id, created_at desc);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists profiles_set_updated_at on public.profiles;
create trigger profiles_set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.profiles (id, email, display_name, player_credits, bank_credits, is_admin)
  values (
    new.id,
    new.email,
    coalesce(new.raw_user_meta_data->>'display_name', split_part(new.email, '@', 1)),
    0,
    0,
    false
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

alter table public.profiles enable row level security;
alter table public.game_hands enable row level security;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    (select is_admin from public.profiles where id = auth.uid()),
    false
  );
$$;

drop policy if exists "profiles_select_own" on public.profiles;
create policy "profiles_select_own"
  on public.profiles for select
  to authenticated
  using (auth.uid() = id or public.is_admin());

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own"
  on public.profiles for update
  to authenticated
  using (auth.uid() = id or public.is_admin())
  with check (auth.uid() = id or public.is_admin());

drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own"
  on public.profiles for insert
  to authenticated
  with check (auth.uid() = id);

drop policy if exists "hands_select_own" on public.game_hands;
create policy "hands_select_own"
  on public.game_hands for select
  to authenticated
  using (auth.uid() = user_id);

drop policy if exists "hands_insert_own" on public.game_hands;
create policy "hands_insert_own"
  on public.game_hands for insert
  to authenticated
  with check (auth.uid() = user_id);

grant usage on schema public to anon, authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select, insert on public.game_hands to authenticated;

-- Manipulação (a cada N apostas, 1 vitória do jogador): ver também game-settings.sql
-- Rode supabase/game-settings.sql no projeto se ainda não existir.
