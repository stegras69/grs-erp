# GRS Solutions ERP Full — istruzioni per Claude

Simulatore ERP in stile SAP usato da Stefano (formatore) nei corsi. Lingua: **italiano**.

## Regole di lavoro (vincolanti)
1. **SAP-like:** ogni nuova funzione o modifica deve seguire SAP. Se la transazione/funzione esiste in SAP si rifà
   come in SAP (codice transazione, nomi dei campi, logica, tipi movimento). Se in SAP non esiste, **prima si discute
   con Stefano** e non si implementa nulla finché non è d'accordo.
2. **Spiegare PRIMA di agire** sulle modifiche di design; per i cambi richiesti esplicitamente si procede.
3. **Scritture sul database** (Supabase) solo con approvazione di Stefano; prima di modifiche ai dati di un corso fare
   una copia (es. chiavi `corso_BACKUP-<CORSO>-<data>::…`) o un backup dal Pannello docente.
4. **Mai** cambiare regole del database, PIN o password senza il suo ok; non scrivere password/PIN in chiaro nel repo.
5. Le modifiche ai dati fatte per conto del formatore si registrano come **SG** (patch/record nei cassetti `::sg`),
   con una spiegazione nel campo `_da` o nel testo del documento, mai riscrivendo i cassetti dei corsisti.
6. Dopo ogni modifica: **test headless** con Playwright (Chromium in `/opt/pw-browsers/chromium`) con Supabase
   simulato (la sandbox non raggiunge Supabase/Firebase); poi commit, push sul branch di lavoro e su `main`.
7. Gli studenti devono **ricaricare la pagina** (Ctrl+F5 / Cmd+Option+R) per prendere una nuova versione.

## Dove sta
- Un solo file: `index.html` → GitHub Pages https://stegras69.github.io/grs-erp/ (branch `main`).
- `index4.html`, `index5.html`: vecchie versioni Firebase, non usate.
- Backend: **Supabase** (progetto "grs erp", ref `zpnwqybvsowzqycesnlc`). Firebase congelato come copia.
- `supabase/sicurezza.sql`: protezione lato server **già applicata** (vedi sotto).
- Non caricare mai versioni locali vecchie (es. `supabase-prova.html`, commit `3dc6734` del branch `sap-like`) al posto
  di `index.html`: cancellerebbero pannello docente, sicurezza e correzioni successive.

## Modello dati
Tabella `public.storage(key text PK, value text, updated_at)`.
- `corso_<CORSO>::<tipo>::u::<shard>`: cassetto del partecipante (array di record, solo in aggiunta).
- `corso_<CORSO>::<tipo>::patch::<shard>`: patch `{_target,_t,_da,campi,_arrayField,_arrayIndex}`; eliminazione = `{_eliminato:true}`.
- `corso_X::partecipanti::<shard>`, `corso_X::contatori::<PREFIX>` (RPC atomica `incrementa_contatore`),
  `corso_X::impostazioni`, `corso_X::sessione::<shard>` (blocco "un nome, un dispositivo").
- Globali: `corsiRegistrati::<corso>`, `dispositiviFidati::<id>`, `dispositiviBannati::<id>`, `dispositiviAttivi::<id>`.
- Lettura `loadList` (unisce cassetti + applica patch con `applicaPatchAElenco`), cache di sessione `_cacheCorso`.
  Al login si scarica il corso intero; 🔄 e i controlli usano l'aggiornamento **incrementale** (`aggiornaCacheIncrementale`:
  elenco chiavi + `updated_at`, si riscaricano solo le chiavi cambiate).
- Scrittura `aggiungiRecord` / `applicaPatch`: su Supabase via RPC **`aggiungi_record(p_chiave, p_record)`** (security
  invoker, rispetta RLS): il server aggiunge il record in coda al cassetto, si invia solo il record nuovo. Ripiego sul
  metodo classico (rilettura + riscrittura) se la RPC non c'è. Errore visibile se il salvataggio fallisce.
- I **controlli di disponibilità** (CO15, COGI, MIGO, MB1A/B/C, MBST, VL01N) usano `movimentiFreschi()` (movimenti di
  tutti aggiornati dal server), mai solo la copia in memoria della scheda.
- Giacenze calcolate con un indice (`_indiceGiacenze`) ricostruito solo quando cambiano i movimenti; MB51 mostra 500
  righe alla volta.

## Comportamenti consolidati (non cambiare senza discuterne)
- **Patch su record duplicati** (stessa chiave): dal 13/10/2026 10:55:30 (`PATCH_REGOLA_COPIA_VALIDA_DAL`) la patch va
  alla prima copia ancora valida che esisteva al momento della patch (15 min di tolleranza) e non tocca record creati
  dopo; prima di quella data vale la regola vecchia (primo record), così ciò che si vedeva non cambia.
