-- Chicken Keeper — Supabase schema & row-level security
-- Run this once in your Supabase project's SQL editor (Database > SQL Editor).

-- ---------- Profiles ----------
-- Mirrors auth.users so we can look people up by email for sharing invites.
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  created_at timestamptz not null default now()
);

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  insert into public.profiles (id, email) values (new.id, new.email)
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- ---------- Sharing ----------
-- A row here means "owner_id has granted invited_email the given role".
-- Once the invited person signs up / logs in with a matching email, the
-- app links accepted_user_id and flips status to 'accepted'.
create table if not exists collaborators (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  invited_email text not null,
  role text not null check (role in ('viewer','editor')),
  accepted_user_id uuid references auth.users(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  unique (owner_id, invited_email)
);

-- True if the current user may access target_owner's flock data.
-- min_role 'editor' requires an editor grant (or being the owner);
-- min_role 'viewer' (default) allows either role, or the owner.
create or replace function public.has_flock_access(target_owner uuid, min_role text default 'viewer')
returns boolean
language sql
stable
security definer set search_path = public
as $$
  select
    target_owner = auth.uid()
    or exists (
      select 1 from collaborators c
      where c.owner_id = target_owner
        and c.accepted_user_id = auth.uid()
        and c.status = 'accepted'
        and (min_role = 'viewer' or c.role = 'editor')
    );
$$;

-- ---------- App data ----------
create table if not exists eggs (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  date date not null,
  total int not null default 0,
  cracked int not null default 0,
  created_at timestamptz not null default now(),
  unique (owner_id, date)
);

create table if not exists chickens (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  tag text,
  tag_colour text,
  animal_type text not null default 'Chicken',
  breed text,
  gender text not null default 'Hen',
  dob date,
  expected_eggs_per_year int default 0,
  egg_colour text,
  notes text,
  is_deceased boolean not null default false,
  deceased_date date,
  created_at timestamptz not null default now()
);

-- Safe to re-run against a chickens table created before these columns existed.
alter table chickens add column if not exists egg_colour text;
alter table chickens add column if not exists notes text;
alter table chickens add column if not exists is_deceased boolean not null default false;
alter table chickens add column if not exists deceased_date date;
alter table chickens add column if not exists animal_type text not null default 'Chicken';

create table if not exists health_checks (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  chicken_id uuid references chickens(id) on delete set null,
  date date not null,
  items jsonb not null default '[]',
  created_at timestamptz not null default now()
);

-- ---------- Coops ----------
create table if not exists coops (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now()
);

alter table chickens add column if not exists coop_id uuid references coops(id) on delete set null;

-- ---------- Breeds ----------
-- User-defined breed presets per animal type, shown alongside the app's
-- built-in chicken breed list when picking a breed on the animal form.
create table if not exists breeds (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  animal_type text not null default 'Chicken',
  name text not null,
  expected_eggs_per_year int not null default 0,
  egg_colour text,
  created_at timestamptz not null default now()
);

-- ---------- Sales ----------
create table if not exists customers (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists sales (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  customer_id uuid references customers(id) on delete set null,
  date date not null,
  unit text not null default 'egg' check (unit in ('egg','half_dozen','dozen')),
  quantity numeric not null default 0,
  charged numeric not null default 0,
  paid numeric not null default 0,
  created_at timestamptz not null default now()
);

-- One row per flock owner. enabled/standard_unit/prices configured from the
-- Account tab; readable/writable by anyone with flock access so collaborators
-- see the same settings as the owner.
create table if not exists sales_settings (
  owner_id uuid primary key references auth.users(id) on delete cascade,
  enabled boolean not null default false,
  standard_unit text not null default 'dozen' check (standard_unit in ('egg','half_dozen','dozen')),
  price_egg numeric not null default 0,
  price_half_dozen numeric not null default 0,
  price_dozen numeric not null default 0,
  updated_at timestamptz not null default now()
);

-- ---------- Account deletion ----------
-- Lets a signed-in user permanently delete their own account. All of
-- profiles, collaborators (both as owner and as an accepted
-- collaborator elsewhere), eggs, chickens and health_checks reference
-- auth.users(id) on delete cascade, so removing the auth.users row
-- takes everything with it in one step.
create or replace function public.delete_own_account()
returns void
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  delete from auth.users where id = auth.uid();
end;
$$;

grant execute on function public.delete_own_account() to authenticated;

-- ---------- Row level security ----------
alter table profiles enable row level security;
alter table collaborators enable row level security;
alter table eggs enable row level security;
alter table chickens enable row level security;
alter table health_checks enable row level security;
alter table coops enable row level security;
alter table breeds enable row level security;
alter table customers enable row level security;
alter table sales enable row level security;
alter table sales_settings enable row level security;

-- profiles: readable by any signed-in user (needed to resolve owner emails
-- in the sharing UI); only the owner can update their own row.
drop policy if exists "profiles readable" on profiles;
create policy "profiles readable" on profiles for select using (auth.uid() is not null);
drop policy if exists "profiles self update" on profiles;
create policy "profiles self update" on profiles for update using (id = auth.uid());
drop policy if exists "profiles self insert" on profiles;
create policy "profiles self insert" on profiles for insert with check (id = auth.uid());

-- collaborators: the flock owner manages their own grants; an invited
-- user can see and accept (update) the invite addressed to their email.
drop policy if exists "collab owner manage" on collaborators;
create policy "collab owner manage" on collaborators for all
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists "collab invitee view" on collaborators;
create policy "collab invitee view" on collaborators for select
  using (invited_email = (select email from profiles where id = auth.uid()));
drop policy if exists "collab invitee accept" on collaborators;
create policy "collab invitee accept" on collaborators for update
  using (invited_email = (select email from profiles where id = auth.uid()))
  with check (invited_email = (select email from profiles where id = auth.uid()));

-- eggs / chickens / health_checks: same read/write shape, gated by role.
drop policy if exists "eggs read" on eggs;
create policy "eggs read" on eggs for select using (has_flock_access(owner_id));
drop policy if exists "eggs write" on eggs;
create policy "eggs write" on eggs for insert with check (has_flock_access(owner_id, 'editor'));
drop policy if exists "eggs update" on eggs;
create policy "eggs update" on eggs for update using (has_flock_access(owner_id, 'editor'));
drop policy if exists "eggs delete" on eggs;
create policy "eggs delete" on eggs for delete using (has_flock_access(owner_id, 'editor'));

drop policy if exists "chickens read" on chickens;
create policy "chickens read" on chickens for select using (has_flock_access(owner_id));
drop policy if exists "chickens write" on chickens;
create policy "chickens write" on chickens for insert with check (has_flock_access(owner_id, 'editor'));
drop policy if exists "chickens update" on chickens;
create policy "chickens update" on chickens for update using (has_flock_access(owner_id, 'editor'));
drop policy if exists "chickens delete" on chickens;
create policy "chickens delete" on chickens for delete using (has_flock_access(owner_id, 'editor'));

drop policy if exists "hc read" on health_checks;
create policy "hc read" on health_checks for select using (has_flock_access(owner_id));
drop policy if exists "hc write" on health_checks;
create policy "hc write" on health_checks for insert with check (has_flock_access(owner_id, 'editor'));
drop policy if exists "hc update" on health_checks;
create policy "hc update" on health_checks for update using (has_flock_access(owner_id, 'editor'));
drop policy if exists "hc delete" on health_checks;
create policy "hc delete" on health_checks for delete using (has_flock_access(owner_id, 'editor'));

-- coops / customers / sales / sales_settings: same read/write shape, gated by role.
drop policy if exists "coops read" on coops;
create policy "coops read" on coops for select using (has_flock_access(owner_id));
drop policy if exists "coops write" on coops;
create policy "coops write" on coops for insert with check (has_flock_access(owner_id, 'editor'));
drop policy if exists "coops update" on coops;
create policy "coops update" on coops for update using (has_flock_access(owner_id, 'editor'));
drop policy if exists "coops delete" on coops;
create policy "coops delete" on coops for delete using (has_flock_access(owner_id, 'editor'));

drop policy if exists "breeds read" on breeds;
create policy "breeds read" on breeds for select using (has_flock_access(owner_id));
drop policy if exists "breeds write" on breeds;
create policy "breeds write" on breeds for insert with check (has_flock_access(owner_id, 'editor'));
drop policy if exists "breeds update" on breeds;
create policy "breeds update" on breeds for update using (has_flock_access(owner_id, 'editor'));
drop policy if exists "breeds delete" on breeds;
create policy "breeds delete" on breeds for delete using (has_flock_access(owner_id, 'editor'));

drop policy if exists "customers read" on customers;
create policy "customers read" on customers for select using (has_flock_access(owner_id));
drop policy if exists "customers write" on customers;
create policy "customers write" on customers for insert with check (has_flock_access(owner_id, 'editor'));
drop policy if exists "customers update" on customers;
create policy "customers update" on customers for update using (has_flock_access(owner_id, 'editor'));
drop policy if exists "customers delete" on customers;
create policy "customers delete" on customers for delete using (has_flock_access(owner_id, 'editor'));

drop policy if exists "sales read" on sales;
create policy "sales read" on sales for select using (has_flock_access(owner_id));
drop policy if exists "sales write" on sales;
create policy "sales write" on sales for insert with check (has_flock_access(owner_id, 'editor'));
drop policy if exists "sales update" on sales;
create policy "sales update" on sales for update using (has_flock_access(owner_id, 'editor'));
drop policy if exists "sales delete" on sales;
create policy "sales delete" on sales for delete using (has_flock_access(owner_id, 'editor'));

drop policy if exists "sales_settings read" on sales_settings;
create policy "sales_settings read" on sales_settings for select using (has_flock_access(owner_id));
drop policy if exists "sales_settings write" on sales_settings;
create policy "sales_settings write" on sales_settings for insert with check (has_flock_access(owner_id, 'editor'));
drop policy if exists "sales_settings update" on sales_settings;
create policy "sales_settings update" on sales_settings for update using (has_flock_access(owner_id, 'editor'));
