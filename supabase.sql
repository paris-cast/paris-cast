-- =====================================================================
-- Paris Cast - banco de dados (Supabase)
-- Cole TUDO isto em: Supabase > SQL Editor > New query > Run.
-- Pode rodar de novo sem problema (ele se ajusta).
-- =====================================================================

-- 1) Tabela unica de documentos (cadastros, musicas, grade, pedidos...)
create table if not exists public.docs (
  path text primary key,
  col text not null default '',
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create index if not exists docs_col_idx on public.docs (col);
alter table public.docs enable row level security;
alter table public.docs replica identity full;

create or replace function public.docs_before() returns trigger
language plpgsql as $$
begin
  new.col := regexp_replace(new.path, '/[^/]+$', '');
  new.updated_at := now();
  return new;
end $$;
drop trigger if exists docs_before_trg on public.docs;
create trigger docs_before_trg before insert or update on public.docs
  for each row execute function public.docs_before();

-- 2) Donos (administradores). Ninguem le/escreve direto: so pelas funcoes abaixo.
create table if not exists public.admins (
  uid uuid primary key,
  is_owner boolean not null default false
);
alter table public.admins enable row level security;

-- 3) Quem e quem
create or replace function public.app_is_anon() returns boolean
language sql stable as $$
  select coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false)
$$;

create or replace function public.app_level() returns int
language sql stable security definer set search_path = public as $$
  select case
    when auth.uid() is null then 0
    when public.app_is_anon() then 2
    when exists (select 1 from public.admins a where a.uid = auth.uid() and a.is_owner) then 4
    when exists (select 1 from public.admins a where a.uid = auth.uid()) then 3
    else 2 end
$$;

create or replace function public.app_role() returns text
language sql stable security definer set search_path = public as $$
  select case when public.app_is_anon() then 'ouvinte'
    else coalesce((select d.data->>'role' from public.docs d where d.path = 'roles/' || auth.uid()::text), 'ouvinte') end
$$;

-- 4) Regras de leitura
create or replace function public.app_can_read(p text) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare seg text[] := string_to_array(p, '/'); me text := auth.uid()::text; lvl int := public.app_level(); n int := array_length(string_to_array(p, '/'), 1);
begin
  if lvl = 0 then return false; end if;
  case seg[1]
    when 'data' then return seg[2] = 'users' and seg[3] = me;
    when 'people' then return lvl >= 3 or (n = 2 and seg[2] = me);
    when 'keys' then return lvl >= 3 or (n = 2 and seg[2] = me);
    when 'listeners' then return lvl >= 3 or (n = 2 and seg[2] = me) or public.app_role() in ('produtor', 'programador', 'dono');
    when 'history' then return lvl >= 3 or public.app_role() in ('produtor', 'programador', 'dono');
    when 'notes' then return lvl >= 3 or public.app_role() in ('produtor', 'programador', 'dono');
    when 'stafflog' then return lvl >= 3 or public.app_role() = 'dono';
    when 'blocked' then return lvl >= 3 or (n = 2 and seg[2] = me);
    else return true;
  end case;
end $$;

-- 5) Regras de escrita (old = linha atual, new = linha nova; nulo quando nao existe)
create or replace function public.app_can_write(p text, old jsonb, new jsonb) returns boolean
language plpgsql stable security definer set search_path = public as $$
declare seg text[] := string_to_array(p, '/'); me text := auth.uid()::text; lvl int := public.app_level(); n int := array_length(string_to_array(p, '/'), 1); r text;
begin
  if lvl = 0 then return false; end if;
  if seg[1] = 'data' then return seg[2] = 'users' and seg[3] = me and n >= 4; end if;
  if lvl >= 3 then return true; end if;
  r := public.app_role();
  case seg[1]
    when 'people' then return n = 2 and seg[2] = me;
    when 'keys' then return n = 2 and seg[2] = me;
    when 'names' then return n = 2 and seg[2] = me;
    when 'listeners' then return n = 2 and seg[2] = me;
    when 'claims' then
      return (new is null and old->>'uid' = me) or (new->>'uid' = me and (old is null or old->>'uid' = me));
    when 'songs' then return r in ('produtor', 'dono');
    when 'folders' then return r in ('produtor', 'dono');
    when 'plan' then return r in ('programador', 'dono');
    when 'requests' then return (old is null and new is not null) or r in ('produtor', 'programador', 'dono');
    when 'suggestions' then return (old is null and new is not null) or r in ('produtor', 'programador', 'dono');
    when 'polls' then return r in ('programador', 'dono');
    when 'templates' then return r in ('programador', 'dono');
    when 'weekly' then return r in ('programador', 'dono');
    when 'shifts' then return r in ('programador', 'dono');
    when 'drafts' then return r in ('programador', 'dono');
    when 'notes' then return r in ('produtor', 'programador', 'dono');
    when 'stafflog' then return old is null and new is not null and r in ('produtor', 'programador', 'dono');
    when 'history' then return r in ('programador', 'dono');
    else return false;
  end case;
