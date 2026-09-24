-- Polygon Trading Cards — uitbreiding v9: tactische battles (ronde per ronde) + polycoins
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor. Veilig om opnieuw te draaien.
-- Kies bij de waarschuwing van Supabase "Run without RLS": het script zet RLS zelf aan.
--
-- Spelregels
-- - Team van 3 kaarten; elke ronde kiezen beide spelers tegelijk (en geheim) een zet:
--     attack  : normale aanval, +1 energie
--     power   : krachtaanval (1,7x schade), kost 2 energie
--     guard   : verdedigen, halve schade deze ronde, +2 energie
--     special : enkel kaarten met een special (legendaries), kost 4 energie, gaat door verdediging
--     switch  : wissel je actieve kaart met een kaart van je bank (gebeurt vóór de aanvallen), +1 energie
--     forfeit : opgeven
-- - Wisselen gebeurt eerst, daarna valt de kaart met de hoogste ATK eerst aan.
-- - Een uitgeschakelde kaart wordt automatisch vervangen door de volgende in je team.
-- - Beloningen: computer makkelijk/normaal/moeilijk = 5/10/20 polycoins (max 5 per dag),
--   vriend: winnaar 25, verliezer 5 (max 3 per dag). Opgeven levert niets op.

-- 1. Tabellen ------------------------------------------------------------------
create table if not exists public.tbattles (
  id bigserial primary key,
  mode text not null check (mode in ('pve', 'pvp')),
  difficulty text check (difficulty in ('easy', 'normal', 'hard')),
  player_a uuid not null references auth.users(id) on delete cascade,   -- speler / uitdager
  player_b uuid references auth.users(id) on delete cascade,            -- vriend (null = computer)
  status text not null default 'pending' check (status in ('pending', 'active', 'done', 'declined', 'cancelled')),
  state jsonb,                 -- publiek spelverloop (nooit geheime zetten)
  round int not null default 0,
  winner text check (winner in ('A', 'B')),
  forfeit boolean not null default false,
  coins_a int not null default 0,
  coins_b int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  finished_at timestamptz
);
create index if not exists tbattles_a_idx on public.tbattles (player_a, status);
create index if not exists tbattles_b_idx on public.tbattles (player_b, status);
alter table public.tbattles enable row level security;
drop policy if exists "eigen tactische battles lezen" on public.tbattles;
create policy "eigen tactische battles lezen" on public.tbattles
  for select to authenticated using (auth.uid() = player_a or auth.uid() = player_b);

-- Geheime gegevens: het team van de uitdager (tot de ander accepteert) en de gekozen zetten
create table if not exists public.tbattle_hidden (
  battle_id bigint not null references public.tbattles(id) on delete cascade,
  side text not null check (side in ('A', 'B')),
  cards int[],
  action text,
  target int,
  primary key (battle_id, side)
);
alter table public.tbattle_hidden enable row level security;
-- Bewust GEEN policies: niemand kan de zet van de tegenstander lezen.

-- 2. Hulpfuncties ----------------------------------------------------------------
create or replace function public._tb_team_ok(p_user uuid, p_cards int[]) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(array_length(p_cards, 1), 0) = 3
     and (select count(distinct x) from unnest(p_cards) x) = 3
     and not exists (select 1 from unnest(p_cards) x
                     where not exists (select 1 from public.user_cards uc where uc.user_id = p_user and uc.card_id = x));
$$;

-- Eén kant van het speelveld, met de stats van de kaarten
create or replace function public._tb_side(p_cards int[]) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'cards', jsonb_agg(c.id order by u.ord),
    'hp', jsonb_agg(coalesce(c.hp, 50) order by u.ord),
    'max', jsonb_agg(coalesce(c.hp, 50) order by u.ord),
    'atk', jsonb_agg(coalesce(c.attack, 10) order by u.ord),
    'def', jsonb_agg(coalesce(c.defense, 0) order by u.ord),
    'sp', jsonb_agg(coalesce(c.special_power, 0) order by u.ord),
    'active', 0, 'energy', 1)
  from unnest(p_cards) with ordinality u(id, ord) join public.cards c on c.id = u.id;
$$;

