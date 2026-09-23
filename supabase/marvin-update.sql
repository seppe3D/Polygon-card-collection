-- Polygon Trading Cards — nieuwe kaarten Marvin 1, 2, 7 en 9
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor.
-- Veilig om opnieuw te draaien. Afbeeldingen: cards/marvin-1/2/7/9.jpg

update public.cards set
  name = 'Remote Work', image_url = 'cards/marvin-1.jpg',
  flavor_text = 'Technically still in the office.'
where person = 'Marvin' and slot = 1;

update public.cards set
  name = 'Cable Chaos', image_url = 'cards/marvin-2.jpg',
  flavor_text = 'Just one more cable. Probably.'
where person = 'Marvin' and slot = 2;

update public.cards set
  name = 'The Filament Forge', image_url = 'cards/marvin-7.jpg',
  flavor_text = 'Layer by layer, legends are printed.'
where person = 'Marvin' and slot = 7;

update public.cards set
  name = 'King of the Classics', image_url = 'cards/marvin-9.jpg',
  flavor_text = 'Cobbles conquered. Hearts conquered.',
  special_name = 'Golden Sprint',
  special_desc = 'Launches an unstoppable final sprint over the cobbles, leaving every rival in the dust and every fan cheering.',
  special_power = 80
where person = 'Marvin' and slot = 9;