end $$;

drop policy if exists docs_select on public.docs;
drop policy if exists docs_insert on public.docs;
drop policy if exists docs_update on public.docs;
drop policy if exists docs_delete on public.docs;
create policy docs_select on public.docs for select to authenticated using (public.app_can_read(path));
create policy docs_insert on public.docs for insert to authenticated with check (public.app_can_write(path, null, data));
create policy docs_update on public.docs for update to authenticated using (public.app_can_write(path, data, data)) with check (public.app_can_write(path, null, data));
create policy docs_delete on public.docs for delete to authenticated using (public.app_can_write(path, data, null));

grant select, insert, update, delete on public.docs to authenticated;
revoke all on public.docs from anon;
revoke all on public.admins from anon, authenticated;

-- 6) Funcoes chamadas pelo site
create or replace function public.whoami() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('level', public.app_level(), 'owner', public.app_level() >= 4, 'admin', public.app_level() >= 3)
$$;

-- So a conta Radialistas do telefone do dono consegue virar dono (e so uma vez).
create or replace function public.claim_owner() returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return false; end if;
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then return false; end if;
  if coalesce(auth.jwt() ->> 'email', '') <> '38999232546@radialistas.pariscast.app' then return false; end if;
  if exists (select 1 from public.admins where is_owner) then return false; end if;
  insert into public.admins (uid, is_owner) values (auth.uid(), true) on conflict (uid) do update set is_owner = true;
  return true;
end $$;

-- So o dono torna alguem "dono tambem" (editor) ou tira.
create or replace function public.set_admin(target uuid, on_ boolean) returns void
language plpgsql security definer set search_path = public as $$
begin
  if public.app_level() < 4 then raise exception 'so o dono pode isto'; end if;
  if target = auth.uid() then return; end if;
  if on_ then
    insert into public.admins (uid, is_owner) values (target, false) on conflict (uid) do nothing;
  else
    delete from public.admins where uid = target and not is_owner;
  end if;
end $$;

-- Atualiza so alguns campos de um documento (e falha se nao existir ou nao puder).
create or replace function public.doc_merge(p text, d jsonb) returns boolean
language plpgsql security invoker set search_path = public as $$
begin
  update public.docs set data = data || d where path = p;
  if not found then raise exception 'not_found'; end if;
  return true;
end $$;

revoke all on function public.whoami(), public.claim_owner(), public.set_admin(uuid, boolean), public.doc_merge(text, jsonb) from public, anon;
grant execute on function public.whoami(), public.claim_owner(), public.set_admin(uuid, boolean), public.doc_merge(text, jsonb) to authenticated;
revoke all on function public.app_level(), public.app_role(), public.app_can_read(text), public.app_can_write(text, jsonb, jsonb) from public, anon;
grant execute on function public.app_level(), public.app_role(), public.app_can_read(text), public.app_can_write(text, jsonb, jsonb) to authenticated;

-- 7) Tempo real
do $$ begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'docs') then
    alter publication supabase_realtime add table public.docs;
  end if;
end $$;

-- 8) Armazenamento dos audios (pasta "audio", leitura publica, envio so da equipe)
create or replace function public.app_is_producer() returns boolean
language sql stable security definer set search_path = public as $$
  select public.app_level() >= 3 or public.app_role() in ('produtor', 'dono')
$$;
revoke all on function public.app_is_producer() from public, anon;
grant execute on function public.app_is_producer() to authenticated;

do $$ begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('audio', 'audio', true, 20971520, array['video/mp4','video/webm','audio/mp4','audio/webm','audio/x-m4a'])
    on conflict (id) do update set public = true, file_size_limit = 20971520, allowed_mime_types = excluded.allowed_mime_types;
    execute 'drop policy if exists audio_insert on storage.objects';
    execute 'drop policy if exists audio_delete on storage.objects';
    execute 'create policy audio_insert on storage.objects for insert to authenticated with check (bucket_id = ''audio'' and public.app_is_producer())';
    execute 'create policy audio_delete on storage.objects for delete to authenticated using (bucket_id = ''audio'' and public.app_is_producer())';
  end if;
end $$;


