-- Polygon Trading Cards — admin mode
-- Voer dit uit in Supabase SQL Editor, NADAT het account
-- seppe.cottenie@outlook.com bestaat (registreer eerst gewoon via de site).
-- Veilig om opnieuw te draaien.

-- Aparte tabel: gebruikers kunnen hier zelf niets in schrijven (geen
-- insert/update/delete policy), dus niemand kan zichzelf admin maken.
create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);
alter table public.admins enable row level security;
drop policy if exists "eigen adminstatus lezen" on public.admins;
create policy "eigen adminstatus lezen" on public.admins
  for select to authenticated using (auth.uid() = user_id);

insert into public.admins (user_id)
select id from auth.users where lower(email) = 'seppe.cottenie@outlook.com'
on conflict do nothing;

-- Controle: moet 1 rij teruggeven
select a.user_id, u.email from public.admins a join auth.users u on u.id = a.user_id;
