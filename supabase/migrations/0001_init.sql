-- Anon Rooms – schema inițială (Supabase / Postgres)
-- Rulează tot fișierul o singură dată în Supabase → SQL Editor.
-- Înainte: Authentication → Sign In / Providers → activează „Allow anonymous sign-ins”.

create extension if not exists pg_cron with schema pg_catalog;

-- ───────────────────────── Tabele ─────────────────────────

create table public.profiles (
  id         uuid primary key references auth.users(id) on delete cascade,
  nickname   text not null check (char_length(nickname) between 3 and 24),
  created_at timestamptz not null default now()
);

create table public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create table public.rooms (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 2 and 40),
  lang        text check (lang is null or lang ~ '^[a-z]{2}$'),  -- limba camerei publice; null = vizibilă în toate limbile
  emoji       text not null default '💬',
  color_a     text not null default '#5B6CFF' check (color_a ~ '^#[0-9A-Fa-f]{6}$'),  -- culorile temei camerei
  color_b     text not null default '#8E54E9' check (color_b ~ '^#[0-9A-Fa-f]{6}$'),
  description text,
  is_private  boolean not null default false,
  invite_code text unique,
  created_by  uuid references auth.users(id) on delete set null,
  sort        int not null default 100,
  created_at  timestamptz not null default now()
);

create table public.room_members (
  room_id   uuid not null references public.rooms(id) on delete cascade,
  user_id   uuid not null references auth.users(id) on delete cascade,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);

create table public.messages (
  id         bigint generated always as identity primary key,
  room_id    uuid not null references public.rooms(id) on delete cascade,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  nickname   text not null,
  body       text not null check (char_length(body) between 1 and 500),
  hidden     boolean not null default false,
  created_at timestamptz not null default now()
);
create index messages_room_time_idx on public.messages (room_id, created_at desc);
create index messages_user_time_idx on public.messages (user_id, created_at desc);

create table public.blocks (
  blocker_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  blocked_id       uuid not null references auth.users(id) on delete cascade,
  blocked_nickname text not null default '',
  created_at       timestamptz not null default now(),
  primary key (blocker_id, blocked_id)
);

-- Fără chei străine: raportul rămâne ca dovadă și după ce mesajul e șters.
create table public.reports (
  id                bigint generated always as identity primary key,
  message_id        bigint not null,
  room_id           uuid,
  reporter_id       uuid not null,
  reported_user_id  uuid not null,
  reported_nickname text,
  message_body      text,
  reason            text,
  resolved          boolean not null default false,
  created_at        timestamptz not null default now(),
  unique (message_id, reporter_id)
);

create table public.bans (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  reason     text,
  until      timestamptz,            -- null = permanent
  created_at timestamptz not null default now()
);

create table public.banned_words (
  word text primary key
);

-- ───────────────────── Funcții ajutătoare ─────────────────────

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from public.admins where user_id = auth.uid());
$fn$;

create or replace function public.is_member(p_room uuid) returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from public.room_members
                 where room_id = p_room and user_id = auth.uid());
$fn$;

create or replace function public.can_access_room(p_room uuid) returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (
    select 1 from public.rooms r
    where r.id = p_room
      and (not r.is_private
           or exists (select 1 from public.room_members m
                      where m.room_id = r.id and m.user_id = auth.uid()))
  );
$fn$;

create or replace function public.is_banned(p_user uuid) returns boolean
language sql stable security definer set search_path = public as $fn$
  select exists (select 1 from public.bans
                 where user_id = p_user and (until is null or until > now()));
$fn$;

create or replace function public.mask_banned_words(p_text text) returns text
language plpgsql stable security definer set search_path = public as $fn$
declare
  w text;
  result text := p_text;
begin
  for w in select word from public.banned_words loop
    result := regexp_replace(
      result,
      regexp_replace(w, '([.*+?^${}()|\[\]\\])', '\\\1', 'g'),
      '***', 'gi');
  end loop;
  return result;
end
$fn$;

-- ───────────────────────── Triggere ─────────────────────────

-- Mesaje: verifică ban, limită de viteză, pune porecla și maschează cuvintele interzise.
create or replace function public.messages_before_insert() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare
  v_nick   text;
  v_recent int;