-- =====================================================================
-- 9) NOVIDADES: limite diario, ouvindo agora, curtidas, enquete
-- =====================================================================
create table if not exists public.quota (
  uid uuid not null, day date not null, kind text not null, n int not null default 0,
  primary key (uid, day, kind)
);
alter table public.quota enable row level security;
revoke all on public.quota from anon, authenticated;

create table if not exists public.presence (
  uid uuid primary key, ls timestamptz not null default now(), listening boolean not null default false
);
alter table public.presence enable row level security;
revoke all on public.presence from anon, authenticated;

create table if not exists public.presence_log (
  day date not null, hour int not null, online int not null default 0, listening int not null default 0,
  primary key (day, hour)
);
alter table public.presence_log enable row level security;
revoke all on public.presence_log from anon, authenticated;

create table if not exists public.likes (
  song text not null, uid uuid not null, at timestamptz not null default now(),
  primary key (song, uid)
);
create index if not exists likes_song_idx on public.likes (song);
alter table public.likes enable row level security;
revoke all on public.likes from anon, authenticated;

create table if not exists public.votes (
  poll text not null, uid uuid not null, opt text not null, at timestamptz not null default now(),
  primary key (poll, uid)
);
alter table public.votes enable row level security;
revoke all on public.votes from anon, authenticated;

-- Limite de pedidos e sugestoes por pessoa por dia (a equipe nao tem limite).
-- O dono muda os numeros no site; sem nada configurado: 3 pedidos e 2 sugestoes.
create or replace function public.docs_quota() returns trigger
language plpgsql security definer set search_path = public as $$
declare k text := split_part(new.path, '/', 1); lim int; cnt int; r text;
begin
  if k not in ('requests', 'suggestions') or split_part(new.path, '/', 3) <> '' then return new; end if;
  if auth.uid() is null then return new; end if;
  if exists (select 1 from public.docs b where b.path = 'blocked/' || auth.uid()::text) then raise exception 'bloqueado'; end if;
  r := public.app_role();
  if public.app_level() >= 3 or r in ('produtor', 'programador', 'dono') then return new; end if;
  select coalesce((select (d.data ->> k)::int from public.docs d where d.path = 'config/limits'), case k when 'requests' then 3 else 2 end) into lim;
  lim := greatest(1, least(coalesce(lim, 3), 50));
  insert into public.quota as q (uid, day, kind, n)
    values (auth.uid(), (now() at time zone 'America/Sao_Paulo')::date, k, 1)
    on conflict (uid, day, kind) do update set n = q.n + 1 where q.n < lim
    returning q.n into cnt;
  if cnt is null then raise exception 'limite_diario'; end if;
  return new;
end $$;
drop trigger if exists docs_quota_trg on public.docs;
create trigger docs_quota_trg before insert on public.docs
  for each row execute function public.docs_quota();

create or replace function public.quota_left(p_kind text) returns int
language plpgsql stable security definer set search_path = public as $$
declare lim int; used int;
begin
  if p_kind not in ('requests', 'suggestions') then return 0; end if;
  if public.app_level() >= 3 or public.app_role() in ('produtor', 'programador', 'dono') then return 999; end if;
  select coalesce((select (d.data ->> p_kind)::int from public.docs d where d.path = 'config/limits'), case p_kind when 'requests' then 3 else 2 end) into lim;
  lim := greatest(1, least(coalesce(lim, 3), 50));
  select coalesce((select n from public.quota where uid = auth.uid() and kind = p_kind and day = (now() at time zone 'America/Sao_Paulo')::date), 0) into used;
  return greatest(0, lim - used);
end $$;

-- Quantas pessoas estao na radio agora (cada aparelho avisa a cada ~30 s).
create or replace function public.presence_ping(p_listening boolean) returns json
language plpgsql security definer set search_path = public as $$
declare a int; b int;
begin
  if auth.uid() is null then return json_build_object('listening', 0, 'online', 0); end if;
  insert into public.presence (uid, ls, listening) values (auth.uid(), now(), coalesce(p_listening, false))
    on conflict (uid) do update set ls = now(), listening = coalesce(p_listening, false);
  if random() < 0.03 then delete from public.presence where ls < now() - interval '1 day'; end if;
  select count(*) filter (where listening), count(*) into a, b from public.presence where ls > now() - interval '100 seconds';
  insert into public.presence_log as pl (day, hour, online, listening)
    values ((now() at time zone 'America/Sao_Paulo')::date, extract(hour from (now() at time zone 'America/Sao_Paulo'))::int, b, a)
    on conflict (day, hour) do update set online = greatest(pl.online, excluded.online), listening = greatest(pl.listening, excluded.listening);
  return json_build_object('listening', a, 'online', b);
end $$;

