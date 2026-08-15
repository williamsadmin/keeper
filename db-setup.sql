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
-- Multiple entries per day are allowed (e.g. a morning and evening
-- collection), so there is no uniqueness constraint on (owner_id, date).
create table if not exists eggs (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  date date not null,
  total int not null default 0,
  cracked int not null default 0,
  created_at timestamptz not null default now()
);

-- Drops the old one-entry-per-day constraint for installs created before
-- multiple daily entries were supported.
alter table eggs drop constraint if exists eggs_owner_id_date_key;

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

-- ---------- Categories (Poultry vs Livestock) ----------
-- Drives the top-level Poultry / Livestock split. Existing rows default
-- to 'poultry'; livestock animal types are backfilled to 'livestock' below.
alter table chickens add column if not exists category text not null default 'poultry' check (category in ('poultry','livestock'));
update chickens set category = 'livestock' where animal_type in ('Sheep','Goat','Cow','Pig') and category = 'poultry';

-- How precisely the date of birth is known — a full date, just a month and
-- year, or just a year. dob still stores a real date (the 1st of the month,
-- or 1 Jan of the year) so age/sort calculations keep working unchanged;
-- dob_precision only controls how it's displayed.
alter table chickens add column if not exists dob_precision text not null default 'day' check (dob_precision in ('day','month','year'));

