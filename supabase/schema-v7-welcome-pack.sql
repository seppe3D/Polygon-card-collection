-- Polygon Trading Cards — uitbreiding v7: welkomstpakket
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor. Veilig om opnieuw te draaien.
--
-- Elke gebruiker kan precies één keer een welkomstpakket met 3 willekeurige
-- (verschillende) common-kaarten ophalen via de knop op de website.

create table if not exists public.welcome_packs (
  user_id uuid primary key references auth.users(id) on delete cascade,
  card_ids int[] not null,
  claimed_at timestamptz not null default now()
);
alter table public.welcome_packs enable row level security;
drop policy if exists "eigen welkomstpakket lezen" on public.welcome_packs;
create policy "eigen welkomstpakket lezen" on public.welcome_packs
  for select to authenticated using (auth.uid() = user_id);
-- Bewust GEEN insert/update/delete policy: ophalen kan enkel via claim_welcome_pack().

create or replace function public.claim_welcome_pack()
returns setof public.cards
language plpgsql security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  v_ids int[];
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if exists (select 1 from public.welcome_packs where user_id = me) then
    raise exception 'Je hebt je welkomstpakket al ontvangen.';
  end if;

  select array_agg(id) into v_ids
  from (select id from public.cards where rarity = 'common' order by random() limit 3) x;
  if coalesce(array_length(v_ids, 1), 0) < 3 then
    raise exception 'Er zijn niet genoeg common-kaarten om een pakket te maken.';
  end if;

  -- De primary key op user_id zorgt dat twee snelle klikken nooit twee pakketten opleveren
  begin
    insert into public.welcome_packs (user_id, card_ids) values (me, v_ids);
  exception when unique_violation then
    raise exception 'Je hebt je welkomstpakket al ontvangen.';
  end;

  insert into public.user_cards (user_id, card_id) select me, unnest(v_ids);

  return query
    select c.* from unnest(v_ids) with ordinality u(id, ord)
    join public.cards c on c.id = u.id
    order by u.ord;
end;
$$;

grant execute on function public.claim_welcome_pack() to authenticated;
