# Anon Rooms

Aplicație iOS cu camere de discuții anonime: camere publice pe teme și camere private cu cod de invitație.
SwiftUI + Supabase, build prin Codemagic (fără Mac). Interfața e în 8 limbi și ia automat limba telefonului:
engleză, română, spaniolă, franceză, germană, italiană, portugheză și arabă (cu afișare de la dreapta la stânga).

## Ce face

- Intri fără cont, cu o poreclă generată (o poți schimba).
- Camere publice pe teme, create de administrator: aceleași 8 teme în fiecare limbă. Fiecare utilizator vede camerele din limba telefonului.
- Fiecare cameră are tema ei: două culori și un emoji, folosite pe card, în bara de sus, pe fundal și pe baloane.
- Camere private: le creezi, primești un cod din 6 caractere și îl trimiți cui vrei.
- Mesaje în timp real, doar text, maximum 500 de caractere.
- Mesajele se șterg automat după 24 de ore.
- Moderare: filtru de cuvinte, raportare, blocare, ascundere automată la 3 rapoarte, ban, limită de 5 mesaje la 10 secunde.
- „Șterge datele mele” din Setări.

## Structură

```
AnonRooms/               codul aplicației (SwiftUI)
  Config.swift           URL Supabase, cheia publică, adresa de contact  ← de completat
  <limba>.lproj/         textele aplicației, câte un fișier Localizable.strings pe limbă
  Backend.swift          toate apelurile către Supabase
  AnonRoomsApp.swift       pornire, stare, ecranul de bun-venit
  RoomsView.swift        lista de camere și Setări
  ChatView.swift         camera de chat
  Models.swift           modele de date
supabase/migrations/     schema bazei de date
project.yml              din el se generează proiectul Xcode (XcodeGen)
codemagic.yaml           build și trimitere în TestFlight
```

## Pornire

1. **Supabase**: creezi un proiect nou, activezi Authentication → Sign In / Providers → „Allow anonymous sign-ins”,
   apoi rulezi `supabase/migrations/0001_init.sql` în SQL Editor.
2. **Config.swift**: pui Project URL, cheia publică și adresa de contact.
3. **Apple**: înregistrezi bundle ID-ul `ro.draghicioiu.anonrooms` și creezi aplicația în App Store Connect.
4. **Codemagic**: adaugi repo-ul, urmezi pașii din capul fișierului `codemagic.yaml`, pornești build-ul.
5. **Admin**: după ce deschizi aplicația pe telefon și îți alegi porecla, rulezi în SQL Editor:
   ```sql
   insert into public.admins (user_id)
   select id from public.profiles where nickname = 'PORECLA_TA';
   ```
   De atunci ai în aplicație, la apăsare lungă pe un mesaj, „Șterge (admin)” și „Ban 24 de ore (admin)”.

## Moderare din Supabase

```sql
-- rapoarte nerezolvate
select * from public.reports where not resolved order by created_at desc;

-- ban permanent
insert into public.bans (user_id, reason) values ('ID-UTILIZATOR', 'motiv');

-- cuvânt nou în filtru
insert into public.banned_words (word) values ('cuvant');

-- cameră publică nouă
-- color_a și color_b sunt cele două culori ale temei (cod hex)
-- lang = limba în care apare camera ('ro', 'en', 'ar'…); null = apare în toate limbile
insert into public.rooms (lang, name, emoji, description, color_a, color_b, sort)
values ('ro', 'Nume', '🎲', 'Descriere', '#FF6B6B', '#FFA94D', 90);
```
