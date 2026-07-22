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
  breed text,
  gender text not null default 'Hen',
  dob date,
  expected_eggs_per_year int default 0,
  created_at timestamptz not null default now()
);

create table if not exists health_checks (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  chicken_id uuid references chickens(id) on delete set null,
  date date not null,
  items jsonb not null default '[]',
  created_at timestamptz not null default now()
);

-- ---------- Row level security ----------
alter table profiles enable row level security;
alter table collaborators enable row level security;
alter table eggs enable row level security;
alter table chickens enable row level security;
alter table health_checks enable row level security;

-- profiles: readable by any signed-in user (needed to resolve owner emails
-- in the sharing UI); only the owner can update their own row.
drop policy if exists "profiles readable" on profiles;
create policy "profiles readable" on profiles for select using (auth.uid() is not null);
drop policy if exists "profiles self update" on profiles;
create policy "profiles self update" on profiles for update using (id = auth.uid());

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