begin
  if auth.uid() is not null then
    new.user_id := auth.uid();
  end if;

  if public.is_banned(new.user_id) then
    raise exception 'BANNED';
  end if;

  select count(*) into v_recent from public.messages
  where user_id = new.user_id and created_at > now() - interval '10 seconds';
  if v_recent >= 5 then
    raise exception 'RATE_LIMIT';
  end if;

  select nickname into v_nick from public.profiles where id = new.user_id;
  if v_nick is null then
    raise exception 'NO_PROFILE';
  end if;

  new.nickname   := v_nick;
  new.body       := public.mask_banned_words(btrim(new.body));
  new.hidden     := false;
  new.created_at := now();
  return new;
end
$fn$;

create trigger messages_before_insert
before insert on public.messages
for each row execute function public.messages_before_insert();

-- Porecle: fără cuvinte interzise.
create or replace function public.profiles_check_nickname() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  new.nickname := btrim(new.nickname);
  if public.mask_banned_words(new.nickname) <> new.nickname then
    raise exception 'BAD_NICKNAME';
  end if;
  return new;
end
$fn$;

create trigger profiles_check_nickname
before insert or update on public.profiles
for each row execute function public.profiles_check_nickname();

-- ───────────────────── Funcții apelate din aplicație ─────────────────────

create or replace function public.create_private_room(p_name text) returns public.rooms
language plpgsql security definer set search_path = public as $fn$
declare
  v_room  public.rooms;
  v_code  text;
  v_count int;
  v_palettes text[] := array[
    '#FF6B6B,#FFA94D', '#845EF7,#5C7CFA', '#20C997,#0CA678', '#F06595,#CC5DE8',
    '#339AF0,#22B8CF', '#FF922B,#F03E3E', '#51CF66,#94D82D', '#7950F2,#E64980'];
  v_pick text;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if public.is_banned(auth.uid()) then raise exception 'BANNED'; end if;

  v_pick := v_palettes[1 + floor(random() * array_length(v_palettes, 1))::int];

  select count(*) into v_count from public.rooms
  where created_by = auth.uid() and is_private;
  if v_count >= 5 then raise exception 'ROOM_LIMIT'; end if;

  loop
    v_code := upper(substr(md5(gen_random_uuid()::text), 1, 6));
    exit when not exists (select 1 from public.rooms where invite_code = v_code);
  end loop;

  insert into public.rooms (name, emoji, color_a, color_b, is_private, invite_code, created_by)
  values (public.mask_banned_words(btrim(p_name)), '🔒',
          split_part(v_pick, ',', 1), split_part(v_pick, ',', 2), true, v_code, auth.uid())
  returning * into v_room;

  insert into public.room_members (room_id, user_id) values (v_room.id, auth.uid());
  return v_room;
end
$fn$;

create or replace function public.join_private_room(p_code text) returns public.rooms
language plpgsql security definer set search_path = public as $fn$
declare
  v_room public.rooms;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHENTICATED'; end if;
  if public.is_banned(auth.uid()) then raise exception 'BANNED'; end if;

  select * into v_room from public.rooms
  where is_private and invite_code = upper(btrim(p_code));
  if not found then raise exception 'ROOM_NOT_FOUND'; end if;

  insert into public.room_members (room_id, user_id)
  values (v_room.id, auth.uid())
  on conflict do nothing;
  return v_room;
end
$fn$;