-- Curtidas
create or replace function public.like_toggle(p_song text) returns json
language plpgsql security definer set search_path = public as $$
declare mine boolean; c int;
begin
  if auth.uid() is null or coalesce(p_song, '') = '' or length(p_song) > 80 then return json_build_object('count', 0, 'mine', false); end if;
  if exists (select 1 from public.docs b where b.path = 'blocked/' || auth.uid()::text) then raise exception 'bloqueado'; end if;
  if exists (select 1 from public.likes where song = p_song and uid = auth.uid()) then
    delete from public.likes where song = p_song and uid = auth.uid(); mine := false;
  else
    insert into public.likes (song, uid) values (p_song, auth.uid()) on conflict do nothing; mine := true;
  end if;
  select count(*) into c from public.likes where song = p_song;
  return json_build_object('count', c, 'mine', mine);
end $$;

create or replace function public.like_info(p_song text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object('count', (select count(*) from public.likes where song = p_song),
                           'mine', exists (select 1 from public.likes where song = p_song and uid = auth.uid()))
$$;

create or replace function public.likes_top(p_n int) returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('song', t.song, 'count', t.c)), '[]'::json)
  from (select song, count(*) c from public.likes group by song order by count(*) desc, max(at) desc limit greatest(1, least(coalesce(p_n, 5), 20))) t
$$;

-- Minhas curtidas (cada pessoa ve as suas)
create or replace function public.my_likes() returns json
language sql stable security definer set search_path = public as $$
  select coalesce(json_agg(json_build_object('song', l.song, 'at', l.at) order by l.at desc), '[]'::json)
  from public.likes l where l.uid = auth.uid()
$$;

-- Estatisticas por hora (pico de gente): so equipe de gestao
create or replace function public.stats_hours(p_days int) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not (public.app_level() >= 3 or public.app_role() in ('programador', 'dono')) then raise exception 'sem permissao'; end if;
  return (select coalesce(json_agg(json_build_object('day', day, 'hour', hour, 'online', online, 'listening', listening) order by day, hour), '[]'::json)
          from public.presence_log where day >= (now() at time zone 'America/Sao_Paulo')::date - greatest(1, least(coalesce(p_days, 30), 120)));
end $$;

-- Enquete (a pergunta fica em polls/atual; os votos ficam aqui, secretos)
create or replace function public.poll_vote(p_poll text, p_opt text) returns json
language plpgsql security definer set search_path = public as $$
declare d jsonb;
begin
  if auth.uid() is null then raise exception 'sem login'; end if;
  if exists (select 1 from public.docs b where b.path = 'blocked/' || auth.uid()::text) then raise exception 'bloqueado'; end if;
  select data into d from public.docs where path in ('polls/atual', 'polls/semana') and data ->> 'id' = p_poll limit 1;
  if d is null or d ->> 'status' <> 'open' then raise exception 'enquete_encerrada'; end if;
  if not (d -> 'opts') @> to_jsonb(p_opt) then raise exception 'opcao_invalida'; end if;
  insert into public.votes (poll, uid, opt) values (p_poll, auth.uid(), p_opt)
    on conflict (poll, uid) do update set opt = excluded.opt, at = now();
  return public.poll_results(p_poll);
end $$;

create or replace function public.poll_results(p_poll text) returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'counts', coalesce((select json_object_agg(opt, c) from (select opt, count(*) c from public.votes where poll = p_poll group by opt) x), '{}'::json),
    'total', (select count(*) from public.votes where poll = p_poll),
    'mine', (select opt from public.votes where poll = p_poll and uid = auth.uid()))
$$;

-- Quem curtiu uma musica: so o dono enxerga.
create or replace function public.likes_who(p_song text) returns json
language plpgsql stable security definer set search_path = public as $$
begin
  if auth.uid() is null or not (public.app_level() >= 4 or public.app_role() = 'dono') then raise exception 'so o dono'; end if;
  return (select coalesce(json_agg(json_build_object('uid', l.uid, 'at', l.at) order by l.at desc), '[]'::json) from public.likes l where l.song = p_song);
end $$;

revoke all on function public.quota_left(text), public.presence_ping(boolean), public.like_toggle(text), public.like_info(text), public.likes_top(int), public.poll_vote(text, text), public.poll_results(text), public.likes_who(text), public.my_likes(), public.stats_hours(int), public.app_is_anon() from public, anon;
grant execute on function public.quota_left(text), public.presence_ping(boolean), public.like_toggle(text), public.like_info(text), public.likes_top(int), public.poll_vote(text, text), public.poll_results(text), public.likes_who(text), public.my_likes(), public.stats_hours(int), public.app_is_anon() to authenticated;
revoke all on function public.docs_quota() from public, anon, authenticated;
