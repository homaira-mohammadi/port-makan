-- Port Makan: MVP schema
-- Tables: profiles, spots, spot_photos, reviews
-- Covers FR-01..03, FR-07..23, FR-26..29, FR-32..37, FR-42 and NFR-09..11.

-- ---------------------------------------------------------------------------
-- Extensions
-- ---------------------------------------------------------------------------
create extension if not exists postgis with schema extensions;   -- distances, map bounds
create extension if not exists pg_trgm with schema extensions;   -- fuzzy name search

-- Private schema for helper functions. It is NOT exposed through the Data API,
-- so nothing in here can be called from the browser directly.
create schema if not exists private;
grant usage on schema private to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------
create type public.spot_category as enum (
  'warung', 'mamak', 'kopitiam', 'hawker_stall', 'night_market', 'cafe', 'other'
);                                                                    -- FR-15
create type public.user_role as enum ('member', 'admin');
create type public.halal_status as enum ('halal', 'non_halal');       -- FR-17

-- ---------------------------------------------------------------------------
-- profiles: one row per signed-in user (FR-03)
-- ---------------------------------------------------------------------------
create table public.profiles (
  id                  uuid primary key references auth.users (id) on delete cascade,
  display_name        text not null
                      check (char_length(display_name) between 1 and 50 and display_name !~ '[<>]'),
  photo_url           text check (photo_url is null or photo_url ~ '^https://'),
  role                public.user_role not null default 'member',
  is_banned           boolean not null default false,               -- FR-44
  privacy_accepted_at timestamptz,                                  -- NFR-14 (PDPA notice)
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- spots: a food place on the map
-- The frontend sends lat/lng; `location` is computed for distance queries.
-- ---------------------------------------------------------------------------
create table public.spots (
  id                     uuid primary key default gen_random_uuid(),
  name                   text not null
                         check (char_length(btrim(name)) between 2 and 80 and name !~ '[<>]'),
  category               public.spot_category not null,
  lat                    double precision not null,
  lng                    double precision not null,
  location               extensions.geography(Point, 4326)
                         generated always as (
                           extensions.st_setsrid(extensions.st_makepoint(lng, lat), 4326)::extensions.geography
                         ) stored,
  address                text check (char_length(address) <= 200 and address !~ '[<>]'),
  -- {"mon": [["07:00","14:00"]], "tue": [], ...}; empty list = closed that day
  opening_hours          jsonb check (opening_hours is null or jsonb_typeof(opening_hours) = 'object'),
  price_range            smallint check (price_range between 1 and 3),   -- 1 = RM, 3 = RM RM RM
  halal_status           public.halal_status,                             -- null = unknown
  is_vegetarian_friendly boolean not null default false,
  rating_avg             numeric(2, 1),                                   -- kept up to date by trigger
  review_count           integer not null default 0,
  created_by             uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now(),
  -- Launch area: Alor Setar (Kota Setar district). Widen this when Port Makan
  -- expands to the rest of Kedah.
  constraint spots_in_launch_area check (lat between 5.90 and 6.35 and lng between 100.20 and 100.55)
);

create index spots_location_idx   on public.spots using gist (location);
create index spots_category_idx   on public.spots (category);
create index spots_name_trgm_idx  on public.spots using gin (name extensions.gin_trgm_ops);
create index spots_created_by_idx on public.spots (created_by);

-- ---------------------------------------------------------------------------
-- spot_photos: files live in Storage bucket "spot-photos"; this table points to them
-- ---------------------------------------------------------------------------
create table public.spot_photos (
  id           uuid primary key default gen_random_uuid(),
  spot_id      uuid not null references public.spots (id) on delete cascade,
  storage_path text not null unique check (char_length(storage_path) <= 200),
  alt_text     text check (char_length(alt_text) <= 200 and alt_text !~ '[<>]'),  -- NFR-07
  uploaded_by  uuid default auth.uid() references public.profiles (id) on delete set null,
  created_at   timestamptz not null default now()
);

create index spot_photos_spot_idx        on public.spot_photos (spot_id, created_at);
create index spot_photos_uploaded_by_idx on public.spot_photos (uploaded_by);

-- ---------------------------------------------------------------------------
-- reviews: one per member per spot (FR-26, FR-27, FR-29)
-- ---------------------------------------------------------------------------
create table public.reviews (
  id            uuid primary key default gen_random_uuid(),
  spot_id       uuid not null references public.spots (id) on delete cascade,
  user_id       uuid not null default auth.uid() references public.profiles (id) on delete cascade,
  rating        smallint not null check (rating between 1 and 5),
  body          text check (char_length(body) <= 2000),
  must_try_dish text check (char_length(must_try_dish) <= 80 and must_try_dish !~ '[<>]'),
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint reviews_one_per_user_per_spot unique (spot_id, user_id)
);

create index reviews_spot_newest_idx on public.reviews (spot_id, created_at desc);  -- FR-23
create index reviews_user_idx        on public.reviews (user_id);

-- ---------------------------------------------------------------------------
-- Helper functions used by security rules
-- SECURITY DEFINER so they can read profiles without recursing into RLS.
-- They live in the private schema, so the browser cannot call them directly.
-- ---------------------------------------------------------------------------
create function private.is_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'admin' and not is_banned
  );