create or replace function public._tb_pay(p_user uuid, p_amount int) returns void
language sql security definer set search_path = public as $$
  insert into public.user_wallet (user_id, polycoins) values (p_user, p_amount)
  on conflict (user_id) do update set polycoins = public.user_wallet.polycoins + excluded.polycoins;
$$;

-- Aantal beloonde battles van vandaag (Belgische tijd) voor een gebruiker en modus
create or replace function public._tb_rewarded_today(p_user uuid, p_mode text) returns int
language sql stable security definer set search_path = public as $$
  select count(*)::int from public.tbattles b
  where b.mode = p_mode and b.status = 'done'
    and (b.finished_at at time zone 'Europe/Brussels')::date = (now() at time zone 'Europe/Brussels')::date
    and ((b.player_a = p_user and b.coins_a > 0) or (b.player_b = p_user and b.coins_b > 0));
$$;

-- Zet van de computer
create or replace function public._tb_ai(p_state jsonb, p_side text, p_diff text) returns jsonb
language plpgsql volatile as $$
declare
  me jsonb := p_state -> p_side;
  op jsonb := p_state -> (case p_side when 'A' then 'B' else 'A' end);
  a int := (me->>'active')::int;
  o int := (op->>'active')::int;
  en int := (me->>'energy')::int;
  sp int := (me->'sp'->>a)::int;
  hp_pct float8 := (me->'hp'->>a)::float8 / greatest(1, (me->'max'->>a)::float8);
  best int; best_pct float8 := 0; i int; r float8 := random();
begin
  if p_diff = 'easy' then
    if sp > 0 and en >= 4 and r < .5 then return '{"a":"special"}'; end if;
    if en >= 2 and r < .2 then return '{"a":"power"}'; end if;
    if r < .35 then return '{"a":"guard"}'; end if;
    return '{"a":"attack"}';
  end if;
  if sp > 0 and en >= 4 then return '{"a":"special"}'; end if;
  -- Zwakke kaart in veiligheid brengen
  for i in 0..jsonb_array_length(me->'hp') - 1 loop
    if i <> a and (me->'hp'->>i)::int > 0
       and (me->'hp'->>i)::float8 / (me->'max'->>i)::float8 > best_pct then
      best := i; best_pct := (me->'hp'->>i)::float8 / (me->'max'->>i)::float8;
    end if;
  end loop;
  if hp_pct < .3 and best is not null and best_pct > .6 and random() < (case p_diff when 'hard' then .6 else .35 end) then
    return jsonb_build_object('a', 'switch', 't', best);
  end if;
  -- Verdedigen als de tegenstander een special klaar heeft
  if (op->'sp'->>o)::int > 0 and (op->>'energy')::int >= 4 and random() < (case p_diff when 'hard' then .7 else .4 end) then
    return '{"a":"guard"}';
  end if;
  if en >= 2 and random() < .6 then return '{"a":"power"}'; end if;
  if p_diff = 'hard' and en < 2 and random() < .2 then return '{"a":"guard"}'; end if;
  return '{"a":"attack"}';
end $$;

-- Eén ronde afwikkelen zodra beide zetten gekend zijn
create or replace function public._tb_resolve(p_id bigint) returns void
language plpgsql volatile security definer set search_path = public as $$
declare
  b public.tbattles;
  st jsonb; ev jsonb; r int;
  act jsonb;
  s text; d text; att text; kind text;
  order_ text[]; dmg int; base float8; crit boolean; guarded boolean;
  ai int; di int; nxt int; i int; w text;
  v_ca int := 0; v_cb int := 0; reward int;
