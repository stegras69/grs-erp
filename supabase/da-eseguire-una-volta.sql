-- Ultimo passo della protezione lato server (il resto è già applicato).
-- Supabase → SQL Editor → incolla tutto → Run. Si può rieseguire senza danni.

-- 1) Cancellazione riservata al docente (con token di sessione)
create or replace function public.docente_elimina(p_token text, p_chiavi text[]) returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  perform _docente_verifica(p_token);
  delete from storage where key = any (p_chiavi);
  get diagnostics n = row_count;
  return n;
end $$;

-- 2) Cambio PIN dal Pannello docente
create or replace function public.docente_cambia_pin(p_token text, p_pin1 text, p_pin2 text) returns void
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform _docente_verifica(p_token);
  if length(coalesce(p_pin1, '')) < 4 or length(coalesce(p_pin2, '')) < 4 then
    raise exception 'Ogni PIN deve avere almeno 4 caratteri';
  end if;
  insert into docente_config (id, pin_hash, aggiornato) values (1, crypt(p_pin1 || ':' || p_pin2, gen_salt('bf')), now())
    on conflict (id) do update set pin_hash = excluded.pin_hash, aggiornato = now();
  delete from docente_sessioni where token is distinct from p_token;
end $$;

revoke execute on function public.docente_elimina(text, text[]), public.docente_cambia_pin(text, text, text) from public, authenticated;
grant execute on function public.docente_elimina(text, text[]), public.docente_cambia_pin(text, text, text) to anon;

-- 3) Regole: i corsisti scrivono solo i dati dei corsi e la propria presenza, e non cancellano
drop policy if exists storage_scrittura on public.storage;
drop policy if exists storage_modifica on public.storage;
drop policy if exists storage_cancella on public.storage;
drop policy if exists storage_scrittura_corsisti on public.storage;
drop policy if exists storage_modifica_corsisti on public.storage;
create policy storage_scrittura_corsisti on public.storage for insert to anon
  with check (public._chiave_corsista(key));
create policy storage_modifica_corsisti on public.storage for update to anon
  using (public._chiave_corsista(key)) with check (public._chiave_corsista(key));
