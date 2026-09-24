-- Polygon Trading Cards — uitbreiding v10: Shop (pakjes, kaarten kopen, dubbels verkopen, Wordle-hulp)
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor, ná schema-v8-wordle.sql.
-- Veilig om opnieuw te draaien. Kies bij de waarschuwing van Supabase "Run without RLS".
--
-- Prijzen (polycoins)
--   Basic Pack (1 kaart: 75% common, 22% epic, 3% legendary) ........ 60
--   Epic Pack (3 kaarten, de 3e gegarandeerd epic (85%) of legendary (15%)) 200
--   Ontbrekende kaart kopen: common 150 · epic 400 · legendary 1000
--   Dubbel verkopen (per extra exemplaar): common 15 · epic 40 · legendary 100 · troostkat 5
--   Wordle: letter onthullen 40 (max 2 per ronde) · extra 7e poging 60 (1 per ronde)

-- 0. Beveiliging: saldo en kaarten kunnen enkel via de functies veranderen -----------------
-- De website schrijft nooit rechtstreeks in deze tabellen; alle wijzigingen gebeuren via
-- security definer-functies (en de oude Edge Function met de service role). Zo kan niemand
-- zijn polycoins of kaarten vervalsen, ongeacht welke policies er ooit op stonden.
revoke insert, update, delete on public.user_wallet from anon, authenticated;
revoke insert, update, delete on public.user_cards from anon, authenticated;
revoke insert, update, delete on public.daily_plays from anon, authenticated;

-- 1. Wordle-hulp: extra kolommen ------------------------------------------------------
alter table public.wordle_games add column if not exists hints jsonb not null default '[]'::jsonb;
alter table public.wordle_games add column if not exists extra_guess boolean not null default false;

-- 2. Logboek van aankopen (enkel je eigen rijen zichtbaar) ------------------------------
create table if not exists public.shop_log (
  id bigserial primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  kind text not null,
  amount int not null,            -- negatief = uitgegeven, positief = verdiend
  detail jsonb,
  created_at timestamptz not null default now()
);
create index if not exists shop_log_user_idx on public.shop_log (user_id, created_at desc);
alter table public.shop_log enable row level security;
drop policy if exists "eigen aankopen lezen" on public.shop_log;
create policy "eigen aankopen lezen" on public.shop_log for select to authenticated using (auth.uid() = user_id);

-- 3. Hulpfuncties ------------------------------------------------------------------------
-- Polycoins uitgeven: faalt als het saldo te laag is (geen negatief saldo mogelijk)
create or replace function public._shop_spend(p_user uuid, p_amount int, p_kind text, p_detail jsonb default null) returns int
language plpgsql volatile security definer set search_path = public as $$
declare v int;
begin
  update public.user_wallet set polycoins = polycoins - p_amount
    where user_id = p_user and polycoins >= p_amount
    returning polycoins into v;
  if not found then
    raise exception 'Niet genoeg polycoins: je hebt er %, je hebt er % nodig.',
      coalesce((select polycoins from public.user_wallet where user_id = p_user), 0), p_amount;
  end if;
  insert into public.shop_log (user_id, kind, amount, detail) values (p_user, p_kind, -p_amount, p_detail);
  return v;
end $$;

