-- Polygon Trading Cards — uitbreiding v6: gevechten tegen vrienden
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor,
-- ná schema-v5-friend-requests.sql. Veilig om opnieuw te draaien.
--
-- Het gevecht wordt volledig hier (server-side) berekend, zodat niemand de
-- uitkomst kan beïnvloeden. De website speelt enkel het opgeslagen verloop af.

-- 1. Tabel ----------------------------------------------------------------
create table if not exists public.battles (
  id bigserial primary key,
  challenger_id uuid not null references auth.users(id) on delete cascade,
  opponent_id uuid not null references auth.users(id) on delete cascade,
  challenger_cards int[] not null,
  opponent_cards int[],
  status text not null default 'pending' check (status in ('pending','done','declined','cancelled')),
  winner_id uuid,
  events jsonb,
  coins_awarded int not null default 0,
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  check (challenger_id <> opponent_id)
);
create index if not exists battles_challenger_idx on public.battles (challenger_id, status);
create index if not exists battles_opponent_idx on public.battles (opponent_id, status);
create index if not exists battles_winner_idx on public.battles (winner_id);

alter table public.battles enable row level security;
drop policy if exists "eigen gevechten lezen" on public.battles;
create policy "eigen gevechten lezen" on public.battles
  for select to authenticated using (auth.uid() = challenger_id or auth.uid() = opponent_id);
-- Bewust GEEN insert/update/delete policy: alles verloopt via de functies hieronder.

-- 2. Hulpfuncties -----------------------------------------------------------
-- Heeft deze gebruiker precies 3 verschillende kaarten die hij allemaal bezit?
create or replace function public._battle_team_ok(p_user uuid, p_cards int[])
returns boolean
language sql stable security definer set search_path = public
as $$
  select coalesce(array_length(p_cards, 1), 0) = 3
     and (select count(distinct x) from unnest(p_cards) x) = 3
     and not exists (
       select 1 from unnest(p_cards) x
       where not exists (select 1 from public.user_cards uc where uc.user_id = p_user and uc.card_id = x)
     );
$$;

create or replace function public._battle_state(p_ia int, p_ahp int[], p_ib int, p_bhp int[])
returns jsonb
language sql immutable
as $$
  select jsonb_build_object(
    'A', jsonb_build_object('active', p_ia - 1, 'hps', to_jsonb(p_ahp)),
    'B', jsonb_build_object('active', p_ib - 1, 'hps', to_jsonb(p_bhp))
  );
$$;

-- Het gevecht zelf. Zelfde regels als de oefenmodus op de website:
-- schade = ATK × (0,85–1,15) − DEF/2, minimaal ATK/4; 10% kans op voltreffer (×1,5);
-- een kaart met special gebruikt die één keer zodra ze op de helft van haar HP of lager staat.
create or replace function public._battle_run(p_a int[], p_b int[], out winner text, out events jsonb)
language plpgsql volatile security definer set search_path = public
as $$
declare
  a_max int[]; a_atk int[]; a_def int[]; a_sp int[]; a_hp int[]; a_used boolean[];
  b_max int[]; b_atk int[]; b_def int[]; b_sp int[]; b_hp int[]; b_used boolean[];
  ia int := 1; ib int := 1;
  turn text; dmg int; kind text; i int;