$$;

create function private.can_write()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and not is_banned
  );
$$;

revoke execute on function private.is_admin(), private.can_write() from public;
grant execute on function private.is_admin(), private.can_write() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Triggers
-- ---------------------------------------------------------------------------

-- Create a profile when someone signs in with Google for the first time (FR-01, FR-03)
create function private.handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_name  text;
  v_photo text;
begin
  v_name := coalesce(
    new.raw_user_meta_data ->> 'full_name',
    new.raw_user_meta_data ->> 'name',
    split_part(new.email, '@', 1)
  );
  v_name := left(btrim(regexp_replace(coalesce(v_name, ''), '[<>]', '', 'g')), 50);
  if v_name = '' then
    v_name := 'Makan friend';
  end if;

  v_photo := coalesce(new.raw_user_meta_data ->> 'avatar_url', new.raw_user_meta_data ->> 'picture');
  if v_photo !~ '^https://' then
    v_photo := null;
  end if;

  insert into public.profiles (id, display_name, photo_url)
  values (new.id, v_name, v_photo)
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- Keep updated_at current
create function private.touch_updated_at()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger profiles_touch before update on public.profiles
  for each row execute function private.touch_updated_at();
create trigger spots_touch before update on public.spots
  for each row execute function private.touch_updated_at();
create trigger reviews_touch before update on public.reviews
  for each row execute function private.touch_updated_at();

-- Keep spots.rating_avg and spots.review_count in step with reviews (FR-22)
create function private.refresh_spot_rating()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_spot uuid;
begin
  for v_spot in
    select distinct s from unnest(array[
      case when tg_op <> 'INSERT' then old.spot_id end,
      case when tg_op <> 'DELETE' then new.spot_id end
    ]) as s where s is not null
  loop
    update public.spots sp
    set rating_avg   = agg.avg_rating,
        review_count = agg.n
    from (
      select round(avg(rating)::numeric, 1) as avg_rating, count(*)::int as n
      from public.reviews where spot_id = v_spot
    ) agg
    where sp.id = v_spot;
  end loop;
  return null;
end;
$$;

create trigger reviews_refresh_rating
  after insert or update of rating, spot_id or delete on public.reviews
  for each row execute function private.refresh_spot_rating();

-- Spam limits: 20 new spots and 50 reviews per member per day (NFR-11)
create function private.enforce_daily_limit()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_count int;
  v_user  uuid := (select auth.uid());
begin
  if v_user is null then
    return new;  -- server-side jobs (SQL editor, seed data) are not limited
  end if;

  if tg_table_name = 'spots' then
    select count(*) into v_count from public.spots
    where created_by = v_user and created_at > now() - interval '24 hours';
    if v_count >= 20 then
      raise exception 'You can add up to 20 spots a day. Try again tomorrow.'
        using errcode = 'P0001', hint = 'daily_spot_limit';
    end if;
  elsif tg_table_name = 'reviews' then
    select count(*) into v_count from public.reviews
    where user_id = v_user and created_at > now() - interval '24 hours';
    if v_count >= 50 then
      raise exception 'You can write up to 50 reviews a day. Try again tomorrow.'
        using errcode = 'P0001', hint = 'daily_review_limit';
    end if;
  end if;
  return new;
