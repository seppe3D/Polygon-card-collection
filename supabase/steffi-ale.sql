-- Polygon Trading Cards — nieuwe collega's: Steffi en Ale (elk 9 kaarten)
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor.
-- Veilig om opnieuw te draaien: bestaande kaarten worden bijgewerkt, niet dubbel aangemaakt.
--
-- Upload de afbeeldingen naar de map "cards/" op GitHub met exact deze namen
-- (1-6 = common, 7-8 = epic, 9 = legendary):
--   steffi-1.jpg .. steffi-9.jpg
--   ale-1.jpg    .. ale-9.jpg

-- 1. Lege kaarten aanmaken, met dezelfde HP/ATK/DEF als Marvin op hetzelfde slot
insert into public.cards (person, slot, name, rarity, hp, attack, defense)
select p.person, m.slot, p.person || ' ' || m.slot, m.rarity, m.hp, m.attack, m.defense
from (values ('Steffi'), ('Ale')) as p(person)
cross join public.cards m
where m.person = 'Marvin'
  and not exists (select 1 from public.cards c where c.person = p.person and c.slot = m.slot);

-- 2. Namen, afbeeldingen, flavor text en specials

-- ===================== STEFFI =====================

update public.cards set
  name = 'Inbox Summit', image_url = 'cards/steffi-1.jpg',
  flavor_text = 'Inbox zero is just a rumour.'
where person = 'Steffi' and slot = 1;

update public.cards set
  name = 'Desk Fortress', image_url = 'cards/steffi-2.jpg',
  flavor_text = 'Focus mode: fully fortified.'
where person = 'Steffi' and slot = 2;

update public.cards set
  name = 'Colour-Coded Everything', image_url = 'cards/steffi-3.jpg',
  flavor_text = 'If it moves, it gets a colour.'
where person = 'Steffi' and slot = 3;

update public.cards set
  name = 'Guardian of the Chair', image_url = 'cards/steffi-4.jpg',
  flavor_text = 'Finders keepers? Not on her watch.'
where person = 'Steffi' and slot = 4;

update public.cards set
  name = 'Fire Drill Priorities', image_url = 'cards/steffi-5.jpg',
  flavor_text = 'Grab what matters. All of it.'
where person = 'Steffi' and slot = 5;

update public.cards set
  name = 'Frozen Lunch Expedition', image_url = 'cards/steffi-6.jpg',
  flavor_text = 'Lunch is served. Eventually.'
where person = 'Steffi' and slot = 6;

update public.cards set
  name = 'Glitter Workshop', image_url = 'cards/steffi-7.jpg',
  flavor_text = 'Glitter is forever.'
where person = 'Steffi' and slot = 7;

update public.cards set
  name = 'Renovation Mode', image_url = 'cards/steffi-8.jpg',
  flavor_text = 'Every wall is just a suggestion.'
where person = 'Steffi' and slot = 8;

update public.cards set
  name = 'Architect of Home', image_url = 'cards/steffi-9.jpg',
  flavor_text = 'Built with love. And a lot of screws.',
  special_name = 'Family Foundation',
  special_desc = 'Raises an unbreakable fortress around her team and flattens every intruder with a flying toolbox.',
  special_power = 80
where person = 'Steffi' and slot = 9;

-- ===================== ALE =====================

update public.cards set
  name = 'Stand-Up Meeting', image_url = 'cards/ale-1.jpg',
  flavor_text = 'Attendance optional. Enthusiasm mandatory.'
where person = 'Ale' and slot = 1;

update public.cards set
  name = 'Snack Drawer Avalanche', image_url = 'cards/ale-2.jpg',
  flavor_text = 'Just one more cookie, he said.'
where person = 'Ale' and slot = 2;

update public.cards set
  name = 'The Human Coat Rack', image_url = 'cards/ale-3.jpg',
  flavor_text = 'Nobody asked. Everybody used.'
where person = 'Ale' and slot = 3;

update public.cards set
  name = 'Password Expired', image_url = 'cards/ale-4.jpg',
  flavor_text = 'Must contain a symbol, a number and a miracle.'
where person = 'Ale' and slot = 4;

update public.cards set
  name = 'Hot Desk', image_url = 'cards/ale-5.jpg',
  flavor_text = 'First come, first scorched.'
where person = 'Ale' and slot = 5;

update public.cards set
  name = 'Out of Toner', image_url = 'cards/ale-6.jpg',
  flavor_text = 'The printer won. This time.'
where person = 'Ale' and slot = 6;

update public.cards set
  name = 'Pura Vida Fiesta', image_url = 'cards/ale-7.jpg',
  flavor_text = 'Gallo pinto for breakfast. Pura vida all day.'
where person = 'Ale' and slot = 7;

update public.cards set
  name = 'Unplugged Session', image_url = 'cards/ale-8.jpg',
  flavor_text = 'One more song, then the budget review.'
where person = 'Ale' and slot = 8;

update public.cards set
  name = 'Rainforest Rockstar', image_url = 'cards/ale-9.jpg',
  flavor_text = 'Turn it up. The jungle is listening.',
  special_name = 'Pura Vida Power Chord',
  special_desc = 'Unleashes a thunderous riff that echoes through the rainforest, stunning every opponent in a storm of sound and colour.',
  special_power = 80
where person = 'Ale' and slot = 9;

-- Controle: moet 18 rijen geven (9 per persoon)
select person, slot, name, rarity, hp, attack, defense from public.cards
where person in ('Steffi', 'Ale') order by person desc, slot;
