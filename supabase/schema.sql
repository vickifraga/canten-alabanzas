-- Canten Alabanzas — base de datos (Supabase / Postgres)
-- Pega TODO este archivo en Supabase → SQL Editor → Run. Se puede correr más de una vez.

-- ============ INVITACIONES (ya no se usan para entrar; solo marcan quién es administrador) ============
create table if not exists public.invites (
  email text primary key,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.invites enable row level security;

create or replace function public.lower_email() returns trigger language plpgsql as $$
begin new.email := lower(trim(new.email)); return new; end $$;
drop trigger if exists invites_lower on public.invites;
create trigger invites_lower before insert or update on public.invites
  for each row execute function public.lower_email();

-- ============ PERFILES ============
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  name text,
  is_admin boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.profiles enable row level security;

-- Registro abierto: cualquier persona puede crear cuenta.
-- (Si antes usabas invitaciones, esto quita ese bloqueo.)
drop trigger if exists gate_signup on auth.users;
drop function if exists public.gate_signup();

create or replace function public.make_profile() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, email, name, is_admin)
  values (new.id, lower(new.email),
          nullif(new.raw_user_meta_data->>'name',''),
          coalesce((select is_admin from public.invites where email = lower(new.email)), false))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists make_profile on auth.users;
create trigger make_profile after insert on auth.users
  for each row execute function public.make_profile();

create or replace function public.me_email() returns text
language sql stable as $$ select lower(coalesce(auth.jwt()->>'email','')) $$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from public.profiles where id = auth.uid()), false)
$$;

drop policy if exists invites_admin on public.invites;
create policy invites_admin on public.invites for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists profiles_read on public.profiles;
create policy profiles_read on public.profiles for select to authenticated using (true);
drop policy if exists profiles_upd on public.profiles;
create policy profiles_upd on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid() and is_admin = (select p.is_admin from public.profiles p where p.id = auth.uid()));

-- ============ EQUIPOS ============
create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(trim(name)) > 0),
  join_code text not null unique default upper(substr(replace(gen_random_uuid()::text,'-',''),1,8)),
  owner uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.team_members (
  team_id uuid references public.teams(id) on delete cascade,
  user_id uuid references public.profiles(id) on delete cascade,
  role text not null default 'member',
  joined_at timestamptz not null default now(),
  primary key (team_id, user_id)
);
alter table public.teams enable row level security;
alter table public.team_members enable row level security;

create or replace function public.in_team(t uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.team_members where team_id = t and user_id = auth.uid())
$$;

-- Al crear un equipo, quien lo crea queda como dueño y miembro
create or replace function public.team_owner_member() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.team_members(team_id, user_id, role) values (new.id, new.owner, 'owner')
  on conflict do nothing;
  return new;
end $$;
drop trigger if exists team_owner_member on public.teams;
create trigger team_owner_member after insert on public.teams
  for each row execute function public.team_owner_member();

drop policy if exists teams_sel on public.teams;
create policy teams_sel on public.teams for select to authenticated
  using (owner = auth.uid() or public.in_team(id));
drop policy if exists teams_ins on public.teams;
create policy teams_ins on public.teams for insert to authenticated with check (owner = auth.uid());
drop policy if exists teams_upd on public.teams;
create policy teams_upd on public.teams for update to authenticated
  using (owner = auth.uid()) with check (owner = auth.uid());
drop policy if exists teams_del on public.teams;
create policy teams_del on public.teams for delete to authenticated using (owner = auth.uid());

drop policy if exists tm_sel on public.team_members;
create policy tm_sel on public.team_members for select to authenticated
  using (user_id = auth.uid() or public.in_team(team_id));
drop policy if exists tm_del on public.team_members;
create policy tm_del on public.team_members for delete to authenticated
  using (user_id = auth.uid()
         or exists (select 1 from public.teams t where t.id = team_id and t.owner = auth.uid()));

create or replace function public.join_team(code text) returns uuid
language plpgsql security definer set search_path = public as $$
declare t uuid;
begin
  if auth.uid() is null then raise exception 'NOT_AUTH'; end if;
  select id into t from public.teams where join_code = upper(trim(code));
  if t is null then raise exception 'BAD_CODE'; end if;
  insert into public.team_members(team_id, user_id) values (t, auth.uid()) on conflict do nothing;
  return t;
