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
create or replace function public.app_level() returns int
language sql stable security definer set search_path = public as $$
  select case
    when auth.uid() is null then 0
    when exists (select 1 from public.admins a where a.uid = auth.uid() and a.is_owner) then 4
    when exists (select 1 from public.admins a where a.uid = auth.uid()) then 3
    else 2 end
$$;

create or replace function public.app_role() returns text
language sql stable security definer set search_path = public as $$
  select coalesce((select d.data->>'role' from public.docs d where d.path = 'roles/' || auth.uid()::text), 'ouvinte')
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

-- O primeiro usuario COM E-MAIL que chamar isto vira o dono. Depois disso ninguem mais consegue.
create or replace function public.claim_owner() returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return false; end if;
  if coalesce((auth.jwt() ->> 'is_anonymous')::boolean, false) then return false; end if;
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
