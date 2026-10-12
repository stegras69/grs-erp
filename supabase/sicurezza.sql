-- =====================================================================================
-- GRS ERP — Protezione lato server (Supabase)
-- -------------------------------------------------------------------------------------
-- 1. I corsisti (chiave pubblica "anon") possono:
--      - leggere tutto;
--      - scrivere SOLO i dati dei corsi (corso_X::...) tranne le impostazioni del corso,
--        e la propria presenza (dispositiviAttivi::...);
--      - NON possono cancellare nulla, né creare/modificare corsi, impostazioni,
--        dispositivi bloccati o fidati.
-- 2. Il formatore entra con i due PIN, verificati SUL SERVER (i PIN non sono più nel
--    codice della pagina): riceve un token di sessione valido 12 ore, che autorizza le
--    funzioni docente_* (scrittura, cancellazione, storico, cambio PIN).
-- 3. Rete di sicurezza: ogni cancellazione e ogni riscrittura che RIDUCE un valore
--    (es. un cassetto svuotato) salva la versione precedente in storage_storico per 30 giorni,
--    ripristinabile dal Pannello docente.
--
-- I PIN si impostano/cambiano dal Pannello docente (scheda Sicurezza) oppure, la prima volta:
--   insert into public.docente_config(id, pin_hash)
--   values (1, extensions.crypt('PIN1:PIN2', extensions.gen_salt('bf')))
--   on conflict (id) do update set pin_hash = excluded.pin_hash;
-- =====================================================================================

-- ---------- Tabelle private (RLS attivo e nessuna policy: invisibili alla chiave pubblica) ----------
create table if not exists public.docente_config (
  id int primary key default 1 check (id = 1),
  pin_hash text not null,
  aggiornato timestamptz not null default now()
);
create table if not exists public.docente_sessioni (
  token text primary key,
  creata timestamptz not null default now(),
  scade timestamptz not null,
  dispositivo text
);
create table if not exists public.docente_tentativi (
  id bigserial primary key,
  ts timestamptz not null default now(),
  dispositivo text,
  ok boolean not null
);
create index if not exists docente_tentativi_ts on public.docente_tentativi (ts);
create table if not exists public.storage_storico (
  id bigserial primary key,
  key text not null,
  value text,
  operazione text not null,
  ts timestamptz not null default now()
);
create index if not exists storage_storico_ts on public.storage_storico (ts);
create index if not exists storage_storico_key on public.storage_storico (key);

alter table public.docente_config enable row level security;
alter table public.docente_sessioni enable row level security;
alter table public.docente_tentativi enable row level security;
alter table public.storage_storico enable row level security;
revoke all on public.docente_config, public.docente_sessioni, public.docente_tentativi, public.storage_storico from anon, authenticated;

-- ---------- Storico: versione precedente salvata su cancellazione o riduzione ----------
create or replace function public._storage_storico_trg() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'DELETE' then
    if old.key not like 'dispositiviAttivi::%' then
      insert into storage_storico (key, value, operazione) values (old.key, old.value, 'eliminata');
    end if;
    return old;
  end if;
  if new.key not like 'dispositiviAttivi::%' and length(coalesce(new.value, '')) < length(coalesce(old.value, '')) then
    insert into storage_storico (key, value, operazione) values (old.key, old.value, 'ridotta');
  end if;
  return new;
end $$;
drop trigger if exists storage_storico_trg on public.storage;
create trigger storage_storico_trg after update or delete on public.storage
  for each row execute function public._storage_storico_trg();

-- ---------- Cosa può scrivere un corsista ----------
create or replace function public._chiave_corsista(k text) returns boolean
language sql immutable set search_path = public as $$
  select (k ~ '^corso_[^:]+::' and k !~ '^corso_[^:]+::impostazioni$') or k like 'dispositiviAttivi::%'
$$;

drop policy if exists storage_scrittura on public.storage;
drop policy if exists storage_modifica on public.storage;
drop policy if exists storage_cancella on public.storage;
drop policy if exists storage_scrittura_corsisti on public.storage;
drop policy if exists storage_modifica_corsisti on public.storage;
create policy storage_scrittura_corsisti on public.storage for insert to anon
  with check (public._chiave_corsista(key));
create policy storage_modifica_corsisti on public.storage for update to anon
  using (public._chiave_corsista(key)) with check (public._chiave_corsista(key));