begin
  select * into b from public.tbattles where id = p_id for update;
  st := b.state || '{"_act": {}}'::jsonb; ev := coalesce(st->'events', '[]'::jsonb); r := b.round + 1;
  -- Gekozen zetten ophalen: {"_act": {"A": {"a": .., "t": ..}, "B": {...}}}
  for s in select unnest(array['A', 'B']) loop
    select jsonb_build_object('a', h.action, 't', h.target) into act from public.tbattle_hidden h where h.battle_id = p_id and h.side = s;
    st := jsonb_set(st, array['_act', s], coalesce(act, '{"a": "attack"}'::jsonb));
  end loop;

  -- Opgeven
  for s in select unnest(array['A', 'B']) loop
    if st->'_act'->s->>'a' = 'forfeit' then
      w := case s when 'A' then 'B' else 'A' end;
      ev := ev || jsonb_build_object('r', r, 't', 'forfeit', 's', s);
    end if;
  end loop;

  if w is null then
    -- 1. Wissels
    for s in select unnest(array['A', 'B']) loop
      if st->'_act'->s->>'a' = 'switch' then
        st := jsonb_set(st, array[s, 'active'], to_jsonb((st->'_act'->s->>'t')::int));
        ev := ev || jsonb_build_object('r', r, 't', 'switch', 's', s, 'i', (st->'_act'->s->>'t')::int);
      elsif st->'_act'->s->>'a' = 'guard' then
        ev := ev || jsonb_build_object('r', r, 't', 'guard', 's', s);
      end if;
    end loop;
    -- 2. Energie betalen
    for s in select unnest(array['A', 'B']) loop
      if st->'_act'->s->>'a' = 'power' then
        st := jsonb_set(st, array[s, 'energy'], to_jsonb((st->s->>'energy')::int - 2));
      elsif st->'_act'->s->>'a' = 'special' then
        st := jsonb_set(st, array[s, 'energy'], to_jsonb((st->s->>'energy')::int - 4));
      end if;
    end loop;
    -- 3. Aanvallen: hoogste ATK eerst (gelijk = toeval)
    order_ := case
      when (st->'A'->'atk'->>((st->'A'->>'active')::int))::int + random() * .5 >=
           (st->'B'->'atk'->>((st->'B'->>'active')::int))::int + random() * .5
      then array['A', 'B'] else array['B', 'A'] end;
    foreach s in array order_ loop
      kind := st->'_act'->s->>'a';
      if kind not in ('attack', 'power', 'special') then continue; end if;
      d := case s when 'A' then 'B' else 'A' end;
      ai := (st->s->>'active')::int; di := (st->d->>'active')::int;
      if (st->s->'hp'->>ai)::int = 0 then continue; end if;          -- al uitgeschakeld deze ronde
      crit := false; guarded := false;
      if kind = 'special' then
        dmg := (st->s->'sp'->>ai)::int;
      else
        base := greatest((st->s->'atk'->>ai)::int * .25,
                         (st->s->'atk'->>ai)::int * (.85 + random() * .3) - (st->d->'def'->>di)::int * .5);
        if kind = 'power' then base := base * 1.7; end if;
        if random() < .1 then base := base * 1.5; crit := true; end if;
        if st->'_act'->d->>'a' = 'guard' then base := base * .5; guarded := true; end if;
        dmg := greatest(1, round(base))::int;
      end if;
      st := jsonb_set(st, array[d, 'hp', di::text], to_jsonb(greatest(0, (st->d->'hp'->>di)::int - dmg)));
      ev := ev || jsonb_build_object('r', r, 't', 'atk', 's', s, 'k', kind, 'd', dmg, 'crit', crit, 'guarded', guarded,
                                     'ai', ai, 'di', di, 'hp', (st->d->'hp'->>di)::int);
      if (st->d->'hp'->>di)::int = 0 then
        ev := ev || jsonb_build_object('r', r, 't', 'ko', 's', d, 'i', di);
      end if;
    end loop;
    -- 4. Energie bijtanken
    for s in select unnest(array['A', 'B']) loop
      st := jsonb_set(st, array[s, 'energy'], to_jsonb(least(5,
        (st->s->>'energy')::int + case st->'_act'->s->>'a' when 'guard' then 2 when 'attack' then 1 when 'switch' then 1 else 0 end)));
    end loop;
    -- 5. Uitgeschakelde kaarten vervangen, of einde
    for s in select unnest(array['A', 'B']) loop
      ai := (st->s->>'active')::int;
      if (st->s->'hp'->>ai)::int = 0 then
        nxt := null;
        for i in 0..jsonb_array_length(st->s->'hp') - 1 loop
          if (st->s->'hp'->>i)::int > 0 then nxt := i; exit; end if;
        end loop;
        if nxt is null then
          w := case s when 'A' then 'B' else 'A' end;
        else
          st := jsonb_set(st, array[s, 'active'], to_jsonb(nxt));
          ev := ev || jsonb_build_object('r', r, 't', 'enter', 's', s, 'i', nxt);
        end if;
      end if;
    end loop;
    -- Veiligheidsnet: na 60 rondes wint wie procentueel het meeste HP over heeft
    if w is null and r >= 60 then
      w := case when (select sum((h.v)::float8 / m.v::float8) from jsonb_array_elements_text(st->'A'->'hp') with ordinality h(v, n)
                        join jsonb_array_elements_text(st->'A'->'max') with ordinality m(v, n) using (n))
                  >= (select sum((h.v)::float8 / m.v::float8) from jsonb_array_elements_text(st->'B'->'hp') with ordinality h(v, n)
                        join jsonb_array_elements_text(st->'B'->'max') with ordinality m(v, n) using (n))
               then 'A' else 'B' end;
    end if;
  end if;

  st := st - '_act';
  st := jsonb_set(st, '{moved}', '{"A": false, "B": false}');
  update public.tbattle_hidden set action = null, target = null where battle_id = p_id;

  if w is not null then
    ev := ev || jsonb_build_object('r', r, 't', 'end', 'w', w);
    -- Beloningen
    if b.mode = 'pve' then
      if w = 'A' and public._tb_rewarded_today(b.player_a, 'pve') < 5 then
        v_ca := case b.difficulty when 'easy' then 5 when 'hard' then 20 else 10 end;
      end if;
    else
      reward := 25;
      if w = 'A' then
        if public._tb_rewarded_today(b.player_a, 'pvp') < 3 then v_ca := reward; end if;
        if public._tb_rewarded_today(b.player_b, 'pvp') < 3 and not exists (select 1 from jsonb_array_elements(ev) e where e->>'t' = 'forfeit') then v_cb := 5; end if;
      else
        if public._tb_rewarded_today(b.player_b, 'pvp') < 3 then v_cb := reward; end if;
        if public._tb_rewarded_today(b.player_a, 'pvp') < 3 and not exists (select 1 from jsonb_array_elements(ev) e where e->>'t' = 'forfeit') then v_ca := 5; end if;
      end if;
      -- Opgeven vóór ronde 3 levert niemand iets op (voorkomt coins "farmen" met een vriend)
      if exists (select 1 from jsonb_array_elements(ev) e where e->>'t' = 'forfeit') and r < 3 then v_ca := 0; v_cb := 0; end if;
    end if;
    if v_ca > 0 then perform public._tb_pay(b.player_a, v_ca); end if;
    if v_cb > 0 and b.player_b is not null then perform public._tb_pay(b.player_b, v_cb); end if;
    st := jsonb_set(st, '{events}', ev);
    update public.tbattles set state = st, round = r, status = 'done', winner = w,
      forfeit = exists (select 1 from jsonb_array_elements(ev) e where e->>'t' = 'forfeit'),
      coins_a = v_ca, coins_b = v_cb, updated_at = now(), finished_at = now()
    where id = p_id;
  else
    st := jsonb_set(st, '{events}', ev);
    update public.tbattles set state = st, round = r, updated_at = now() where id = p_id;
  end if;