begin
  select array_agg(coalesce(c.hp, 50) order by u.ord), array_agg(coalesce(c.attack, 10) order by u.ord),
         array_agg(coalesce(c.defense, 0) order by u.ord), array_agg(coalesce(c.special_power, 0) order by u.ord)
    into a_max, a_atk, a_def, a_sp
    from unnest(p_a) with ordinality u(id, ord) join public.cards c on c.id = u.id;
  select array_agg(coalesce(c.hp, 50) order by u.ord), array_agg(coalesce(c.attack, 10) order by u.ord),
         array_agg(coalesce(c.defense, 0) order by u.ord), array_agg(coalesce(c.special_power, 0) order by u.ord)
    into b_max, b_atk, b_def, b_sp
    from unnest(p_b) with ordinality u(id, ord) join public.cards c on c.id = u.id;
  a_hp := a_max; b_hp := b_max;
  a_used := array_fill(false, array[array_length(p_a, 1)]);
  b_used := array_fill(false, array[array_length(p_b, 1)]);

  turn := case when random() < 0.5 then 'A' else 'B' end;
  events := jsonb_build_array(jsonb_build_object('t', 'start', 'first', turn, 'st', public._battle_state(ia, a_hp, ib, b_hp)));

  for i in 1..300 loop
    if turn = 'A' then
      if a_sp[ia] > 0 and not a_used[ia] and a_hp[ia] * 2 <= a_max[ia] then
        a_used[ia] := true; kind := 'special'; dmg := a_sp[ia];
      else
        kind := 'hit';
        dmg := greatest(round(a_atk[ia] * 0.25), round(a_atk[ia] * (0.85 + random() * 0.3) - b_def[ib] * 0.5))::int;
        if random() < 0.1 then dmg := round(dmg * 1.5)::int; kind := 'crit'; end if;
      end if;
      b_hp[ib] := greatest(0, b_hp[ib] - dmg);
      events := events || jsonb_build_object('t', 'atk', 's', 'A', 'k', kind, 'd', dmg, 'ai', ia - 1, 'di', ib - 1,
                                             'st', public._battle_state(ia, a_hp, ib, b_hp));
      if b_hp[ib] = 0 then
        events := events || jsonb_build_object('t', 'ko', 's', 'B', 'i', ib - 1, 'st', public._battle_state(ia, a_hp, ib, b_hp));
        if ib = array_length(p_b, 1) then
          winner := 'A';
          events := events || jsonb_build_object('t', 'end', 'w', 'A', 'st', public._battle_state(ia, a_hp, ib, b_hp));
          return;
        end if;
        ib := ib + 1;
        events := events || jsonb_build_object('t', 'enter', 's', 'B', 'i', ib - 1, 'st', public._battle_state(ia, a_hp, ib, b_hp));
      end if;
      turn := 'B';
    else
      if b_sp[ib] > 0 and not b_used[ib] and b_hp[ib] * 2 <= b_max[ib] then
        b_used[ib] := true; kind := 'special'; dmg := b_sp[ib];
      else
        kind := 'hit';
        dmg := greatest(round(b_atk[ib] * 0.25), round(b_atk[ib] * (0.85 + random() * 0.3) - a_def[ia] * 0.5))::int;
        if random() < 0.1 then dmg := round(dmg * 1.5)::int; kind := 'crit'; end if;
      end if;
      a_hp[ia] := greatest(0, a_hp[ia] - dmg);
      events := events || jsonb_build_object('t', 'atk', 's', 'B', 'k', kind, 'd', dmg, 'ai', ib - 1, 'di', ia - 1,
                                             'st', public._battle_state(ia, a_hp, ib, b_hp));
      if a_hp[ia] = 0 then
        events := events || jsonb_build_object('t', 'ko', 's', 'A', 'i', ia - 1, 'st', public._battle_state(ia, a_hp, ib, b_hp));
        if ia = array_length(p_a, 1) then
          winner := 'B';
          events := events || jsonb_build_object('t', 'end', 'w', 'B', 'st', public._battle_state(ia, a_hp, ib, b_hp));
          return;
        end if;
        ia := ia + 1;
        events := events || jsonb_build_object('t', 'enter', 's', 'A', 'i', ia - 1, 'st', public._battle_state(ia, a_hp, ib, b_hp));
      end if;
      turn := 'A';
    end if;
  end loop;

  -- Veiligheidsnet: wie procentueel het meeste HP over heeft, wint
  winner := case
    when (select sum(h::numeric / m) from unnest(a_hp, a_max) t(h, m)) >= (select sum(h::numeric / m) from unnest(b_hp, b_max) t(h, m))
    then 'A' else 'B' end;
  events := events || jsonb_build_object('t', 'end', 'w', winner, 'st', public._battle_state(ia, a_hp, ib, b_hp));
end;
$$;

-- Niemand mag de hulpfuncties rechtstreeks aanroepen
revoke all on function public._battle_team_ok(uuid, int[]) from public, anon, authenticated;
revoke all on function public._battle_run(int[], int[]) from public, anon, authenticated;

