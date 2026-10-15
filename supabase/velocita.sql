-- Applicata il 15/10/2026. Salvataggio "leggero": il server aggiunge un record in coda al cassetto,
-- il programma invia solo il record nuovo (prima riscriveva tutto il cassetto, fino a ~1 MB per salvataggio).
-- SECURITY INVOKER: valgono le stesse regole RLS dei corsisti (scrivono solo corso_* tranne impostazioni).
create or replace function public.aggiungi_record(p_chiave text, p_record jsonb)
returns jsonb
language plpgsql security invoker set search_path = public as $$
declare v_agg timestamptz; v_n int;
begin
  insert into storage (key, value, updated_at) values (p_chiave, jsonb_build_array(p_record)::text, now())
  on conflict (key) do update
    set value = (case when jsonb_typeof(storage.value::jsonb) = 'array' then storage.value::jsonb else '[]'::jsonb end || jsonb_build_array(p_record))::text,
        updated_at = now()
  returning updated_at, jsonb_array_length(value::jsonb) into v_agg, v_n;
  return jsonb_build_object('agg', v_agg, 'n', v_n);
end $$;
revoke execute on function public.aggiungi_record(text, jsonb) from public, authenticated;
grant execute on function public.aggiungi_record(text, jsonb) to anon;
-- Nota: esiste anche public.aggiungi_a_cassetto (prima versione, non usata dal programma): si può eliminare.