end $$;

revoke all on function public._tb_team_ok(uuid, int[]) from public, anon, authenticated;
revoke all on function public._tb_side(int[]) from public, anon, authenticated;
revoke all on function public._tb_pay(uuid, int) from public, anon, authenticated;
revoke all on function public._tb_rewarded_today(uuid, text) from public, anon, authenticated;
revoke all on function public._tb_ai(jsonb, text, text) from public, anon, authenticated;
revoke all on function public._tb_resolve(bigint) from public, anon, authenticated;

-- 3. Gevecht tegen de computer starten ------------------------------------------------
create or replace function public.tb_start_pve(p_cards int[], p_difficulty text) returns bigint
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  opp int[] := '{}'; c int; rar text; v_id bigint;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if p_difficulty not in ('easy', 'normal', 'hard') then raise exception 'Onbekende moeilijkheid.'; end if;
  if not public._tb_team_ok(me, p_cards) then raise exception 'Kies 3 verschillende kaarten die je bezit.'; end if;
  -- Een eventueel vorig, onafgewerkt oefengevecht vervalt
  update public.tbattles set status = 'cancelled', updated_at = now()
    where player_a = me and mode = 'pve' and status = 'active';
  -- Tegenstander: per kaart een kaart van dezelfde zeldzaamheid (makkelijk: lager, moeilijk: hoger)
  foreach c in array p_cards loop
    select rarity into rar from public.cards where id = c;
    if rar = 'cat' then rar := 'common'; end if;
    rar := case p_difficulty
      when 'easy' then case rar when 'legendary' then 'epic' else 'common' end
      when 'hard' then case rar when 'common' then 'epic' else 'legendary' end
      else rar end;
    opp := opp || (select id from public.cards where rarity = rar and not (id = any(opp)) order by random() limit 1);
  end loop;
  insert into public.tbattles (mode, difficulty, player_a, status, state)
  values ('pve', p_difficulty, me, 'active',
          jsonb_build_object('A', public._tb_side(p_cards), 'B', public._tb_side(opp), 'events', '[]'::jsonb,
                             'moved', '{"A": false, "B": false}'::jsonb))
  returning id into v_id;
  insert into public.tbattle_hidden (battle_id, side) values (v_id, 'A'), (v_id, 'B');
  return v_id;