end $$;

-- ============ CATÁLOGO COMÚN + VERSIONES ============
create table if not exists public.songs (
  id uuid primary key default gen_random_uuid(),
  title text not null check (length(trim(title)) > 0),
  artist text not null default '',
  created_by uuid not null default auth.uid() references public.profiles(id),
  main_version uuid,
  created_at timestamptz not null default now()
);
create table if not exists public.song_versions (
  id uuid primary key default gen_random_uuid(),
  song_id uuid not null references public.songs(id) on delete cascade,
  author uuid not null default auth.uid() references public.profiles(id),
  name text not null default '',
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists song_versions_song on public.song_versions(song_id);
create index if not exists songs_title on public.songs(lower(title));

alter table public.songs drop constraint if exists songs_main_fk;
alter table public.songs add constraint songs_main_fk
  foreign key (main_version) references public.song_versions(id) on delete set null;

alter table public.songs enable row level security;
alter table public.song_versions enable row level security;

-- Solo quien creó el canto puede cambiar cuál es la versión principal
create or replace function public.guard_song() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.created_by is distinct from old.created_by then
    raise exception 'FORBIDDEN';
  end if;
  if new.main_version is distinct from old.main_version then
    if old.created_by is distinct from auth.uid() and not public.is_admin() then
      raise exception 'ONLY_CREATOR_CHANGES_MAIN';
    end if;
    if new.main_version is not null and not exists
       (select 1 from public.song_versions v where v.id = new.main_version and v.song_id = new.id) then
      raise exception 'VERSION_OF_OTHER_SONG';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists guard_song on public.songs;
create trigger guard_song before update on public.songs
  for each row execute function public.guard_song();

create or replace function public.guard_version() returns trigger
language plpgsql as $$
begin
  new.updated_at := now();
  if tg_op = 'UPDATE' and (new.song_id <> old.song_id or new.author <> old.author) then
    raise exception 'FORBIDDEN';
  end if;
  return new;
end $$;
drop trigger if exists guard_version on public.song_versions;
create trigger guard_version before update on public.song_versions
  for each row execute function public.guard_version();

drop policy if exists songs_sel on public.songs;
create policy songs_sel on public.songs for select to authenticated using (true);
drop policy if exists songs_ins on public.songs;
create policy songs_ins on public.songs for insert to authenticated with check (created_by = auth.uid());
drop policy if exists songs_upd on public.songs;
create policy songs_upd on public.songs for update to authenticated
  using (created_by = auth.uid() or public.is_admin());
drop policy if exists songs_del on public.songs;
create policy songs_del on public.songs for delete to authenticated
  using (created_by = auth.uid() or public.is_admin());

drop policy if exists sv_sel on public.song_versions;
create policy sv_sel on public.song_versions for select to authenticated using (true);
drop policy if exists sv_ins on public.song_versions;
create policy sv_ins on public.song_versions for insert to authenticated with check (author = auth.uid());
drop policy if exists sv_upd on public.song_versions;
create policy sv_upd on public.song_versions for update to authenticated
  using (author = auth.uid()) with check (author = auth.uid());
drop policy if exists sv_del on public.song_versions;
create policy sv_del on public.song_versions for delete to authenticated
  using (author = auth.uid() or public.is_admin());

-- Publicar un canto nuevo (canto + primera versión, que queda como principal)
create or replace function public.publish_song(p_title text, p_artist text, p_data jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare s uuid; v uuid;
begin
  if auth.uid() is null then raise exception 'NOT_AUTH'; end if;
  insert into public.songs(title, artist, created_by) values (trim(p_title), coalesce(p_artist,''), auth.uid())
    returning id into s;
  insert into public.song_versions(song_id, author, name, data) values (s, auth.uid(), 'Original', coalesce(p_data,'{}'))
    returning id into v;
  update public.songs set main_version = v where id = s;
  return jsonb_build_object('song', s, 'version', v);
end $$;

-- ============ REPERTORIOS COMPARTIDOS ============
create table if not exists public.shared_sets (
  id uuid primary key default gen_random_uuid(),
  owner uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  team_id uuid references public.teams(id) on delete set null,
  title text not null default '',
  data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists public.set_shares (
  set_id uuid references public.shared_sets(id) on delete cascade,
  email text not null,
  primary key (set_id, email)
);
alter table public.shared_sets enable row level security;
alter table public.set_shares enable row level security;

create or replace function public.touch_set() returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists touch_set on public.shared_sets;
create trigger touch_set before update on public.shared_sets
  for each row execute function public.touch_set();

create or replace function public.set_shared_with_me(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.set_shares where set_id = sid and email = public.me_email())
$$;
create or replace function public.owns_set(sid uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.shared_sets where id = sid and owner = auth.uid())
$$;

drop policy if exists ss_sel on public.shared_sets;
create policy ss_sel on public.shared_sets for select to authenticated
  using (owner = auth.uid()
         or (team_id is not null and public.in_team(team_id))
         or public.set_shared_with_me(id));
drop policy if exists ss_ins on public.shared_sets;
create policy ss_ins on public.shared_sets for insert to authenticated
  with check (owner = auth.uid() and (team_id is null or public.in_team(team_id)));
drop policy if exists ss_upd on public.shared_sets;
create policy ss_upd on public.shared_sets for update to authenticated
  using (owner = auth.uid())
  with check (owner = auth.uid() and (team_id is null or public.in_team(team_id)));
drop policy if exists ss_del on public.shared_sets;
create policy ss_del on public.shared_sets for delete to authenticated using (owner = auth.uid());

drop policy if exists sh_sel on public.set_shares;
create policy sh_sel on public.set_shares for select to authenticated
  using (public.owns_set(set_id) or email = public.me_email());
drop policy if exists sh_ins on public.set_shares;
create policy sh_ins on public.set_shares for insert to authenticated with check (public.owns_set(set_id));
drop policy if exists sh_del on public.set_shares;
create policy sh_del on public.set_shares for delete to authenticated using (public.owns_set(set_id));

create or replace function public.shares_lower() returns trigger language plpgsql as $$
begin new.email := lower(trim(new.email)); return new; end $$;
drop trigger if exists shares_lower on public.set_shares;
create trigger shares_lower before insert or update on public.set_shares
  for each row execute function public.shares_lower();

-- ============ REPORTES (quitar un canto si su autor lo pide) ============
create table if not exists public.song_reports (
  id uuid primary key default gen_random_uuid(),
  song_id uuid references public.songs(id) on delete cascade,
  reporter uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  reason text not null default '',
  created_at timestamptz not null default now()
);
alter table public.song_reports enable row level security;
drop policy if exists rep_ins on public.song_reports;
create policy rep_ins on public.song_reports for insert to authenticated with check (reporter = auth.uid());
drop policy if exists rep_sel on public.song_reports;
create policy rep_sel on public.song_reports for select to authenticated
  using (reporter = auth.uid() or public.is_admin());
drop policy if exists rep_del on public.song_reports;
create policy rep_del on public.song_reports for delete to authenticated using (public.is_admin());

-- ============ PERMISOS ============
grant usage on schema public to authenticated;
grant select, insert, update, delete on all tables in schema public to authenticated;
grant execute on function public.join_team(text), public.publish_song(text,text,jsonb) to authenticated;
revoke all on all tables in schema public from anon;

-- ============ TU CORREO COMO ADMINISTRADORA ============
-- Cambia el correo por el tuyo y corre SOLO esta línea (una vez):
-- insert into public.invites(email, is_admin) values ('tucorreo@gmail.com', true) on conflict (email) do update set is_admin = true;

-- ============ SINCRONIZACIÓN ENTRE DISPOSITIVOS (repertorios e historial) ============
create table if not exists public.user_sync (
  user_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  kind text not null,
  item_id text not null,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (user_id, kind, item_id)
);
alter table public.user_sync enable row level security;
drop policy if exists us_all on public.user_sync;
create policy us_all on public.user_sync for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
grant select, insert, update, delete on public.user_sync to authenticated;
revoke all on public.user_sync from anon;