- **Un nome, un dispositivo:** lo stesso nome non lavora da due browser/dispositivi insieme (schede dello stesso browser
  sì). Sblocco dal Pannello docente → Dispositivi → "Sblocca nome". Dispositivi del formatore esenti.
- **Password del sito** ricordata 12 ore per browser.
- **Messaggi dal formatore** (come SAP TH_POPUP / SM02): Pannello → Dispositivi → "✉ messaggio" (un dispositivo) o
  "📢 messaggio al corso". Chiavi `messaggi::<dispositivo>` e `messaggiCorso::<corso>` scritte solo dal docente; i
  dispositivi controllano ogni 30 s, mostrano ogni messaggio una volta e confermano la lettura nella presenza.
- **LS24** mostra anche merce in ubicazioni non più in anagrafica ("⚠ ubicazione non in anagrafica").
- **Sicurezza server:** i corsisti (chiave anon) scrivono solo `corso_*` (tranne `impostazioni`) e `dispositiviAttivi::*`,
  non cancellano; il docente usa le RPC `docente_*` con token ottenuto da `docente_accesso` (PIN verificati sul server);
  ogni valore cancellato/ridotto finisce in `storage_storico` per 30 giorni (Pannello → Sicurezza).
- MRP: MD02 = ordini di vendita aperti − (giacenza + ODP aperti) poi esplosione; MD01/MD03 dagli ODP aperti;
  dimensionamento lotto: politica → lotto minimo → arrotondamento → lotto massimo (FX ignora gli altri).
- Rettifiche: MB1A 702 (quantità da togliere), MB1C 701 (da aggiungere), MB1C 561, storno MBST.

## Pannello docente
Accesso dal login con due PIN. Schede: Corsi (crea, duplica, backup, elimina, giacenza negativa), Dispositivi
(collegati, blocca/sblocca, nomi in uso), Backup e ripristino, Pulizia dati, Sicurezza (cambio PIN, versioni
precedenti), Diagnostica.

## Questioni aperte (decide Stefano)
- **PRATOMAG, SU022 (Tayeba):** il 14/10 un MB1B 311 da una scheda con dati vecchi ha spostato 17.900 pz da OFFICINA
  a 1A1 con solo 500 presenti (OFFICINA a -17.400, poi ricoperta). Il totale è giusto ma 1A1 mostra 17.900 pz non reali:
  correzione MB1B 311 di 17.400 da 1A1 a OFFICINA, (a) da Tayeba o (b) da SG. Il difetto del programma è corretto dal 15/10.
- MIGO: tenere o togliere la ricezione riga per riga oltre a "Ricevi DDT completo".
- Elenco ordini di vendita tipo VA05 (oggi l'elenco è sotto VA01).
- MI01/MI04/MI07 (inventario fisico SAP) al posto delle sole rettifiche 701/702.
- Controllo al salvataggio dei movimenti verso ubicazioni eliminate.
- Opzionali: quantità modificabile in ME21N, backup automatico periodico.
- **Esercitazione guidata** (tipo SAP Enable Now / Fiori guided tours), proposta del 15/10, da riprendere: overlay che
  scurisce lo schermo e illumina con freccia e fumetto la voce di menu e poi campo per campo; il passo avanza solo quando
  l'azione è fatta davvero. Un unico percorso a passi numerati con mappa del progresso, riprendibile:
  1 VA01 · 2 MF50/CO01 · 3 MD02/MD01 (+MD04) · 4 ME21N · 5 MIGO (→RICEZIONE) · 6 ZMR01+MB1B 311 (→OFFICINA) ·
  7 CO15 · 8 MB1B 311 (OFFICINA→SPEDIZIONE) · 9 VL01N · 10 controllo MB51/MMBE/COOIS.
  Da decidere: prodotto (consigliato: un prodotto "da esercizio" identico per ciascuno), dati imposti (consigliato),
  guida rigida o morbida, attivazione per corso (consigliato: solo PISTOIALOG), progresso visibile nel Pannello docente.
  Primo prototipo previsto: motore + passi 1–2.

## Esercitazione in corso (PRATOMAG, dal 15/10/2026)
Ordini OV-0065…OV-0075 inseriti da SG con riferimento "ESERCIZIO 15/10 – <corsista>" (Davide, FLINT, modou, Tayeba):
difficoltà sulla capacità delle linee. Copia del corso prima delle modifiche: chiavi `corso_BACKUP-PRATOMAG-1510::*`.