-- Eén kaart van een bepaalde zeldzaamheid toevoegen aan de collectie
create or replace function public._shop_give(p_user uuid, p_rarity text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare v_card public.cards; v_dup boolean;
begin
  select * into v_card from public.cards where rarity = p_rarity order by random() limit 1;
  if not found then raise exception 'Geen kaarten gevonden voor zeldzaamheid %.', p_rarity; end if;
  v_dup := exists (select 1 from public.user_cards where user_id = p_user and card_id = v_card.id);
  insert into public.user_cards (user_id, card_id) values (p_user, v_card.id);
  return to_jsonb(v_card) || jsonb_build_object('is_duplicate', v_dup);
end $$;

create or replace function public._shop_roll(p_legendary float8, p_epic float8) returns text
language sql volatile as $$
  select case when r < p_legendary then 'legendary' when r < p_legendary + p_epic then 'epic' else 'common' end
  from (select random() * 100 as r) x;
$$;

revoke all on function public._shop_spend(uuid, int, text, jsonb) from public, anon, authenticated;
revoke all on function public._shop_give(uuid, text) from public, anon, authenticated;

-- 4. Pakjes kopen --------------------------------------------------------------------------
create or replace function public.shop_buy_pack(p_kind text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); v_wallet int; v_cards jsonb := '[]'::jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_kind = 'basic' then
    v_wallet := public._shop_spend(me, 60, 'pack_basic');
    v_cards := v_cards || public._shop_give(me, public._shop_roll(3, 22));
  elsif p_kind = 'epic' then
    v_wallet := public._shop_spend(me, 200, 'pack_epic');
    v_cards := v_cards || public._shop_give(me, public._shop_roll(3, 22));
    v_cards := v_cards || public._shop_give(me, public._shop_roll(3, 22));
    v_cards := v_cards || public._shop_give(me, public._shop_roll(15, 85));
  else
    raise exception 'Onbekend pakje.';
  end if;
  update public.shop_log set detail = jsonb_build_object('cards', (select jsonb_agg(c->'id') from jsonb_array_elements(v_cards) c))
    where id = (select max(id) from public.shop_log where user_id = me);
  return jsonb_build_object('cards', v_cards, 'wallet', v_wallet);
end $$;

-- 5. Een ontbrekende kaart kopen -------------------------------------------------------------
create or replace function public.shop_buy_card(p_card_id int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); v_card public.cards; v_price int; v_wallet int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into v_card from public.cards where id = p_card_id;
  if not found then raise exception 'Kaart niet gevonden.'; end if;
  if v_card.rarity = 'cat' then raise exception 'Troostkatten zijn niet te koop.'; end if;
  if exists (select 1 from public.user_cards where user_id = me and card_id = p_card_id) then
    raise exception 'Je hebt deze kaart al.';
  end if;
  v_price := case v_card.rarity when 'common' then 150 when 'epic' then 400 else 1000 end;
  v_wallet := public._shop_spend(me, v_price, 'buy_card', jsonb_build_object('card', p_card_id));
  insert into public.user_cards (user_id, card_id) values (me, p_card_id);
  return jsonb_build_object('card', to_jsonb(v_card), 'wallet', v_wallet);
end $$;

-- 6. Dubbels verkopen (je houdt altijd minstens 1 exemplaar) -----------------------------------
create or replace function public.shop_sell_duplicates(p_card_id int, p_count int default 1) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); v_card public.cards; v_have int; v_price int; v_earned int; v_wallet int; i int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_count < 1 then raise exception 'Verkoop minstens 1 exemplaar.'; end if;
  select * into v_card from public.cards where id = p_card_id;
  if not found then raise exception 'Kaart niet gevonden.'; end if;
  select count(*) into v_have from public.user_cards where user_id = me and card_id = p_card_id;
  if v_have - p_count < 1 then raise exception 'Je kan enkel dubbels verkopen: je houdt altijd 1 exemplaar.'; end if;
  for i in 1..p_count loop
    delete from public.user_cards where id = (select id from public.user_cards where user_id = me and card_id = p_card_id order by id desc limit 1);
  end loop;
  v_price := case v_card.rarity when 'common' then 15 when 'epic' then 40 when 'legendary' then 100 else 5 end;
  v_earned := v_price * p_count;
  insert into public.user_wallet (user_id, polycoins) values (me, v_earned)
    on conflict (user_id) do update set polycoins = public.user_wallet.polycoins + excluded.polycoins
    returning polycoins into v_wallet;
  insert into public.shop_log (user_id, kind, amount, detail) values (me, 'sell_duplicate', v_earned, jsonb_build_object('card', p_card_id, 'count', p_count));
  return jsonb_build_object('sold', p_count, 'earned', v_earned, 'wallet', v_wallet);
end $$;