-- Raportare: la 3 rapoarte de la utilizatori diferiți mesajul se ascunde singur.
create or replace function public.report_message(p_message_id bigint, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $fn$
declare
  m public.messages;
  n int;
begin
  if auth.uid() is null then raise exception 'NOT_AUTHENTICATED'; end if;

  select * into m from public.messages where id = p_message_id;
  if not found or not public.can_access_room(m.room_id) then return; end if;

  insert into public.reports
    (message_id, room_id, reporter_id, reported_user_id, reported_nickname, message_body, reason)
  values
    (m.id, m.room_id, auth.uid(), m.user_id, m.nickname, m.body, left(p_reason, 200))
  on conflict (message_id, reporter_id) do nothing;

  select count(*) into n from public.reports where message_id = p_message_id;
  if n >= 3 then
    update public.messages set hidden = true where id = p_message_id;
  end if;
end
$fn$;

create or replace function public.admin_ban(p_user_id uuid, p_hours int default null, p_reason text default null)
returns void
language plpgsql security definer set search_path = public as $fn$
begin
  if not public.is_admin() then raise exception 'NOT_ADMIN'; end if;

  insert into public.bans (user_id, reason, until)
  values (p_user_id, p_reason,
          case when p_hours is null then null else now() + make_interval(hours => p_hours) end)
  on conflict (user_id) do update
    set reason = excluded.reason, until = excluded.until, created_at = now();

  update public.messages set hidden = true where user_id = p_user_id;
  update public.reports  set resolved = true where reported_user_id = p_user_id;
end
$fn$;

-- „Șterge datele mele”: șterge contul anonim și, în cascadă, profilul, mesajele și blocările.
create or replace function public.delete_my_data() returns void
language plpgsql security definer set search_path = public as $fn$
begin
  if auth.uid() is null then raise exception 'NOT_AUTHENTICATED'; end if;
  delete from auth.users where id = auth.uid();
end
$fn$;

-- ───────────────────── Row Level Security ─────────────────────

alter table public.profiles     enable row level security;
alter table public.admins       enable row level security;
alter table public.rooms        enable row level security;
alter table public.room_members enable row level security;
alter table public.messages     enable row level security;
alter table public.blocks       enable row level security;
alter table public.reports      enable row level security;
alter table public.bans         enable row level security;
alter table public.banned_words enable row level security;

create policy profiles_select_own on public.profiles for select to authenticated
  using (id = auth.uid());
create policy profiles_insert_own on public.profiles for insert to authenticated
  with check (id = auth.uid());
create policy profiles_update_own on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

create policy rooms_select on public.rooms for select to authenticated
  using (not is_private or public.is_member(id));

create policy members_select_own on public.room_members for select to authenticated
  using (user_id = auth.uid());
create policy members_leave on public.room_members for delete to authenticated
  using (user_id = auth.uid());

create policy messages_select on public.messages for select to authenticated
  using (
    public.is_admin()
    or (
      not hidden
      and public.can_access_room(room_id)
      and not exists (select 1 from public.blocks b
                      where b.blocker_id = auth.uid() and b.blocked_id = messages.user_id)
    )
  );
create policy messages_insert on public.messages for insert to authenticated
  with check (user_id = auth.uid() and public.can_access_room(room_id));
create policy messages_delete on public.messages for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());

create policy blocks_all_own on public.blocks for all to authenticated
  using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());

create policy reports_admin_select on public.reports for select to authenticated
  using (public.is_admin());
create policy reports_admin_update on public.reports for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

create policy bans_select on public.bans for select to authenticated
  using (user_id = auth.uid() or public.is_admin());
create policy bans_admin_delete on public.bans for delete to authenticated
  using (public.is_admin());

-- admins și banned_words: fără politici = inaccesibile din aplicație.

-- ───────────────────────── Drepturi ─────────────────────────

revoke all on all tables in schema public from anon;
grant select, insert, update on public.profiles     to authenticated;
grant select                 on public.rooms        to authenticated;
grant select, delete         on public.room_members to authenticated;
grant select, insert, delete on public.messages     to authenticated;
grant select, insert, update, delete on public.blocks to authenticated;
grant select, update         on public.reports      to authenticated;
grant select, delete         on public.bans         to authenticated;

revoke execute on all functions in schema public from public, anon;
grant execute on function
  public.is_admin(), public.is_member(uuid), public.can_access_room(uuid),
  public.create_private_room(text), public.join_private_room(text),
  public.report_message(bigint, text), public.admin_ban(uuid, int, text),
  public.delete_my_data()
to authenticated;

-- ───────────────────────── Realtime ─────────────────────────

alter publication supabase_realtime add table public.messages;

-- ───────────────────── Curățare automată ─────────────────────

select cron.schedule('rooms-sterge-mesaje-vechi', '*/15 * * * *',
  $$delete from public.messages where created_at < now() - interval '24 hours'$$);
select cron.schedule('rooms-sterge-rapoarte-vechi', '17 3 * * *',
  $$delete from public.reports where resolved and created_at < now() - interval '30 days'$$);
select cron.schedule('rooms-sterge-banuri-expirate', '23 3 * * *',
  $$delete from public.bans where until is not null and until < now()$$);

-- ───────────────────────── Date inițiale ─────────────────────────