end;
$$;

create trigger spots_daily_limit before insert on public.spots
  for each row execute function private.enforce_daily_limit();
create trigger reviews_daily_limit before insert on public.reviews
  for each row execute function private.enforce_daily_limit();

revoke execute on all functions in schema private from public;
grant execute on function private.is_admin(), private.can_write() to anon, authenticated;

-- ---------------------------------------------------------------------------
-- Table access (who can reach which columns through the Data API)
-- Column-level grants stop members from setting role, is_banned, rating_avg,
-- review_count, created_by or user_id themselves.
-- ---------------------------------------------------------------------------
revoke all on public.profiles, public.spots, public.spot_photos, public.reviews from anon, authenticated;

grant select on public.profiles, public.spots, public.spot_photos, public.reviews to anon, authenticated;

grant update (display_name, photo_url, privacy_accepted_at) on public.profiles to authenticated;

grant insert (name, category, lat, lng, address, opening_hours, price_range, halal_status, is_vegetarian_friendly)
  on public.spots to authenticated;
grant update (name, category, lat, lng, address, opening_hours, price_range, halal_status, is_vegetarian_friendly)
  on public.spots to authenticated;
grant delete on public.spots to authenticated;

grant insert (spot_id, storage_path, alt_text) on public.spot_photos to authenticated;
grant update (alt_text) on public.spot_photos to authenticated;
grant delete on public.spot_photos to authenticated;

grant insert (spot_id, rating, body, must_try_dish) on public.reviews to authenticated;
grant update (rating, body, must_try_dish) on public.reviews to authenticated;
grant delete on public.reviews to authenticated;

-- ---------------------------------------------------------------------------
-- Row Level Security (NFR-09): which rows each person can touch
-- Guests read everything; members write their own; admins can fix anything (FR-42).
-- ---------------------------------------------------------------------------
alter table public.profiles    enable row level security;
alter table public.spots       enable row level security;
alter table public.spot_photos enable row level security;
alter table public.reviews     enable row level security;

-- profiles
create policy "Profiles are public"
  on public.profiles for select to anon, authenticated
  using (true);

create policy "Members edit their own profile"
  on public.profiles for update to authenticated
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

-- spots
create policy "Spots are public"
  on public.spots for select to anon, authenticated
  using (true);

create policy "Members add spots"
  on public.spots for insert to authenticated
  with check ((select auth.uid()) = created_by and (select private.can_write()));

create policy "Owner or admin edits a spot"
  on public.spots for update to authenticated
  using (((select auth.uid()) = created_by and (select private.can_write())) or (select private.is_admin()))
  with check (((select auth.uid()) = created_by and (select private.can_write())) or (select private.is_admin()));

create policy "Owner or admin deletes a spot"
  on public.spots for delete to authenticated
  using (((select auth.uid()) = created_by and (select private.can_write())) or (select private.is_admin()));