end $$;

-- 4. Vriend uitdagen / reageren ----------------------------------------------------------
create or replace function public.tb_challenge(p_friend uuid, p_cards int[]) returns bigint
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); v_id bigint;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if not exists (select 1 from public.friendships where user_id = me and friend_id = p_friend) then
    raise exception 'Jullie zijn geen vrienden.';
  end if;
  if not public._tb_team_ok(me, p_cards) then raise exception 'Kies 3 verschillende kaarten die je bezit.'; end if;
  if exists (select 1 from public.tbattles where mode = 'pvp' and status in ('pending', 'active')
             and ((player_a = me and player_b = p_friend) or (player_a = p_friend and player_b = me))) then
    raise exception 'Er loopt al een battle tussen jullie.';
  end if;
  insert into public.tbattles (mode, player_a, player_b, status) values ('pvp', me, p_friend, 'pending') returning id into v_id;
  insert into public.tbattle_hidden (battle_id, side, cards) values (v_id, 'A', p_cards);
  return v_id;
end $$;

create or replace function public.tb_respond(p_id bigint, p_action text, p_cards int[] default null) returns void
language plpgsql volatile security definer set search_path = public as $$
declare me uuid := auth.uid(); b public.tbattles; a_cards int[];
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into b from public.tbattles where id = p_id for update;
  if not found or b.mode <> 'pvp' then raise exception 'Battle niet gevonden.'; end if;
  if b.status <> 'pending' then raise exception 'Deze uitdaging is al afgehandeld.'; end if;
  if p_action = 'cancel' then
    if me <> b.player_a then raise exception 'Enkel de uitdager kan annuleren.'; end if;
    update public.tbattles set status = 'cancelled', updated_at = now() where id = p_id;
    return;
  end if;
  if me <> b.player_b then raise exception 'Deze uitdaging is niet aan jou gericht.'; end if;
  if p_action = 'decline' then
    update public.tbattles set status = 'declined', updated_at = now() where id = p_id;
    return;
  end if;
  if p_action <> 'accept' then raise exception 'Onbekende actie.'; end if;
  if not public._tb_team_ok(me, p_cards) then raise exception 'Kies 3 verschillende kaarten die je bezit.'; end if;
  select cards into a_cards from public.tbattle_hidden where battle_id = p_id and side = 'A';
  if not public._tb_team_ok(b.player_a, a_cards) then
    update public.tbattles set status = 'cancelled', updated_at = now() where id = p_id;
    return;
  end if;
  insert into public.tbattle_hidden (battle_id, side) values (p_id, 'B') on conflict do nothing;
  update public.tbattles set status = 'active', updated_at = now(),
    state = jsonb_build_object('A', public._tb_side(a_cards), 'B', public._tb_side(p_cards), 'events', '[]'::jsonb,
                               'moved', '{"A": false, "B": false}'::jsonb)
  where id = p_id;
end $$;