-- Camere publice: aceleași 8 teme în fiecare dintre cele 8 limbi. Utilizatorul vede camerele din limba telefonului.
insert into public.rooms (lang, name, emoji, description, color_a, color_b, sort) values
  ('en', 'Lounge', '💬', 'Anything goes, be kind', '#5B6CFF', '#8E54E9', 10),
  ('en', 'Football', '⚽', 'Matches, transfers, teams', '#11998E', '#38C172', 20),
  ('en', 'Movies & Series', '🎬', 'What''s worth watching', '#C31432', '#7B1FA2', 30),
  ('en', 'Music', '🎵', 'What you''re listening to', '#F953C6', '#B91D73', 40),
  ('en', 'Gaming', '🎮', 'PC, console, mobile', '#7F00FF', '#00A8E8', 50),
  ('en', 'Tech', '💻', 'Phones, apps, gadgets', '#1E3C72', '#2A9DF4', 60),
  ('en', 'Travel', '✈️', 'Places, tips, stories', '#F37335', '#F2A900', 70),
  ('en', 'Night Owls', '🌙', 'For those who can''t sleep', '#141E30', '#4B4E9E', 80),
  ('ro', 'La o vorbă', '💬', 'Despre orice, cu bun-simț', '#5B6CFF', '#8E54E9', 10),
  ('ro', 'Fotbal', '⚽', 'Meciuri, transferuri, echipe', '#11998E', '#38C172', 20),
  ('ro', 'Filme și seriale', '🎬', 'Ce merită văzut', '#C31432', '#7B1FA2', 30),
  ('ro', 'Muzică', '🎵', 'Ce asculți acum', '#F953C6', '#B91D73', 40),
  ('ro', 'Jocuri', '🎮', 'PC, consolă, mobil', '#7F00FF', '#00A8E8', 50),
  ('ro', 'Tehnologie', '💻', 'Telefoane, aplicații, gadgeturi', '#1E3C72', '#2A9DF4', 60),
  ('ro', 'Călătorii', '✈️', 'Locuri, sfaturi, povești', '#F37335', '#F2A900', 70),
  ('ro', 'Noapte bună', '🌙', 'Pentru cei care nu dorm', '#141E30', '#4B4E9E', 80),
  ('es', 'Charla libre', '💬', 'De todo un poco, con respeto', '#5B6CFF', '#8E54E9', 10),
  ('es', 'Fútbol', '⚽', 'Partidos, fichajes, equipos', '#11998E', '#38C172', 20),
  ('es', 'Cine y series', '🎬', 'Qué vale la pena ver', '#C31432', '#7B1FA2', 30),
  ('es', 'Música', '🎵', 'Qué estás escuchando', '#F953C6', '#B91D73', 40),
  ('es', 'Videojuegos', '🎮', 'PC, consola, móvil', '#7F00FF', '#00A8E8', 50),
  ('es', 'Tecnología', '💻', 'Móviles, apps, gadgets', '#1E3C72', '#2A9DF4', 60),
  ('es', 'Viajes', '✈️', 'Lugares, consejos, historias', '#F37335', '#F2A900', 70),
  ('es', 'Noctámbulos', '🌙', 'Para los que no duermen', '#141E30', '#4B4E9E', 80),
  ('fr', 'Papotage', '💬', 'De tout et de rien, avec respect', '#5B6CFF', '#8E54E9', 10),
  ('fr', 'Football', '⚽', 'Matchs, transferts, équipes', '#11998E', '#38C172', 20),
  ('fr', 'Films et séries', '🎬', 'Ce qui vaut le détour', '#C31432', '#7B1FA2', 30),
  ('fr', 'Musique', '🎵', 'Ce que tu écoutes', '#F953C6', '#B91D73', 40),
  ('fr', 'Jeux vidéo', '🎮', 'PC, console, mobile', '#7F00FF', '#00A8E8', 50),
  ('fr', 'Tech', '💻', 'Téléphones, applis, gadgets', '#1E3C72', '#2A9DF4', 60),
  ('fr', 'Voyages', '✈️', 'Lieux, conseils, récits', '#F37335', '#F2A900', 70),
  ('fr', 'Oiseaux de nuit', '🌙', 'Pour ceux qui ne dorment pas', '#141E30', '#4B4E9E', 80),
  ('de', 'Plauderecke', '💬', 'Über alles, mit Respekt', '#5B6CFF', '#8E54E9', 10),
  ('de', 'Fußball', '⚽', 'Spiele, Transfers, Teams', '#11998E', '#38C172', 20),
  ('de', 'Filme & Serien', '🎬', 'Was sich lohnt', '#C31432', '#7B1FA2', 30),
  ('de', 'Musik', '🎵', 'Was du gerade hörst', '#F953C6', '#B91D73', 40),
  ('de', 'Gaming', '🎮', 'PC, Konsole, Handy', '#7F00FF', '#00A8E8', 50),
  ('de', 'Technik', '💻', 'Handys, Apps, Gadgets', '#1E3C72', '#2A9DF4', 60),
  ('de', 'Reisen', '✈️', 'Orte, Tipps, Geschichten', '#F37335', '#F2A900', 70),
  ('de', 'Nachteulen', '🌙', 'Für alle, die nicht schlafen', '#141E30', '#4B4E9E', 80),
  ('it', 'Due chiacchiere', '💬', 'Di tutto un po'', con rispetto', '#5B6CFF', '#8E54E9', 10),
  ('it', 'Calcio', '⚽', 'Partite, mercato, squadre', '#11998E', '#38C172', 20),
  ('it', 'Film e serie', '🎬', 'Cosa vale la pena vedere', '#C31432', '#7B1FA2', 30),
  ('it', 'Musica', '🎵', 'Cosa stai ascoltando', '#F953C6', '#B91D73', 40),
  ('it', 'Videogiochi', '🎮', 'PC, console, mobile', '#7F00FF', '#00A8E8', 50),
  ('it', 'Tecnologia', '💻', 'Telefoni, app, gadget', '#1E3C72', '#2A9DF4', 60),
  ('it', 'Viaggi', '✈️', 'Luoghi, consigli, storie', '#F37335', '#F2A900', 70),
  ('it', 'Nottambuli', '🌙', 'Per chi non dorme', '#141E30', '#4B4E9E', 80),
  ('pt', 'Bate-papo', '💬', 'De tudo um pouco, com respeito', '#5B6CFF', '#8E54E9', 10),
  ('pt', 'Futebol', '⚽', 'Jogos, transferências, equipas', '#11998E', '#38C172', 20),
  ('pt', 'Filmes e séries', '🎬', 'O que vale a pena ver', '#C31432', '#7B1FA2', 30),
  ('pt', 'Música', '🎵', 'O que estás a ouvir', '#F953C6', '#B91D73', 40),
  ('pt', 'Jogos', '🎮', 'PC, consola, telemóvel', '#7F00FF', '#00A8E8', 50),
  ('pt', 'Tecnologia', '💻', 'Telemóveis, apps, gadgets', '#1E3C72', '#2A9DF4', 60),
  ('pt', 'Viagens', '✈️', 'Lugares, dicas, histórias', '#F37335', '#F2A900', 70),
  ('pt', 'Notívagos', '🌙', 'Para quem não dorme', '#141E30', '#4B4E9E', 80),
  ('ar', 'دردشة عامة', '💬', 'عن كل شيء، باحترام', '#5B6CFF', '#8E54E9', 10),
  ('ar', 'كرة القدم', '⚽', 'مباريات، انتقالات، فرق', '#11998E', '#38C172', 20),
  ('ar', 'أفلام ومسلسلات', '🎬', 'ما يستحق المشاهدة', '#C31432', '#7B1FA2', 30),
  ('ar', 'موسيقى', '🎵', 'ماذا تسمع الآن', '#F953C6', '#B91D73', 40),
  ('ar', 'ألعاب', '🎮', 'كمبيوتر، كونسول، جوال', '#7F00FF', '#00A8E8', 50),
  ('ar', 'تقنية', '💻', 'هواتف، تطبيقات، أجهزة', '#1E3C72', '#2A9DF4', 60),
  ('ar', 'سفر', '✈️', 'أماكن، نصائح، حكايات', '#F37335', '#F2A900', 70),
  ('ar', 'سهارى', '🌙', 'لمن لا ينام', '#141E30', '#4B4E9E', 80);

-- Listă de pornire pentru filtru; adaugi oricând rânduri în tabelul banned_words.
insert into public.banned_words (word) values
  ('fuck'), ('shit'), ('bitch'), ('pula'), ('pizda'), ('muie'), ('futu');

-- După prima deschidere a aplicației pe telefonul tău, fă-te admin:
--   insert into public.admins (user_id)
--   select id from public.profiles where nickname = 'PORECLA_TA';

-- Coada de moderare (rulezi în SQL Editor):
--   select * from public.reports where not resolved order by created_at desc;