-- 3. create_battle: vriend uitdagen met een team van 3 kaarten ---------------
create or replace function public.create_battle(p_friend_id uuid, p_cards int[])
returns public.battles
language plpgsql security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  v_row public.battles;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  if not exists (select 1 from public.friendships where user_id = me and friend_id = p_friend_id) then
    raise exception 'Jullie zijn geen vrienden.';
  end if;
  if not public._battle_team_ok(me, p_cards) then
    raise exception 'Kies 3 verschillende kaarten die je bezit.';
  end if;
  if exists (
    select 1 from public.battles
    where status = 'pending'
      and ((challenger_id = me and opponent_id = p_friend_id) or (challenger_id = p_friend_id and opponent_id = me))
  ) then
    raise exception 'Er staat al een uitdaging open tussen jullie.';
  end if;

  insert into public.battles (challenger_id, opponent_id, challenger_cards)
  values (me, p_friend_id, p_cards)
  returning * into v_row;
  return v_row;
end;
$$;

-- 4. respond_battle: accepteren (met eigen team), weigeren of annuleren -------
create or replace function public.respond_battle(p_battle_id bigint, p_action text, p_cards int[] default null)
returns public.battles
language plpgsql security definer set search_path = public
as $$
declare
  me uuid := auth.uid();
  b public.battles;
  v_run record;
  v_winner uuid;
  v_wins_today int;
  v_coins int := 0;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;
  select * into b from public.battles where id = p_battle_id for update;
  if not found then raise exception 'Uitdaging niet gevonden.'; end if;
  if b.status <> 'pending' then raise exception 'Deze uitdaging is al afgehandeld.'; end if;

  if p_action = 'cancel' then
    if me <> b.challenger_id then raise exception 'Enkel de uitdager kan annuleren.'; end if;
    update public.battles set status = 'cancelled', resolved_at = now() where id = b.id returning * into b;
    return b;
  end if;

  if me <> b.opponent_id then raise exception 'Deze uitdaging is niet aan jou gericht.'; end if;

  if p_action = 'decline' then
    update public.battles set status = 'declined', resolved_at = now() where id = b.id returning * into b;
    return b;
  end if;

  if p_action <> 'accept' then raise exception 'Onbekende actie.'; end if;
  if not public._battle_team_ok(me, p_cards) then
    raise exception 'Kies 3 verschillende kaarten die je bezit.';
  end if;
  if not public._battle_team_ok(b.challenger_id, b.challenger_cards) then
    -- Geen exception: die zou de annulering terugdraaien. De website toont een melding.
    update public.battles set status = 'cancelled', resolved_at = now() where id = b.id returning * into b;
    return b;
  end if;

  select * into v_run from public._battle_run(b.challenger_cards, p_cards);
  v_winner := case when v_run.winner = 'A' then b.challenger_id else b.opponent_id end;

  -- Beloning: 10 polycoins voor de winnaar, maximaal 3 beloonde overwinningen per dag
  select count(*) into v_wins_today from public.battles
    where winner_id = v_winner and coins_awarded > 0
      and (resolved_at at time zone 'Europe/Brussels')::date = (now() at time zone 'Europe/Brussels')::date;
  if v_wins_today < 3 then
    v_coins := 10;
    insert into public.user_wallet (user_id, polycoins) values (v_winner, v_coins)
      on conflict (user_id) do update set polycoins = public.user_wallet.polycoins + excluded.polycoins;
  end if;

  update public.battles set
    opponent_cards = p_cards, status = 'done', winner_id = v_winner,
    events = v_run.events, coins_awarded = v_coins, resolved_at = now()
  where id = b.id
  returning * into b;
  return b;
end;
$$;

-- 5. Ranglijst: jij en je vrienden --------------------------------------------
create or replace function public.battle_leaderboard()
returns table (user_id uuid, display_name text, avatar_url text, wins bigint, losses bigint)
language sql stable security definer set search_path = public
as $$
  with people as (
    select auth.uid() as id
    union
    select f.friend_id from public.friendships f where f.user_id = auth.uid()
  )
  select p.id, pr.display_name, pr.avatar_url,
    (select count(*) from public.battles b where b.status = 'done' and b.winner_id = p.id),
    (select count(*) from public.battles b where b.status = 'done'
       and (b.challenger_id = p.id or b.opponent_id = p.id) and b.winner_id <> p.id)
  from people p
  join public.profiles pr on pr.id = p.id
  where auth.uid() is not null
  order by 4 desc, 5 asc, 2;
$$;

grant execute on function public.create_battle(uuid, int[]) to authenticated;
grant execute on function public.respond_battle(bigint, text, int[]) to authenticated;
grant execute on function public.battle_leaderboard() to authenticated;
