-- Polygon Trading Cards — uitbreiding v11: ideeënbus met upvotes
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor. Veilig om opnieuw te draaien.
-- Kies bij de waarschuwing van Supabase "Run without RLS": het script zet RLS zelf aan.
--
-- Iedereen (ingelogd) kan ideeën lezen, indienen en upvoten (1 stem per persoon per idee).
-- Je kan je eigen idee verwijderen; enkel admins (tabel public.admins) kunnen de status
-- aanpassen of andermans ideeën verwijderen.

create table if not exists public.suggestions (
  id bigserial primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  body text not null check (char_length(trim(body)) between 3 and 500),
  status text not null default 'open' check (status in ('open', 'planned', 'done', 'rejected')),
  created_at timestamptz not null default now()
);
create table if not exists public.suggestion_votes (
  suggestion_id bigint not null references public.suggestions(id) on delete cascade,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (suggestion_id, user_id)
);
alter table public.suggestions enable row level security;
alter table public.suggestion_votes enable row level security;

-- Is de ingelogde gebruiker admin? (werkt ook als de admins-tabel nog niet bestaat)
create or replace function public.is_admin() returns boolean
language plpgsql stable security definer set search_path = public as $$
begin
  if to_regclass('public.admins') is null then return false; end if;
  return exists (select 1 from public.admins where user_id = auth.uid());
end $$;
grant execute on function public.is_admin() to authenticated;

-- Ideeën
drop policy if exists "ideeen lezen" on public.suggestions;
create policy "ideeen lezen" on public.suggestions for select to authenticated using (true);
drop policy if exists "idee indienen" on public.suggestions;
create policy "idee indienen" on public.suggestions for insert to authenticated
  with check (user_id = auth.uid() and status = 'open');
drop policy if exists "idee verwijderen" on public.suggestions;
create policy "idee verwijderen" on public.suggestions for delete to authenticated
  using (user_id = auth.uid() or public.is_admin());
drop policy if exists "status aanpassen (admin)" on public.suggestions;
create policy "status aanpassen (admin)" on public.suggestions for update to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- Stemmen
drop policy if exists "stemmen lezen" on public.suggestion_votes;
create policy "stemmen lezen" on public.suggestion_votes for select to authenticated using (true);
drop policy if exists "stemmen" on public.suggestion_votes;
create policy "stemmen" on public.suggestion_votes for insert to authenticated with check (user_id = auth.uid());
drop policy if exists "stem intrekken" on public.suggestion_votes;
create policy "stem intrekken" on public.suggestion_votes for delete to authenticated using (user_id = auth.uid());

grant select, insert, delete on public.suggestions to authenticated;
grant update (status) on public.suggestions to authenticated;
grant select, insert, delete on public.suggestion_votes to authenticated;
grant usage on sequence public.suggestions_id_seq to authenticated;