-- 7. Wordle-hulp ---------------------------------------------------------------------------------
-- Onthult een letter op een plaats die je nog niet groen hebt (max 2 per ronde)
create or replace function public.wordle_hint(p_slot int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  loc timestamp := public._wordle_local();
  d date := loc::date;
  g public.wordle_games; w text; pos int; v_wallet int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_slot not in (1, 2) or loc::time < public._wordle_opens(p_slot) then raise exception 'Deze Wordle is nog niet open.'; end if;
  insert into public.wordle_games (user_id, round_date, slot) values (me, d, p_slot) on conflict do nothing;
  select * into g from public.wordle_games where user_id = me and round_date = d and slot = p_slot for update;
  if g.status <> 'playing' then raise exception 'Deze Wordle is al afgelopen.'; end if;
  if jsonb_array_length(g.hints) >= 2 then raise exception 'Je kan maximaal 2 letters per ronde onthullen.'; end if;
  w := public._wordle_word(d, p_slot);
  -- Plaatsen die nog niet gekend zijn: nooit groen gegokt en nog niet onthuld
  select p into pos from generate_series(1, 5) p
  where not exists (select 1 from unnest(g.guesses) x where substr(x, p, 1) = substr(w, p, 1))
    and not exists (select 1 from jsonb_array_elements(g.hints) h where (h->>'pos')::int = p)
  order by random() limit 1;
  if pos is null then raise exception 'Je kent alle letters al — nu nog de juiste volgorde!'; end if;
  v_wallet := public._shop_spend(me, 40, 'wordle_hint', jsonb_build_object('date', d, 'slot', p_slot));
  update public.wordle_games set hints = hints || jsonb_build_object('pos', pos, 'letter', substr(w, pos, 1))
    where user_id = me and round_date = d and slot = p_slot;
  return jsonb_build_object('pos', pos, 'letter', substr(w, pos, 1), 'wallet', v_wallet);
end $$;

-- Koopt een 7e poging voor deze ronde (moet vóór je 6e gok)
create or replace function public.wordle_extra_guess(p_slot int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  loc timestamp := public._wordle_local();
  d date := loc::date;
  g public.wordle_games; v_wallet int;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_slot not in (1, 2) or loc::time < public._wordle_opens(p_slot) then raise exception 'Deze Wordle is nog niet open.'; end if;
  insert into public.wordle_games (user_id, round_date, slot) values (me, d, p_slot) on conflict do nothing;
  select * into g from public.wordle_games where user_id = me and round_date = d and slot = p_slot for update;
  if g.status <> 'playing' then raise exception 'Deze Wordle is al afgelopen.'; end if;
  if g.extra_guess then raise exception 'Je hebt voor deze ronde al een extra poging.'; end if;
  v_wallet := public._shop_spend(me, 60, 'wordle_extra', jsonb_build_object('date', d, 'slot', p_slot));
  update public.wordle_games set extra_guess = true where user_id = me and round_date = d and slot = p_slot;
  return jsonb_build_object('max_guesses', 7, 'wallet', v_wallet);
end $$;

-- 8. Bijgewerkte Wordle-functies (7e poging + onthulde letters) -----------------------------------
create or replace function public._wordle_draw(p_user uuid, p_attempts int) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  r float8 := random() * 100;
  leg float8; ep float8; v_rarity text;
  v_card public.cards; v_dup boolean; v_coins int;
begin
  if p_attempts is null then
    v_rarity := 'cat';
  else
    leg := (array[80, 30, 10, 3, 1, 0.5])[least(p_attempts, 6)];
    ep  := (array[20, 50, 35, 22, 11, 4.5])[least(p_attempts, 6)];
    v_rarity := case when r < leg then 'legendary' when r < leg + ep then 'epic' else 'common' end;
  end if;
  select * into v_card from public.cards where rarity = v_rarity order by random() limit 1;
  if not found then raise exception 'Geen kaarten gevonden voor zeldzaamheid %.', v_rarity; end if;
  v_dup := exists (select 1 from public.user_cards where user_id = p_user and card_id = v_card.id);
  insert into public.user_cards (user_id, card_id) values (p_user, v_card.id);  -- dubbels komen er ook bij
  v_coins := 0;
  if v_dup then
    v_coins := case v_rarity when 'common' then 10 when 'epic' then 25 when 'legendary' then 60 else 5 end;
    insert into public.user_wallet (user_id, polycoins) values (p_user, v_coins)
      on conflict (user_id) do update set polycoins = public.user_wallet.polycoins + excluded.polycoins;
  end if;
  return jsonb_build_object('card', to_jsonb(v_card), 'dup', v_dup, 'coins', v_coins);
end $$;


revoke all on function public._wordle_draw(uuid, int) from public, anon, authenticated;

create or replace function public.wordle_state() returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  loc timestamp := public._wordle_local();
  d date := loc::date;
  out_ jsonb := '[]'::jsonb;
  s int; g public.wordle_games; w text; rows_ jsonb; opens time;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  for s in 1..2 loop
    opens := public._wordle_opens(s);
    select * into g from public.wordle_games where user_id = me and round_date = d and slot = s;
    rows_ := '[]'::jsonb;
    if found and coalesce(array_length(g.guesses, 1), 0) > 0 then
      w := public._wordle_word(d, s);
      select coalesce(jsonb_agg(jsonb_build_object('w', x.guess, 'r', public._wordle_score(x.guess, w)) order by x.n), '[]')
        into rows_ from unnest(g.guesses) with ordinality x(guess, n);
    end if;
    out_ := out_ || jsonb_build_object(
      'slot', s,
      'opens', to_char(opens, 'HH24:MI'),
      'open', loc::time >= opens,
      'seconds_until_open', greatest(0, extract(epoch from (d + opens) - loc))::int,
      'status', coalesce(g.status, 'new'),
      'rows', rows_,
      'attempts', g.attempts,
      'hints', coalesce(g.hints, '[]'::jsonb),
      'max_guesses', 6 + case when g.extra_guess then 1 else 0 end,
      'card_id', g.card_id,
      'answer', case when g.status = 'lost' then public._wordle_word(d, s) end
    );
  end loop;
  return jsonb_build_object('date', d, 'slots', out_);
end $$;


create or replace function public.wordle_guess(p_slot int, p_guess text) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  loc timestamp := public._wordle_local();
  d date := loc::date;
  guess text := upper(trim(p_guess));
  g public.wordle_games;
  w text; score text; n int;
  v_draw jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_slot not in (1, 2) then raise exception 'Onbekende ronde.'; end if;
  if loc::time < public._wordle_opens(p_slot) then
    raise exception 'Deze Wordle opent pas om % (Belgische tijd).', to_char(public._wordle_opens(p_slot), 'HH24:MI');
  end if;
  if guess !~ '^[A-Z]{5}$' then raise exception 'Een gok moet uit precies 5 letters bestaan.'; end if;

  insert into public.wordle_games (user_id, round_date, slot) values (me, d, p_slot) on conflict do nothing;
  select * into g from public.wordle_games where user_id = me and round_date = d and slot = p_slot for update;
  if g.status <> 'playing' then raise exception 'Deze Wordle heb je al gespeeld.'; end if;

  w := public._wordle_word(d, p_slot);
  score := public._wordle_score(guess, w);
  g.guesses := g.guesses || guess;
  n := array_length(g.guesses, 1);

  if score = 'ggggg' or n >= 6 + (case when g.extra_guess then 1 else 0 end) then
    g.status := case when score = 'ggggg' then 'won' else 'lost' end;
    g.attempts := case when g.status = 'won' then n end;
    v_draw := public._wordle_draw(me, g.attempts);
    update public.wordle_games set guesses = g.guesses, status = g.status, attempts = g.attempts,
      card_id = (v_draw->'card'->>'id')::int, is_duplicate = (v_draw->>'dup')::boolean,
      coins_earned = (v_draw->>'coins')::int, finished_at = now()
    where user_id = me and round_date = d and slot = p_slot;
    return jsonb_build_object('result', score, 'status', g.status, 'attempts', g.attempts, 'guess', guess,
      'card', v_draw->'card', 'rarity', v_draw->'card'->>'rarity', 'isDuplicate', (v_draw->>'dup')::boolean,
      'coinsEarned', (v_draw->>'coins')::int,
      'cardAdded', true, 'solved', g.status = 'won', 'answer', case when g.status = 'lost' then w end);
  end if;

  update public.wordle_games set guesses = g.guesses where user_id = me and round_date = d and slot = p_slot;
  return jsonb_build_object('result', score, 'status', 'playing', 'guess', guess, 'wallet', (select polycoins from public.user_wallet where user_id = me));
end $$;


grant execute on function public.shop_buy_pack(text) to authenticated;
-- Gericht een kaart kopen is uitgeschakeld (zou tonen welke kaarten er bestaan)
revoke execute on function public.shop_buy_card(int) from public, anon, authenticated;
grant execute on function public.shop_sell_duplicates(int, int) to authenticated;
grant execute on function public.wordle_hint(int) to authenticated;
grant execute on function public.wordle_extra_guess(int) to authenticated;