-- Optional pedigree info (livestock only). Sire/dam are free-text names,
-- optionally linked to another animal row via sire_id/dam_id when the
-- parent is also tracked in the app (the text column still gets a copy of
-- the linked animal's name so display never needs a live join). Grandparents
-- stay free-text only, since going another generation back is rarely tracked
-- as its own animal record.
alter table chickens add column if not exists registered_pedigree boolean not null default false;
alter table chickens add column if not exists sire text;
alter table chickens add column if not exists dam text;
alter table chickens add column if not exists sire_id uuid references chickens(id) on delete set null;
alter table chickens add column if not exists dam_id uuid references chickens(id) on delete set null;
alter table chickens add column if not exists sire_sire text;
alter table chickens add column if not exists sire_dam text;
alter table chickens add column if not exists dam_sire text;
alter table chickens add column if not exists dam_dam text;

-- Livestock only. A breeding/registration flock name chosen per animal,
-- independent of which physical coop/group they're currently kept in —
-- shown as a prefix before the animal's own name.
alter table chickens add column if not exists flock_name text;

create table if not exists health_checks (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  chicken_id uuid references chickens(id) on delete set null,
  date date not null,
  items jsonb not null default '[]',
  created_at timestamptz not null default now()
);

-- Which checklist (Poultry or Sheep & Goats) this record was checked against.
alter table health_checks add column if not exists category text not null default 'poultry' check (category in ('poultry','livestock'));

-- ---------- Coops ----------
-- Shown as "Coop" for poultry and "Group" for Sheep & Goats, driven by category.
create table if not exists coops (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now()
);

alter table coops add column if not exists category text not null default 'poultry' check (category in ('poultry','livestock'));

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

-- Comma-separated list of colours for this breed (livestock only) — offered
-- as a dropdown on the animal form once a breed with colours is selected.
alter table breeds add column if not exists colours text not null default '';

-- Typical age (in weeks) at which this breed starts laying (poultry only).
-- Used to adjust a bird's contribution to the flock's expected-eggs totals
-- until they reach point of lay, and to show an expected start date.
alter table breeds add column if not exists point_of_lay_weeks int not null default 0;

-- ---------- Sales ----------
-- price_egg/price_half_dozen/price_dozen are per-customer price overrides;
-- null means "charge this customer the standard price set in sales_settings".
create table if not exists customers (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  name text not null,
  notes text,
  price_egg numeric,
  price_half_dozen numeric,
  price_dozen numeric,
  created_at timestamptz not null default now()
);

alter table customers add column if not exists price_egg numeric;
alter table customers add column if not exists price_half_dozen numeric;
alter table customers add column if not exists price_dozen numeric;

-- Free-text address, searchable alongside name when picking a customer.
alter table customers add column if not exists address text;

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

-- Optional attribution to which coop the eggs came from, for profit/loss
-- broken down by coop against purchases.
alter table sales add column if not exists coop_id uuid references coops(id) on delete set null;

-- Ledger of free/promotional stock owed to a customer, e.g. "2 dozen boxes
-- from a referral". Positive quantity adds credit owed; negative quantity
-- records it being claimed. Deleted along with the customer it belongs to.
create table if not exists customer_credits (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  customer_id uuid not null references customers(id) on delete cascade,
  unit text not null default 'dozen' check (unit in ('egg','half_dozen','dozen')),
  quantity numeric not null default 0,
  date date not null,
  note text,
  created_at timestamptz not null default now()
);

-- One row per flock owner. enabled/standard_unit/prices configured from the
-- Account tab; readable/writable by anyone with flock access so collaborators
-- see the same settings as the owner.
create table if not exists sales_settings (
  owner_id uuid primary key references auth.users(id) on delete cascade,
  enabled boolean not null default false,
  allow_egg_sales boolean not null default false,
  standard_unit text not null default 'dozen' check (standard_unit in ('egg','half_dozen','dozen')),
  price_egg numeric not null default 0,
  price_half_dozen numeric not null default 0,
  price_dozen numeric not null default 0,
  updated_at timestamptz not null default now()
);

-- Off by default: charging per single egg is opt-in, hidden everywhere until enabled.
alter table sales_settings add column if not exists allow_egg_sales boolean not null default false;

-- ---------- Sheep & Goats sales ----------
-- Tick-list of which output types are sold, each with its own price. Meat
-- and live animals are kept as separate sellable types.
create table if not exists livestock_sales_settings (
  owner_id uuid primary key references auth.users(id) on delete cascade,
  sell_wool boolean not null default false,
  sell_milk boolean not null default false,
  sell_meat boolean not null default false,
  sell_live_animals boolean not null default false,
  price_wool numeric not null default 0,
  price_milk numeric not null default 0,
  price_meat numeric not null default 0,
  price_live_animal numeric not null default 0,
  updated_at timestamptz not null default now()
);

create table if not exists livestock_sales (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  customer_id uuid references customers(id) on delete set null,
  date date not null,
  sale_type text not null default 'wool' check (sale_type in ('wool','milk','meat','live_animal')),
  quantity numeric not null default 0,
  charged numeric not null default 0,
  paid numeric not null default 0,
  created_at timestamptz not null default now()
);

-- Optional attribution to which flock this sale came from, for profit/loss
-- broken down by flock against purchases.
alter table livestock_sales add column if not exists coop_id uuid references coops(id) on delete set null;

-- ---------- Offspring (livestock) ----------
-- One row per animal per year, with a running male/female young count
-- adjusted with +/- in the UI rather than re-entered each time.
create table if not exists offspring_records (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  chicken_id uuid not null references chickens(id) on delete cascade,
  year int not null,
  male_count int not null default 0,
  female_count int not null default 0,
  created_at timestamptz not null default now(),
  unique (chicken_id, year)
);

-- ---------- Head counts ----------
-- One row per counting session for a coop/flock. coop_id null means the
-- "Unassigned" bucket for that category, matching chickens.coop_id.
-- animal_ids is a snapshot of who was in the coop when the count was
-- taken (so history stays accurate even if animals are later moved or
-- deleted); counted_ids is the subset that were actually ticked.
create table if not exists head_counts (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  coop_id uuid references coops(id) on delete set null,
  category text not null default 'poultry' check (category in ('poultry','livestock')),
  date date not null,
  animal_ids jsonb not null default '[]',
  counted_ids jsonb not null default '[]',
  total int not null default 0,
  created_at timestamptz not null default now()
);

-- ---------- Purchases ----------
-- One row per shopping trip / receipt. total is the ground truth for what
-- was spent; purchase_items optionally break it down by coop/flock, and
-- the app computes an "Other" remainder on the fly (total minus the sum
-- of items) rather than storing it, so it can't drift out of sync.
create table if not exists purchases (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  date date not null,
  vendor text,
  total numeric not null default 0,
  notes text,
  created_at timestamptz not null default now()
);

create table if not exists purchase_items (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users(id) on delete cascade,
  purchase_id uuid not null references purchases(id) on delete cascade,
  coop_id uuid references coops(id) on delete set null,
  description text,
  amount numeric not null default 0,
  created_at timestamptz not null default now()
);

-- Optional classification of a whole purchase (used as the default for its
-- "Other" remainder, and for purchases with no items at all e.g. imports)
-- as a fixed cost (doesn't vary with flock size, e.g. rent, insurance) or a
-- running cost (scales with what you keep, e.g. feed, bedding, vet bills).
-- Only shown in the UI when purchases_settings.track_cost_type is on.
alter table purchases add column if not exists cost_type text check (cost_type in ('fixed','running'));

-- Same classification, but per item, so a single purchase can mix fixed and
-- running items. Falls back to the parent purchase's cost_type when unset.
alter table purchase_items add column if not exists cost_type text check (cost_type in ('fixed','running'));

-- One row per flock owner, toggled from the Account tab.
create table if not exists purchases_settings (
  owner_id uuid primary key references auth.users(id) on delete cascade,
  enabled boolean not null default true,
  track_cost_type boolean not null default false,
  updated_at timestamptz not null default now()
);
alter table purchases_settings add column if not exists enabled boolean not null default true;

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
alter table customer_credits enable row level security;
alter table sales_settings enable row level security;
alter table livestock_sales_settings enable row level security;
alter table livestock_sales enable row level security;
alter table offspring_records enable row level security;
alter table head_counts enable row level security;
alter table purchases enable row level security;
alter table purchase_items enable row level security;
alter table purchases_settings enable row level security;

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

drop policy if exists "customer_credits read" on customer_credits;
create policy "customer_credits read" on customer_credits for select using (has_flock_access(owner_id));
drop policy if exists "customer_credits write" on customer_credits;
create policy "customer_credits write" on customer_credits for insert with check (has_flock_access(owner_id, 'editor'));
drop policy if exists "customer_credits update" on customer_credits;
create policy "customer_credits update" on customer_credits for update using (has_flock_access(owner_id, 'editor'));
drop policy if exists "customer_credits delete" on customer_credits;
create policy "customer_credits delete" on customer_credits for delete using (has_flock_access(owner_id, 'editor'));

drop policy if exists "sales_settings read" on sales_settings;
create policy "sales_settings read" on sales_settings for select using (has_flock_access(owner_id));
drop policy if exists "sales_settings write" on sales_settings;
create policy "sales_settings write" on sales_settings for insert with check (has_flock_access(owner_id, 'editor'));
drop policy if exists "sales_settings update" on sales_settings;
create policy "sales_settings update" on sales_settings for update using (has_flock_access(owner_id, 'editor'));

drop policy if exists "livestock_sales read" on livestock_sales;
create policy "livestock_sales read" on livestock_sales for select using (has_flock_access(owner_id));
drop policy if exists "livestock_sales write" on livestock_sales;
create policy "livestock_sales write" on livestock_sales for insert with check (has_flock_access(owner_id, 'editor'));
drop policy if exists "livestock_sales update" on livestock_sales;
create policy "livestock_sales update" on livestock_sales for update using (has_flock_access(owner_id, 'editor'));
drop policy if exists "livestock_sales delete" on livestock_sales;
create policy "livestock_sales delete" on livestock_sales for delete using (has_flock_access(owner_id, 'editor'));

drop policy if exists "livestock_sales_settings read" on livestock_sales_settings;
create policy "livestock_sales_settings read" on livestock_sales_settings for select using (has_flock_access(owner_id));
drop policy if exists "livestock_sales_settings write" on livestock_sales_settings;
create policy "livestock_sales_settings write" on livestock_sales_settings for insert with check (has_flock_access(owner_id, 'editor'));
drop policy if exists "livestock_sales_settings update" on livestock_sales_settings;
create policy "livestock_sales_settings update" on livestock_sales_settings for update using (has_flock_access(owner_id, 'editor'));

drop policy if exists "offspring_records read" on offspring_records;
create policy "offspring_records read" on offspring_records for select using (has_flock_access(owner_id));
drop policy if exists "offspring_records write" on offspring_records;
create policy "offspring_records write" on offspring_records for insert with check (has_flock_access(owner_id, 'editor'));
drop policy if exists "offspring_records update" on offspring_records;
create policy "offspring_records update" on offspring_records for update using (has_flock_access(owner_id, 'editor'));
drop policy if exists "offspring_records delete" on offspring_records;
create policy "offspring_records delete" on offspring_records for delete using (has_flock_access(owner_id, 'editor'));

drop policy if exists "head_counts read" on head_counts;
create policy "head_counts read" on head_counts for select using (has_flock_access(owner_id));
drop policy if exists "head_counts write" on head_counts;
create policy "head_counts write" on head_counts for insert with check (has_flock_access(owner_id, 'editor'));
drop policy if exists "head_counts delete" on head_counts;
create policy "head_counts delete" on head_counts for delete using (has_flock_access(owner_id, 'editor'));

drop policy if exists "purchases read" on purchases;
create policy "purchases read" on purchases for select using (has_flock_access(owner_id));
drop policy if exists "purchases write" on purchases;
create policy "purchases write" on purchases for insert with check (has_flock_access(owner_id, 'editor'));
drop policy if exists "purchases delete" on purchases;
create policy "purchases delete" on purchases for delete using (has_flock_access(owner_id, 'editor'));

drop policy if exists "purchase_items read" on purchase_items;
create policy "purchase_items read" on purchase_items for select using (has_flock_access(owner_id));
drop policy if exists "purchase_items write" on purchase_items;
create policy "purchase_items write" on purchase_items for insert with check (has_flock_access(owner_id, 'editor'));
drop policy if exists "purchase_items delete" on purchase_items;
create policy "purchase_items delete" on purchase_items for delete using (has_flock_access(owner_id, 'editor'));

drop policy if exists "purchases_settings read" on purchases_settings;
create policy "purchases_settings read" on purchases_settings for select using (has_flock_access(owner_id));
drop policy if exists "purchases_settings write" on purchases_settings;
create policy "purchases_settings write" on purchases_settings for insert with check (has_flock_access(owner_id, 'editor'));
drop policy if exists "purchases_settings update" on purchases_settings;
create policy "purchases_settings update" on purchases_settings for update using (has_flock_access(owner_id, 'editor'));