-- 5. Een zet doen ------------------------------------------------------------------------
create or replace function public.tb_act(p_id bigint, p_action text, p_target int default null) returns jsonb
language plpgsql volatile security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  b public.tbattles; s text; o text; v_side jsonb; a int; ai jsonb;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into b from public.tbattles where id = p_id for update;
  if not found then raise exception 'Battle niet gevonden.'; end if;
  if b.status <> 'active' then raise exception 'Deze battle is niet (meer) bezig.'; end if;
  s := case when me = b.player_a then 'A' when me = b.player_b then 'B' end;
  if s is null then raise exception 'Dit is niet jouw battle.'; end if;
  o := case s when 'A' then 'B' else 'A' end;
  -- Opgeven mag altijd, ook als je deze ronde al gekozen hebt
  if p_action <> 'forfeit' and (b.state->'moved'->>s)::boolean then
    raise exception 'Je hebt deze ronde al gekozen. Wacht op je tegenstander.';
  end if;

  v_side := b.state->s; a := (v_side->>'active')::int;
  if p_action = 'power' and (v_side->>'energy')::int < 2 then raise exception 'Niet genoeg energie (2 nodig).'; end if;
  if p_action = 'special' then
    if (v_side->'sp'->>a)::int <= 0 then raise exception 'Deze kaart heeft geen special.'; end if;
    if (v_side->>'energy')::int < 4 then raise exception 'Niet genoeg energie (4 nodig).'; end if;
  end if;
  if p_action = 'switch' then
    if p_target is null or p_target < 0 or p_target >= jsonb_array_length(v_side->'hp') or p_target = a
       or (v_side->'hp'->>p_target)::int <= 0 then
      raise exception 'Kies een andere kaart die nog kan vechten.';
    end if;
  end if;
  if p_action not in ('attack', 'power', 'guard', 'special', 'switch', 'forfeit') then raise exception 'Onbekende zet.'; end if;

  update public.tbattle_hidden h set action = p_action, target = case when p_action = 'switch' then p_target end
    where h.battle_id = p_id and h.side = s;
  update public.tbattles set state = jsonb_set(state, array['moved', s], 'true'), updated_at = now() where id = p_id;

  if b.mode = 'pve' then
    ai := public._tb_ai(b.state, o, b.difficulty);
    update public.tbattle_hidden h set action = ai->>'a', target = (ai->>'t')::int where h.battle_id = p_id and h.side = o;
    perform public._tb_resolve(p_id);
  elsif p_action = 'forfeit' or (b.state->'moved'->>o)::boolean then
    -- Opgeven geldt meteen; anders pas afwikkelen als beide spelers gekozen hebben
    perform public._tb_resolve(p_id);
  end if;

  select * into b from public.tbattles where id = p_id;
  return to_jsonb(b);
end $$;

-- 6. Ranglijst (oude + nieuwe gevechten tegen vrienden) ------------------------------------
create or replace function public.tb_leaderboard()
returns table (user_id uuid, display_name text, avatar_url text, wins bigint, losses bigint)
language sql stable security definer set search_path = public as $$
  with people as (
    select auth.uid() as id
    union select f.friend_id from public.friendships f where f.user_id = auth.uid()
  ),
  results as (
    select winner_id as winner, challenger_id as p1, opponent_id as p2 from public.battles where status = 'done'
    union all
    select case winner when 'A' then player_a else player_b end, player_a, player_b
    from public.tbattles where mode = 'pvp' and status = 'done'
  )
  select p.id, pr.display_name, pr.avatar_url,
    (select count(*) from results r where r.winner = p.id),
    (select count(*) from results r where (r.p1 = p.id or r.p2 = p.id) and r.winner <> p.id)
  from people p join public.profiles pr on pr.id = p.id
  where auth.uid() is not null
  order by 4 desc, 5 asc, 2;
$$;

-- Hoeveel beloonde overwinningen heb ik vandaag nog?
create or replace function public.tb_rewards_today()
returns jsonb language sql stable security definer set search_path = public as $$
  select jsonb_build_object('pve', public._tb_rewarded_today(auth.uid(), 'pve'), 'pve_max', 5,
                            'pvp', public._tb_rewarded_today(auth.uid(), 'pvp'), 'pvp_max', 3);
$$;

grant execute on function public.tb_start_pve(int[], text) to authenticated;
grant execute on function public.tb_challenge(uuid, int[]) to authenticated;
grant execute on function public.tb_respond(bigint, text, int[]) to authenticated;
grant execute on function public.tb_act(bigint, text, int) to authenticated;
grant execute on function public.tb_leaderboard() to authenticated;
grant execute on function public.tb_rewards_today() to authenticated;