-- spot_photos (only the spot's owner or an admin adds photos for now)
create policy "Spot photos are public"
  on public.spot_photos for select to anon, authenticated
  using (true);

create policy "Spot owner adds photos"
  on public.spot_photos for insert to authenticated
  with check (
    (select auth.uid()) = uploaded_by
    and (select private.can_write())
    and (
      exists (select 1 from public.spots s where s.id = spot_id and s.created_by = (select auth.uid()))
      or (select private.is_admin())
    )
  );

create policy "Uploader or admin edits photo text"
  on public.spot_photos for update to authenticated
  using ((select auth.uid()) = uploaded_by or (select private.is_admin()))
  with check ((select auth.uid()) = uploaded_by or (select private.is_admin()));

create policy "Uploader or admin deletes a photo"
  on public.spot_photos for delete to authenticated
  using ((select auth.uid()) = uploaded_by or (select private.is_admin()));

-- reviews
create policy "Reviews are public"
  on public.reviews for select to anon, authenticated
  using (true);

create policy "Members write reviews"
  on public.reviews for insert to authenticated
  with check ((select auth.uid()) = user_id and (select private.can_write()));

create policy "Author or admin edits a review"
  on public.reviews for update to authenticated
  using (((select auth.uid()) = user_id and (select private.can_write())) or (select private.is_admin()))
  with check (((select auth.uid()) = user_id and (select private.can_write())) or (select private.is_admin()));

create policy "Author or admin deletes a review"
  on public.reviews for delete to authenticated
  using ((select auth.uid()) = user_id or (select private.is_admin()));

-- ---------------------------------------------------------------------------
-- API functions (called from the frontend with supabase.rpc)
-- SECURITY INVOKER: they run as the caller, so RLS still applies.
-- ---------------------------------------------------------------------------

-- Map pins and list view for the visible map area, with filters (FR-07, FR-32..35, FR-37)
create function public.spots_in_view(
  min_lng      double precision,
  min_lat      double precision,
  max_lng      double precision,
  max_lat      double precision,
  p_category   public.spot_category default null,
  p_search     text default null,
  p_min_rating numeric default null,
  p_price      smallint default null,
  p_halal      boolean default null,
  p_vegetarian boolean default null,
  p_near_lat   double precision default null,
  p_near_lng   double precision default null,
  p_limit      integer default 300
)
returns table (
  id                     uuid,
  name                   text,
  category               public.spot_category,
  lat                    double precision,
  lng                    double precision,
  rating_avg             numeric,
  review_count           integer,
  price_range            smallint,
  halal_status           public.halal_status,
  is_vegetarian_friendly boolean,
  cover_photo_path       text,
  distance_m             double precision
)
language sql stable security invoker set search_path = ''
as $$
  select
    s.id, s.name, s.category, s.lat, s.lng, s.rating_avg, s.review_count,
    s.price_range, s.halal_status, s.is_vegetarian_friendly,
    (select p.storage_path from public.spot_photos p
      where p.spot_id = s.id order by p.created_at limit 1) as cover_photo_path,
    case when p_near_lat is not null and p_near_lng is not null then
      extensions.st_distance(
        s.location,
        extensions.st_setsrid(extensions.st_makepoint(p_near_lng, p_near_lat), 4326)::extensions.geography
      )
    end as distance_m
  from public.spots s
  where s.location operator(extensions.&&)
        extensions.st_makeenvelope(min_lng, min_lat, max_lng, max_lat, 4326)::extensions.geography
    and (p_category   is null or s.category = p_category)
    and (p_search     is null or btrim(p_search) = ''
         or s.name ilike '%' || btrim(p_search) || '%'
         or extensions.similarity(s.name, btrim(p_search)) > 0.3)
    and (p_min_rating is null or s.rating_avg >= p_min_rating)
    and (p_price      is null or s.price_range <= p_price)
    and (p_halal      is null or not p_halal or s.halal_status = 'halal')
    and (p_vegetarian is null or not p_vegetarian or s.is_vegetarian_friendly)
  order by
    case when p_near_lat is not null and p_near_lng is not null then
      extensions.st_distance(
        s.location,
        extensions.st_setsrid(extensions.st_makepoint(p_near_lng, p_near_lat), 4326)::extensions.geography
      )
    end asc nulls last,
    s.rating_avg desc nulls last,
    s.name
  limit least(greatest(coalesce(p_limit, 300), 1), 1000);
$$;

-- Warn about a likely duplicate before adding a spot (FR-18)
create function public.nearby_duplicates(p_name text, p_lat double precision, p_lng double precision)
returns table (id uuid, name text, category public.spot_category, distance_m double precision)
language sql stable security invoker set search_path = ''
as $$
  select s.id, s.name, s.category,
         extensions.st_distance(s.location, pt.g) as distance_m
  from public.spots s,
       (select extensions.st_setsrid(extensions.st_makepoint(p_lng, p_lat), 4326)::extensions.geography as g) pt
  where extensions.st_dwithin(s.location, pt.g, 100)
    and extensions.similarity(lower(s.name), lower(btrim(p_name))) > 0.4
  order by distance_m
  limit 5;
$$;

revoke execute on function public.spots_in_view, public.nearby_duplicates from public;
grant execute on function public.spots_in_view, public.nearby_duplicates to anon, authenticated;

-- Server-side code (Edge Functions, admin scripts) uses the service role.
grant all on public.profiles, public.spots, public.spot_photos, public.reviews to service_role;
grant execute on function public.spots_in_view, public.nearby_duplicates to service_role;