-- Nessuna policy DELETE per anon: le cancellazioni passano solo da docente_elimina.
-- (storage_lettura, SELECT per anon, resta com'era.)

-- ---------- Sessione docente ----------
create or replace function public._docente_verifica(p_token text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if p_token is null or not exists (select 1 from docente_sessioni where token = p_token and scade > now()) then
    raise exception 'Sessione docente non valida o scaduta: rientra nel Pannello docente con i PIN';
  end if;
end $$;

create or replace function public._ora_it() returns text
language sql stable as $$ select to_char(now() at time zone 'Europe/Rome', 'DD/MM/YYYY HH24:MI') $$;

create or replace function public.docente_accesso(p_pin1 text, p_pin2 text, p_dispositivo text) returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  v_hash text; v_tok text; v_fidato boolean;
  v_disp text := nullif(left(coalesce(p_dispositivo, ''), 80), '');
begin
  -- Limite ai tentativi: 5 errori per dispositivo o 30 in totale negli ultimi 15 minuti.
  if (select count(*) from docente_tentativi where not ok and ts > now() - interval '15 minutes'
        and dispositivo is not distinct from v_disp) >= 5
     or (select count(*) from docente_tentativi where not ok and ts > now() - interval '15 minutes') >= 30 then
    return jsonb_build_object('ok', false, 'troppiTentativi', true);
  end if;
  select pin_hash into v_hash from docente_config where id = 1;
  if v_hash is not null and v_hash = crypt(coalesce(p_pin1, '') || ':' || coalesce(p_pin2, ''), v_hash) then
    insert into docente_tentativi (dispositivo, ok) values (v_disp, true);
    v_tok := encode(gen_random_bytes(24), 'hex');
    insert into docente_sessioni (token, scade, dispositivo) values (v_tok, now() + interval '12 hours', v_disp);
    -- manutenzione
    delete from docente_sessioni where scade < now();
    delete from docente_tentativi where ts < now() - interval '30 days';
    delete from storage_storico where ts < now() - interval '30 days';
    if v_disp is not null then
      insert into storage (key, value, updated_at)
        values ('dispositiviFidati::' || v_disp, jsonb_build_object('dal', _ora_it())::text, now())
        on conflict (key) do nothing;
    end if;
    return jsonb_build_object('ok', true, 'token', v_tok);
  end if;
  insert into docente_tentativi (dispositivo, ok) values (v_disp, false);
  v_fidato := v_disp is not null and exists (select 1 from storage where key = 'dispositiviFidati::' || v_disp);
  -- Dispositivo mai autenticato prima: PIN sbagliato = blocco (come prima, ma deciso dal server).
  if v_disp is not null and not v_fidato then
    insert into storage (key, value, updated_at)
      values ('dispositiviBannati::' || v_disp, jsonb_build_object('motivo', 'PIN Pannello docente errato', 'quando', _ora_it())::text, now())
      on conflict (key) do update set value = excluded.value, updated_at = now();
  end if;
  return jsonb_build_object('ok', false, 'bannato', v_disp is not null and not v_fidato);
end $$;

create or replace function public.docente_esci(p_token text) returns void
language sql security definer set search_path = public as $$
  delete from docente_sessioni where token = p_token
$$;

-- p_righe = [{"key": "...", "value": "..."}, ...]
create or replace function public.docente_scrivi(p_token text, p_righe jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform _docente_verifica(p_token);
  insert into storage (key, value, updated_at)
    select r->>'key', r->>'value', now() from jsonb_array_elements(p_righe) r where coalesce(r->>'key', '') <> ''
    on conflict (key) do update set value = excluded.value, updated_at = now();
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.docente_elimina(p_token text, p_chiavi text[]) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform _docente_verifica(p_token);
  delete from storage where key = any (p_chiavi);
  get diagnostics n = row_count;
  return n;
end $$;

create or replace function public.docente_cambia_pin(p_token text, p_pin1 text, p_pin2 text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _docente_verifica(p_token);
  if length(coalesce(p_pin1, '')) < 4 or length(coalesce(p_pin2, '')) < 4 then
    raise exception 'Ogni PIN deve avere almeno 4 caratteri';
  end if;
  insert into docente_config (id, pin_hash, aggiornato) values (1, crypt(p_pin1 || ':' || p_pin2, gen_salt('bf')), now())
    on conflict (id) do update set pin_hash = excluded.pin_hash, aggiornato = now();
  -- chiude tutte le altre sessioni docente aperte
  delete from docente_sessioni where token <> p_token;
end $$;

create or replace function public.docente_storico(p_token text, p_filtro text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _docente_verifica(p_token);
  return coalesce((select jsonb_agg(t order by t.id desc) from (
    select id, key, operazione, ts, length(value) as lunghezza from storage_storico
    where p_filtro is null or p_filtro = '' or key like '%' || p_filtro || '%'
    order by id desc limit 300) t), '[]'::jsonb);
end $$;

create or replace function public.docente_versione(p_token text, p_id bigint) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  perform _docente_verifica(p_token);
  return (select jsonb_build_object('key', key, 'value', value, 'ts', ts, 'operazione', operazione) from storage_storico where id = p_id);
end $$;

create or replace function public.docente_ripristina_versione(p_token text, p_id bigint) returns text
language plpgsql security definer set search_path = public as $$
declare v_key text; v_value text;
begin
  perform _docente_verifica(p_token);
  select key, value into v_key, v_value from storage_storico where id = p_id;
  if v_key is null then raise exception 'Versione non trovata'; end if;
  insert into storage (key, value, updated_at) values (v_key, v_value, now())
    on conflict (key) do update set value = excluded.value, updated_at = now();
  return v_key;
end $$;

-- ---------- Permessi sulle funzioni ----------
revoke execute on function public._storage_storico_trg(), public._docente_verifica(text), public._ora_it() from public, anon, authenticated;
revoke execute on function public.docente_accesso(text, text, text), public.docente_esci(text), public.docente_scrivi(text, jsonb),
  public.docente_elimina(text, text[]), public.docente_cambia_pin(text, text, text), public.docente_storico(text, text),
  public.docente_versione(text, bigint), public.docente_ripristina_versione(text, bigint) from public;
grant execute on function public.docente_accesso(text, text, text), public.docente_esci(text), public.docente_scrivi(text, jsonb),
  public.docente_elimina(text, text[]), public.docente_cambia_pin(text, text, text), public.docente_storico(text, text),
  public.docente_versione(text, bigint), public.docente_ripristina_versione(text, bigint) to anon;
