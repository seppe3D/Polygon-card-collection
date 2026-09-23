-- Polygon Trading Cards — 9 troostkatten i.p.v. 6
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor.
-- Veilig om opnieuw te draaien.
--
-- Controle vooraf (optioneel): zo zie je de huidige katten
--   select id, person, slot, name, image_url from public.cards where rarity = 'cat' order by slot;
--
-- Upload de 9 afbeeldingen naar de map "cards/" in je GitHub-repo met exact
-- deze bestandsnamen: kat-1.jpg .. kat-9.jpg
-- (de prompts staan in troostkatten-prompts.md)

-- 1. Drie extra kattenkaarten (slot 7-9), met dezelfde stats als de eerste kat
insert into public.cards (person, slot, name, rarity, hp, attack, defense)
select 'Katten', s.slot, 'Troostkat ' || s.slot, 'cat', c.hp, c.attack, c.defense
from generate_series(7, 9) as s(slot)
cross join (
  select hp, attack, defense from public.cards where rarity = 'cat' order by slot limit 1
) c
where not exists (
  select 1 from public.cards where rarity = 'cat' and slot = s.slot
);

-- 2. Namen, afbeeldingen en flavor text voor alle 9 katten
update public.cards set
  name = 'Could''ve Been an Email', image_url = 'cards/kat-1.jpg',
  flavor_text = 'Agenda item one: more naps.'
where rarity = 'cat' and slot = 1;

update public.cards set
  name = 'Reply All', image_url = 'cards/kat-2.jpg',
  flavor_text = 'Sent to everyone. Regrets: none.'
where rarity = 'cat' and slot = 2;

update public.cards set
  name = 'The Printer Exorcist', image_url = 'cards/kat-3.jpg',
  flavor_text = 'Paper jam in tray 2. The power of catnip compels you.'
where rarity = 'cat' and slot = 3;

update public.cards set
  name = 'Out of Office', image_url = 'cards/kat-4.jpg',
  flavor_text = 'Back never. Maybe Monday.'
where rarity = 'cat' and slot = 4;

update public.cards set
  name = 'The Coffee Machine Cult', image_url = 'cards/kat-5.jpg',
  flavor_text = 'Deliver us from decaf.'
where rarity = 'cat' and slot = 5;

update public.cards set
  name = 'Swivel Chair Hyperdrive', image_url = 'cards/kat-6.jpg',
  flavor_text = 'Productivity: zero. Velocity: maximum.'
where rarity = 'cat' and slot = 6;

update public.cards set
  name = 'The Stapler Heist', image_url = 'cards/kat-7.jpg',
  flavor_text = 'Get in. Get the stapler. Get out.'
where rarity = 'cat' and slot = 7;

update public.cards set
  name = 'Quarterly Targets', image_url = 'cards/kat-8.jpg',
  flavor_text = 'Q3 goals? Gravity says no.'
where rarity = 'cat' and slot = 8;

update public.cards set
  name = 'Cardboard Corner Office', image_url = 'cards/kat-9.jpg',
  flavor_text = 'If it fits, it''s a promotion.'
where rarity = 'cat' and slot = 9;
