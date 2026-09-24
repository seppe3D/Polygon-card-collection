-- Polygon Trading Cards — uitbreiding v8: eigen Wordle, 2 rondes per dag
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor. Veilig om opnieuw te draaien.
--
-- - Elke dag 2 rondes: ochtend (vanaf 08:00) en middag (vanaf 13:00), Belgische tijd.
-- - Per ronde krijgt iedereen hetzelfde woord, willekeurig gekozen uit een geheime lijst
--   (dus niet de officiële NYT-Wordle).
-- - Het woord verlaat de database nooit tijdens het spel: elke gok wordt hier nagekeken,
--   de website krijgt enkel de kleurtjes terug. Na afloop wordt meteen een kaart getrokken.

-- 1. Geheime woordenlijst en gekozen woorden per ronde (NIET leesbaar voor gebruikers)
create table if not exists public.wordle_answers (word text primary key check (word ~ '^[A-Z]{5}$'));
create table if not exists public.wordle_rounds (
  round_date date not null,
  slot smallint not null check (slot in (1, 2)),
  word text not null,
  created_at timestamptz not null default now(),
  primary key (round_date, slot)
);
alter table public.wordle_answers enable row level security;
alter table public.wordle_rounds enable row level security;
-- Bewust GEEN policies: enkel de functies hieronder (security definer) mogen erin kijken.

-- 2. Spelletjes per gebruiker per ronde
create table if not exists public.wordle_games (
  user_id uuid not null references auth.users(id) on delete cascade,
  round_date date not null,
  slot smallint not null check (slot in (1, 2)),
  guesses text[] not null default '{}',
  status text not null default 'playing' check (status in ('playing', 'won', 'lost')),
  attempts int,
  card_id int references public.cards(id),
  is_duplicate boolean,
  coins_earned int not null default 0,
  created_at timestamptz not null default now(),
  finished_at timestamptz,
  primary key (user_id, round_date, slot)
);
alter table public.wordle_games enable row level security;
drop policy if exists "eigen wordles lezen" on public.wordle_games;
create policy "eigen wordles lezen" on public.wordle_games
  for select to authenticated using (auth.uid() = user_id);
-- Vrienden zien je gokken bewust NIET (die verklappen het woord); statistieken via friend_wordle_stats().

-- 3. Hulpfuncties -------------------------------------------------------------
create or replace function public._wordle_local() returns timestamp
language sql stable as $$ select now() at time zone 'Europe/Brussels' $$;

create or replace function public._wordle_opens(p_slot int) returns time
language sql immutable as $$ select case p_slot when 1 then time '08:00' else time '13:00' end $$;

-- Het woord van een ronde; wordt bij de eerste speler willekeurig gekozen (voor iedereen hetzelfde)
create or replace function public._wordle_word(p_date date, p_slot int) returns text
language plpgsql volatile security definer set search_path = public as $$
declare v text;
begin
  select word into v from public.wordle_rounds where round_date = p_date and slot = p_slot;
  if found then return v; end if;
  insert into public.wordle_rounds (round_date, slot, word)
  select p_date, p_slot, a.word from public.wordle_answers a
  where not exists (select 1 from public.wordle_rounds r where r.word = a.word)  -- geen herhalingen
  order by random() limit 1
  on conflict do nothing;
  select word into v from public.wordle_rounds where round_date = p_date and slot = p_slot;
  if v is null then
    -- Alle woorden al eens gebruikt: dan mag er herhaald worden
    insert into public.wordle_rounds (round_date, slot, word)
    select p_date, p_slot, word from public.wordle_answers order by random() limit 1
    on conflict do nothing;
    select word into v from public.wordle_rounds where round_date = p_date and slot = p_slot;
  end if;
  return v;
end $$;

-- Kleurtjes zoals in Wordle: g = juist, y = zit erin maar elders, x = zit er niet in (met correcte dubbele letters)
create or replace function public._wordle_score(p_guess text, p_answer text) returns text
language plpgsql immutable as $$
declare
  res text[] := array['x','x','x','x','x'];
  left_ text[] := '{}';
  i int; j int;
begin
  for i in 1..5 loop
    if substr(p_guess, i, 1) = substr(p_answer, i, 1) then res[i] := 'g';
    else left_ := left_ || substr(p_answer, i, 1); end if;
  end loop;
  for i in 1..5 loop
    if res[i] <> 'g' then
      j := array_position(left_, substr(p_guess, i, 1));
      if j is not null then res[i] := 'y'; left_ := left_[1:j-1] || left_[j+1:]; end if;
    end if;
  end loop;
  return array_to_string(res, '');
end $$;

-- Kaart trekken na een ronde (zelfde kansen en polycoins als de vroegere Edge Function)
drop function if exists public._wordle_draw(uuid, int);
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
    leg := (array[80, 30, 10, 3, 1, 0.5])[p_attempts];
    ep  := (array[20, 50, 35, 22, 11, 4.5])[p_attempts];
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

revoke all on function public._wordle_word(date, int) from public, anon, authenticated;
revoke all on function public._wordle_draw(uuid, int) from public, anon, authenticated;

-- 4. wordle_state: de 2 rondes van vandaag voor de ingelogde gebruiker ------------
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
      'card_id', g.card_id,
      'answer', case when g.status = 'lost' then public._wordle_word(d, s) end
    );
  end loop;
  return jsonb_build_object('date', d, 'slots', out_);
end $$;

-- 5. wordle_guess: één gok indienen ------------------------------------------------
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

  if score = 'ggggg' or n >= 6 then
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
  return jsonb_build_object('result', score, 'status', 'playing', 'guess', guess);
end $$;

-- 6. Statistieken van een vriend (enkel resultaten, nooit de gokken) -----------------
create or replace function public.friend_wordle_stats(p_friend uuid)
returns table (play_date date, solved boolean, attempts int)
language sql stable security definer set search_path = public as $$
  select g.round_date, g.status = 'won', g.attempts
  from public.wordle_games g
  where g.user_id = p_friend and g.status <> 'playing'
    and exists (select 1 from public.friendships f where f.user_id = auth.uid() and f.friend_id = p_friend)
  order by g.round_date;
$$;

grant execute on function public.wordle_state() to authenticated;
grant execute on function public.wordle_guess(int, text) to authenticated;
grant execute on function public.friend_wordle_stats(uuid) to authenticated;

-- 7. De geheime lijst met oplossingen (2307 woorden) ------------------------------
insert into public.wordle_answers (word) values
  ('ABACK'), ('ABASE'), ('ABATE'), ('ABBEY'), ('ABBOT'), ('ABHOR'), ('ABIDE'), ('ABLED'), ('ABODE'), ('ABORT'), ('ABOUT'), ('ABOVE'),
  ('ABUSE'), ('ABYSS'), ('ACORN'), ('ACRID'), ('ACTOR'), ('ACUTE'), ('ADAGE'), ('ADAPT'), ('ADEPT'), ('ADMIN'), ('ADMIT'), ('ADOBE'),
  ('ADOPT'), ('ADORE'), ('ADORN'), ('ADULT'), ('AFFIX'), ('AFIRE'), ('AFOOT'), ('AFOUL'), ('AFTER'), ('AGAIN'), ('AGAPE'), ('AGATE'),
  ('AGENT'), ('AGILE'), ('AGING'), ('AGLOW'), ('AGONY'), ('AGORA'), ('AGREE'), ('AHEAD'), ('AIDER'), ('AISLE'), ('ALARM'), ('ALBUM'),
  ('ALERT'), ('ALGAE'), ('ALIBI'), ('ALIEN'), ('ALIGN'), ('ALIKE'), ('ALIVE'), ('ALLAY'), ('ALLEY'), ('ALLOT'), ('ALLOW'), ('ALLOY'),
  ('ALOFT'), ('ALONE'), ('ALONG'), ('ALOOF'), ('ALOUD'), ('ALPHA'), ('ALTAR'), ('ALTER'), ('AMASS'), ('AMAZE'), ('AMBER'), ('AMBLE'),
  ('AMEND'), ('AMISS'), ('AMITY'), ('AMONG'), ('AMPLE'), ('AMPLY'), ('AMUSE'), ('ANGEL'), ('ANGER'), ('ANGLE'), ('ANGRY'), ('ANGST'),
  ('ANIME'), ('ANKLE'), ('ANNEX'), ('ANNOY'), ('ANNUL'), ('ANODE'), ('ANTIC'), ('ANVIL'), ('AORTA'), ('APART'), ('APHID'), ('APING'),
  ('APNEA'), ('APPLE'), ('APPLY'), ('APRON'), ('APTLY'), ('ARBOR'), ('ARDOR'), ('ARENA'), ('ARGUE'), ('ARISE'), ('ARMOR'), ('AROMA'),
  ('AROSE'), ('ARRAY'), ('ARROW'), ('ARSON'), ('ARTSY'), ('ASCOT'), ('ASHEN'), ('ASIDE'), ('ASKEW'), ('ASSAY'), ('ASSET'), ('ATOLL'),
  ('ATONE'), ('ATTIC'), ('AUDIO'), ('AUDIT'), ('AUGUR'), ('AUNTY'), ('AVAIL'), ('AVERT'), ('AVIAN'), ('AVOID'), ('AWAIT'), ('AWAKE'),
  ('AWARD'), ('AWARE'), ('AWASH'), ('AWFUL'), ('AWOKE'), ('AXIAL'), ('AXIOM'), ('AXION'), ('AZURE'), ('BACON'), ('BADGE'), ('BADLY'),
  ('BAGEL'), ('BAGGY'), ('BAKER'), ('BALER'), ('BALMY'), ('BANAL'), ('BANJO'), ('BARGE'), ('BARON'), ('BASAL'), ('BASIC'), ('BASIL'),
  ('BASIN'), ('BASIS'), ('BASTE'), ('BATCH'), ('BATHE'), ('BATON'), ('BATTY'), ('BAWDY'), ('BAYOU'), ('BEACH'), ('BEADY'), ('BEARD'),
  ('BEAST'), ('BEECH'), ('BEEFY'), ('BEFIT'), ('BEGAN'), ('BEGAT'), ('BEGET'), ('BEGIN'), ('BEGUN'), ('BEING'), ('BELCH'), ('BELIE'),
  ('BELLE'), ('BELLY'), ('BELOW'), ('BENCH'), ('BERET'), ('BERRY'), ('BERTH'), ('BESET'), ('BETEL'), ('BEVEL'), ('BEZEL'), ('BIBLE'),
  ('BICEP'), ('BIDDY'), ('BILGE'), ('BILLY'), ('BINGE'), ('BINGO'), ('BIOME'), ('BIRCH'), ('BIRTH'), ('BISON'), ('BITTY'), ('BLACK'),
  ('BLADE'), ('BLAME'), ('BLAND'), ('BLANK'), ('BLARE'), ('BLAST'), ('BLAZE'), ('BLEAK'), ('BLEAT'), ('BLEED'), ('BLEEP'), ('BLEND'),
  ('BLESS'), ('BLIMP'), ('BLIND'), ('BLINK'), ('BLISS'), ('BLITZ'), ('BLOAT'), ('BLOCK'), ('BLOKE'), ('BLOND'), ('BLOOD'), ('BLOOM'),
  ('BLOWN'), ('BLUER'), ('BLUFF'), ('BLUNT'), ('BLURB'), ('BLURT'), ('BLUSH'), ('BOARD'), ('BOAST'), ('BOBBY'), ('BONEY'), ('BONGO'),
  ('BONUS'), ('BOOBY'), ('BOOST'), ('BOOTH'), ('BOOTY'), ('BOOZE'), ('BOOZY'), ('BORAX'), ('BORNE'), ('BOSOM'), ('BOSSY'), ('BOTCH'),
  ('BOUGH'), ('BOULE'), ('BOUND'), ('BOWEL'), ('BOXER'), ('BRACE'), ('BRAID'), ('BRAIN'), ('BRAKE'), ('BRAND'), ('BRASH'), ('BRASS'),
  ('BRAVE'), ('BRAVO'), ('BRAWL'), ('BRAWN'), ('BREAD'), ('BREAK'), ('BREED'), ('BRIAR'), ('BRIBE'), ('BRICK'), ('BRIDE'), ('BRIEF'),
  ('BRINE'), ('BRING'), ('BRINK'), ('BRINY'), ('BRISK'), ('BROAD'), ('BROIL'), ('BROKE'), ('BROOD'), ('BROOK'), ('BROOM'), ('BROTH'),
  ('BROWN'), ('BRUNT'), ('BRUSH'), ('BRUTE'), ('BUDDY'), ('BUDGE'), ('BUGGY'), ('BUGLE'), ('BUILD'), ('BUILT'), ('BULGE'), ('BULKY'),
  ('BULLY'), ('BUNCH'), ('BUNNY'), ('BURLY'), ('BURNT'), ('BURST'), ('BUSED'), ('BUSHY'), ('BUTCH'), ('BUTTE'), ('BUXOM'), ('BUYER'),
  ('BYLAW'), ('CABAL'), ('CABBY'), ('CABIN'), ('CABLE'), ('CACAO'), ('CACHE'), ('CACTI'), ('CADDY'), ('CADET'), ('CAGEY'), ('CAIRN'),
  ('CAMEL'), ('CAMEO'), ('CANAL'), ('CANDY'), ('CANNY'), ('CANOE'), ('CANON'), ('CAPER'), ('CAPUT'), ('CARAT'), ('CARGO'), ('CAROL'),
  ('CARRY'), ('CARVE'), ('CASTE'), ('CATCH'), ('CATER'), ('CATTY'), ('CAULK'), ('CAUSE'), ('CAVIL'), ('CEASE'), ('CEDAR'), ('CELLO'),
  ('CHAFE'), ('CHAFF'), ('CHAIN'), ('CHAIR'), ('CHALK'), ('CHAMP'), ('CHANT'), ('CHAOS'), ('CHARD'), ('CHARM'), ('CHART'), ('CHASE'),
  ('CHASM'), ('CHEAP'), ('CHEAT'), ('CHECK'), ('CHEEK'), ('CHEER'), ('CHESS'), ('CHEST'), ('CHICK'), ('CHIDE'), ('CHIEF'), ('CHILD'),
  ('CHILI'), ('CHILL'), ('CHIME'), ('CHINA'), ('CHIRP'), ('CHOCK'), ('CHOIR'), ('CHOKE'), ('CHORD'), ('CHORE'), ('CHOSE'), ('CHUCK'),
  ('CHUMP'), ('CHUNK'), ('CHURN'), ('CHUTE'), ('CIDER'), ('CIGAR'), ('CINCH'), ('CIRCA'), ('CIVIC'), ('CIVIL'), ('CLACK'), ('CLAIM'),
  ('CLAMP'), ('CLANG'), ('CLANK'), ('CLASH'), ('CLASP'), ('CLASS'), ('CLEAN'), ('CLEAR'), ('CLEAT'), ('CLEFT'), ('CLERK'), ('CLICK'),
  ('CLIFF'), ('CLIMB'), ('CLING'), ('CLINK'), ('CLOAK'), ('CLOCK'), ('CLONE'), ('CLOSE'), ('CLOTH'), ('CLOUD'), ('CLOUT'), ('CLOVE'),
  ('CLOWN'), ('CLUCK'), ('CLUED'), ('CLUMP'), ('CLUNG'), ('COACH'), ('COAST'), ('COBRA'), ('COCOA'), ('COLON'), ('COLOR'), ('COMET'),
  ('COMFY'), ('COMIC'), ('COMMA'), ('CONCH'), ('CONDO'), ('CONIC'), ('COPSE'), ('CORAL'), ('CORER'), ('CORNY'), ('COUCH'), ('COUGH'),
  ('COULD'), ('COUNT'), ('COUPE'), ('COURT'), ('COVEN'), ('COVER'), ('COVET'), ('COVEY'), ('COWER'), ('COYLY'), ('CRACK'), ('CRAFT'),
  ('CRAMP'), ('CRANE'), ('CRANK'), ('CRASH'), ('CRASS'), ('CRATE'), ('CRAVE'), ('CRAWL'), ('CRAZE'), ('CRAZY'), ('CREAK'), ('CREAM'),
  ('CREDO'), ('CREED'), ('CREEK'), ('CREEP'), ('CREME'), ('CREPE'), ('CREPT'), ('CRESS'), ('CREST'), ('CRICK'), ('CRIED'), ('CRIER'),
  ('CRIME'), ('CRIMP'), ('CRISP'), ('CROAK'), ('CROCK'), ('CRONE'), ('CRONY'), ('CROOK'), ('CROSS'), ('CROUP'), ('CROWD'), ('CROWN'),
  ('CRUDE'), ('CRUEL'), ('CRUMB'), ('CRUMP'), ('CRUSH'), ('CRUST'), ('CRYPT'), ('CUBIC'), ('CUMIN'), ('CURIO'), ('CURLY'), ('CURRY'),
  ('CURSE'), ('CURVE'), ('CURVY'), ('CUTIE'), ('CYBER'), ('CYCLE'), ('CYNIC'), ('DADDY'), ('DAILY'), ('DAIRY'), ('DAISY'), ('DALLY'),
  ('DANCE'), ('DANDY'), ('DATUM'), ('DAUNT'), ('DEALT'), ('DEATH'), ('DEBAR'), ('DEBIT'), ('DEBUG'), ('DEBUT'), ('DECAL'), ('DECAY'),
  ('DECOR'), ('DECOY'), ('DECRY'), ('DEFER'), ('DEIGN'), ('DEITY'), ('DELAY'), ('DELTA'), ('DELVE'), ('DEMON'), ('DEMUR'), ('DENIM'),
  ('DENSE'), ('DEPOT'), ('DEPTH'), ('DERBY'), ('DETER'), ('DETOX'), ('DEUCE'), ('DEVIL'), ('DIARY'), ('DICEY'), ('DIGIT'), ('DILLY'),
  ('DIMLY'), ('DINER'), ('DINGO'), ('DINGY'), ('DIODE'), ('DIRGE'), ('DIRTY'), ('DISCO'), ('DITCH'), ('DITTO'), ('DITTY'), ('DIVER'),
  ('DIZZY'), ('DODGE'), ('DODGY'), ('DOGMA'), ('DOING'), ('DOLLY'), ('DONOR'), ('DONUT'), ('DOPEY'), ('DOUBT'), ('DOUGH'), ('DOWDY'),
  ('DOWEL'), ('DOWNY'), ('DOWRY'), ('DOZEN'), ('DRAFT'), ('DRAIN'), ('DRAKE'), ('DRAMA'), ('DRANK'), ('DRAPE'), ('DRAWL'), ('DRAWN'),
  ('DREAD'), ('DREAM'), ('DRESS'), ('DRIED'), ('DRIER'), ('DRIFT'), ('DRILL'), ('DRINK'), ('DRIVE'), ('DROIT'), ('DROLL'), ('DRONE'),
  ('DROOL'), ('DROOP'), ('DROSS'), ('DROVE'), ('DROWN'), ('DRUID'), ('DRUNK'), ('DRYER'), ('DRYLY'), ('DUCHY'), ('DULLY'), ('DUMMY'),
  ('DUMPY'), ('DUNCE'), ('DUSKY'), ('DUSTY'), ('DUTCH'), ('DUVET'), ('DWARF'), ('DWELL'), ('DWELT'), ('DYING'), ('EAGER'), ('EAGLE'),
  ('EARLY'), ('EARTH'), ('EASEL'), ('EATEN'), ('EATER'), ('EBONY'), ('ECLAT'), ('EDICT'), ('EDIFY'), ('EERIE'), ('EGRET'), ('EIGHT'),
  ('EJECT'), ('EKING'), ('ELATE'), ('ELBOW'), ('ELDER'), ('ELECT'), ('ELEGY'), ('ELFIN'), ('ELIDE'), ('ELITE'), ('ELOPE'), ('ELUDE'),
  ('EMAIL'), ('EMBED'), ('EMBER'), ('EMCEE'), ('EMPTY'), ('ENACT'), ('ENDOW'), ('ENEMA'), ('ENEMY'), ('ENJOY'), ('ENNUI'), ('ENSUE'),
  ('ENTER'), ('ENTRY'), ('ENVOY'), ('EPOCH'), ('EPOXY'), ('EQUAL'), ('EQUIP'), ('ERASE'), ('ERECT'), ('ERODE'), ('ERROR'), ('ERUPT'),
  ('ESSAY'), ('ESTER'), ('ETHER'), ('ETHIC'), ('ETHOS'), ('ETUDE'), ('EVADE'), ('EVENT'), ('EVERY'), ('EVICT'), ('EVOKE'), ('EXACT'),
  ('EXALT'), ('EXCEL'), ('EXERT'), ('EXILE'), ('EXIST'), ('EXPEL'), ('EXTOL'), ('EXTRA'), ('EXULT'), ('EYING'), ('FABLE'), ('FACET'),
  ('FAINT'), ('FAIRY'), ('FAITH'), ('FALSE'), ('FANCY'), ('FANNY'), ('FARCE'), ('FATAL'), ('FATTY'), ('FAULT'), ('FAUNA'), ('FAVOR'),
  ('FEAST'), ('FEIGN'), ('FELLA'), ('FELON'), ('FEMME'), ('FEMUR'), ('FENCE'), ('FERAL'), ('FERRY'), ('FETAL'), ('FETCH'), ('FETID'),
  ('FETUS'), ('FEVER'), ('FEWER'), ('FIBER'), ('FIBRE'), ('FICUS'), ('FIELD'), ('FIEND'), ('FIERY'), ('FIFTH'), ('FIFTY'), ('FIGHT'),
  ('FILER'), ('FILET'), ('FILLY'), ('FILMY'), ('FILTH'), ('FINAL'), ('FINCH'), ('FINER'), ('FIRST'), ('FISHY'), ('FIXER'), ('FIZZY'),
  ('FJORD'), ('FLACK'), ('FLAIL'), ('FLAIR'), ('FLAKE'), ('FLAKY'), ('FLAME'), ('FLANK'), ('FLARE'), ('FLASH'), ('FLASK'), ('FLECK'),
  ('FLEET'), ('FLESH'), ('FLICK'), ('FLIER'), ('FLING'), ('FLINT'), ('FLIRT'), ('FLOAT'), ('FLOCK'), ('FLOOD'), ('FLOOR'), ('FLORA'),
  ('FLOSS'), ('FLOUR'), ('FLOUT'), ('FLOWN'), ('FLUFF'), ('FLUID'), ('FLUKE'), ('FLUME'), ('FLUNG'), ('FLUNK'), ('FLUSH'), ('FLUTE'),
  ('FLYER'), ('FOAMY'), ('FOCAL'), ('FOCUS'), ('FOGGY'), ('FOIST'), ('FOLIO'), ('FOLLY'), ('FORAY'), ('FORCE'), ('FORGE'), ('FORGO'),
  ('FORTE'), ('FORTH'), ('FORTY'), ('FORUM'), ('FOUND'), ('FOYER'), ('FRAIL'), ('FRAME'), ('FRANK'), ('FRAUD'), ('FREAK'), ('FREED'),
  ('FREER'), ('FRESH'), ('FRIAR'), ('FRIED'), ('FRILL'), ('FRISK'), ('FRITZ'), ('FROCK'), ('FROND'), ('FRONT'), ('FROST'), ('FROTH'),
  ('FROWN'), ('FROZE'), ('FRUIT'), ('FUDGE'), ('FUGUE'), ('FULLY'), ('FUNGI'), ('FUNKY'), ('FUNNY'), ('FUROR'), ('FURRY'), ('FUSSY'),
  ('FUZZY'), ('GAFFE'), ('GAILY'), ('GAMER'), ('GAMMA'), ('GAMUT'), ('GASSY'), ('GAUDY'), ('GAUGE'), ('GAUNT'), ('GAUZE'), ('GAVEL'),
  ('GAWKY'), ('GAYER'), ('GAYLY'), ('GAZER'), ('GECKO'), ('GEEKY'), ('GEESE'), ('GENIE'), ('GENRE'), ('GHOST'), ('GHOUL'), ('GIANT'),
  ('GIDDY'), ('GIPSY'), ('GIRLY'), ('GIRTH'), ('GIVEN'), ('GIVER'), ('GLADE'), ('GLAND'), ('GLARE'), ('GLASS'), ('GLAZE'), ('GLEAM'),
  ('GLEAN'), ('GLIDE'), ('GLINT'), ('GLOAT'), ('GLOBE'), ('GLOOM'), ('GLORY'), ('GLOSS'), ('GLOVE'), ('GLYPH'), ('GNASH'), ('GNOME'),
  ('GODLY'), ('GOING'), ('GOLEM'), ('GOLLY'), ('GONAD'), ('GONER'), ('GOODY'), ('GOOEY'), ('GOOFY'), ('GOOSE'), ('GORGE'), ('GOUGE'),
  ('GOURD'), ('GRACE'), ('GRADE'), ('GRAFT'), ('GRAIL'), ('GRAIN'), ('GRAND'), ('GRANT'), ('GRAPE'), ('GRAPH'), ('GRASP'), ('GRASS'),
  ('GRATE'), ('GRAVE'), ('GRAVY'), ('GRAZE'), ('GREAT'), ('GREED'), ('GREEN'), ('GREET'), ('GRIEF'), ('GRILL'), ('GRIME'), ('GRIMY'),
  ('GRIND'), ('GRIPE'), ('GROAN'), ('GROIN'), ('GROOM'), ('GROPE'), ('GROSS'), ('GROUP'), ('GROUT'), ('GROVE'), ('GROWL'), ('GROWN'),
  ('GRUEL'), ('GRUFF'), ('GRUNT'), ('GUARD'), ('GUAVA'), ('GUESS'), ('GUEST'), ('GUIDE'), ('GUILD'), ('GUILE'), ('GUILT'), ('GUISE'),
  ('GULCH'), ('GULLY'), ('GUMBO'), ('GUMMY'), ('GUPPY'), ('GUSTO'), ('GUSTY'), ('HABIT'), ('HAIRY'), ('HALVE'), ('HANDY'), ('HAPPY'),
  ('HARDY'), ('HAREM'), ('HARPY'), ('HARRY'), ('HARSH'), ('HASTE'), ('HASTY'), ('HATCH'), ('HATER'), ('HAUNT'), ('HAUTE'), ('HAVEN'),
  ('HAVOC'), ('HAZEL'), ('HEADY'), ('HEARD'), ('HEART'), ('HEATH'), ('HEAVE'), ('HEAVY'), ('HEDGE'), ('HEFTY'), ('HEIST'), ('HELIX'),
  ('HELLO'), ('HENCE'), ('HERON'), ('HILLY'), ('HINGE'), ('HIPPO'), ('HIPPY'), ('HITCH'), ('HOARD'), ('HOBBY'), ('HOIST'), ('HOLLY'),
  ('HOMER'), ('HONEY'), ('HONOR'), ('HORDE'), ('HORNY'), ('HORSE'), ('HOTEL'), ('HOTLY'), ('HOUND'), ('HOUSE'), ('HOVEL'), ('HOVER'),
  ('HOWDY'), ('HUMAN'), ('HUMID'), ('HUMOR'), ('HUMPH'), ('HUMUS'), ('HUNCH'), ('HUNKY'), ('HURRY'), ('HUSKY'), ('HUSSY'), ('HUTCH'),
  ('HYDRO'), ('HYENA'), ('HYMEN'), ('HYPER'), ('ICILY'), ('ICING'), ('IDEAL'), ('IDIOM'), ('IDIOT'), ('IDLER'), ('IDYLL'), ('IGLOO'),
  ('ILIAC'), ('IMAGE'), ('IMBUE'), ('IMPEL'), ('IMPLY'), ('INANE'), ('INBOX'), ('INCUR'), ('INDEX'), ('INEPT'), ('INERT'), ('INFER'),
  ('INGOT'), ('INLAY'), ('INLET'), ('INNER'), ('INPUT'), ('INTER'), ('INTRO'), ('IONIC'), ('IRATE'), ('IRONY'), ('ISLET'), ('ISSUE'),
  ('ITCHY'), ('IVORY'), ('JAUNT'), ('JAZZY'), ('JELLY'), ('JERKY'), ('JETTY'), ('JEWEL'), ('JIFFY'), ('JOINT'), ('JOIST'), ('JOKER'),
  ('JOLLY'), ('JOUST'), ('JUDGE'), ('JUICE'), ('JUICY'), ('JUMBO'), ('JUMPY'), ('JUNTA'), ('JUNTO'), ('JUROR'), ('KAPPA'), ('KARMA'),
  ('KAYAK'), ('KEBAB'), ('KHAKI'), ('KIOSK'), ('KITTY'), ('KNACK'), ('KNAVE'), ('KNEAD'), ('KNEED'), ('KNEEL'), ('KNELT'), ('KNIFE'),
  ('KNOCK'), ('KNOLL'), ('KNOWN'), ('KOALA'), ('KRILL'), ('LABEL'), ('LABOR'), ('LADEN'), ('LADLE'), ('LAGER'), ('LANCE'), ('LANKY'),
  ('LAPEL'), ('LAPSE'), ('LARGE'), ('LARVA'), ('LASSO'), ('LATCH'), ('LATER'), ('LATHE'), ('LATTE'), ('LAUGH'), ('LAYER'), ('LEACH'),
  ('LEAFY'), ('LEAKY'), ('LEANT'), ('LEAPT'), ('LEARN'), ('LEASE'), ('LEASH'), ('LEAST'), ('LEAVE'), ('LEDGE'), ('LEECH'), ('LEERY'),
  ('LEFTY'), ('LEGAL'), ('LEGGY'), ('LEMON'), ('LEMUR'), ('LEPER'), ('LEVEL'), ('LEVER'), ('LIBEL'), ('LIEGE'), ('LIGHT'), ('LIKEN'),
  ('LILAC'), ('LIMBO'), ('LIMIT'), ('LINEN'), ('LINER'), ('LINGO'), ('LIPID'), ('LITHE'), ('LIVER'), ('LIVID'), ('LLAMA'), ('LOAMY'),
  ('LOATH'), ('LOBBY'), ('LOCAL'), ('LOCUS'), ('LODGE'), ('LOFTY'), ('LOGIC'), ('LOGIN'), ('LOOPY'), ('LOOSE'), ('LORRY'), ('LOSER'),
  ('LOUSE'), ('LOUSY'), ('LOVER'), ('LOWER'), ('LOWLY'), ('LOYAL'), ('LUCID'), ('LUCKY'), ('LUMEN'), ('LUMPY'), ('LUNAR'), ('LUNCH'),
  ('LUNGE'), ('LUPUS'), ('LURCH'), ('LURID'), ('LUSTY'), ('LYING'), ('LYMPH'), ('LYRIC'), ('MACAW'), ('MACHO'), ('MACRO'), ('MADAM'),
  ('MADLY'), ('MAFIA'), ('MAGIC'), ('MAGMA'), ('MAIZE'), ('MAJOR'), ('MAKER'), ('MAMBO'), ('MAMMA'), ('MAMMY'), ('MANGA'), ('MANGE'),
  ('MANGO'), ('MANGY'), ('MANIA'), ('MANIC'), ('MANLY'), ('MANOR'), ('MAPLE'), ('MARCH'), ('MARRY'), ('MARSH'), ('MASON'), ('MASSE'),
  ('MATCH'), ('MATEY'), ('MAUVE'), ('MAXIM'), ('MAYBE'), ('MAYOR'), ('MEALY'), ('MEANT'), ('MEATY'), ('MECCA'), ('MEDAL'), ('MEDIA'),
  ('MEDIC'), ('MELEE'), ('MELON'), ('MERCY'), ('MERGE'), ('MERIT'), ('MERRY'), ('METAL'), ('METER'), ('METRO'), ('MICRO'), ('MIDGE'),
  ('MIDST'), ('MIGHT'), ('MILKY'), ('MIMIC'), ('MINCE'), ('MINER'), ('MINIM'), ('MINOR'), ('MINTY'), ('MINUS'), ('MIRTH'), ('MISER'),
  ('MISSY'), ('MOCHA'), ('MODAL'), ('MODEL'), ('MODEM'), ('MOGUL'), ('MOIST'), ('MOLAR'), ('MOLDY'), ('MONEY'), ('MONTH'), ('MOODY'),
  ('MOOSE'), ('MORAL'), ('MORON'), ('MORPH'), ('MOSSY'), ('MOTEL'), ('MOTIF'), ('MOTOR'), ('MOTTO'), ('MOULT'), ('MOUND'), ('MOUNT'),
  ('MOURN'), ('MOUSE'), ('MOUTH'), ('MOVER'), ('MOVIE'), ('MOWER'), ('MUCKY'), ('MUCUS'), ('MUDDY'), ('MULCH'), ('MUMMY'), ('MUNCH'),
  ('MURAL'), ('MURKY'), ('MUSHY'), ('MUSIC'), ('MUSKY'), ('MUSTY'), ('MYRRH'), ('NADIR'), ('NAIVE'), ('NANNY'), ('NASAL'), ('NASTY'),
  ('NATAL'), ('NAVAL'), ('NAVEL'), ('NEEDY'), ('NEIGH'), ('NERDY'), ('NERVE'), ('NEVER'), ('NEWER'), ('NEWLY'), ('NICER'), ('NICHE'),
  ('NIECE'), ('NIGHT'), ('NINJA'), ('NINNY'), ('NINTH'), ('NOBLE'), ('NOBLY'), ('NOISE'), ('NOISY'), ('NOMAD'), ('NOOSE'), ('NORTH'),
  ('NOSEY'), ('NOTCH'), ('NOVEL'), ('NUDGE'), ('NURSE'), ('NUTTY'), ('NYLON'), ('NYMPH'), ('OAKEN'), ('OBESE'), ('OCCUR'), ('OCEAN'),
  ('OCTAL'), ('OCTET'), ('ODDER'), ('ODDLY'), ('OFFAL'), ('OFFER'), ('OFTEN'), ('OLDEN'), ('OLDER'), ('OLIVE'), ('OMBRE'), ('OMEGA'),
  ('ONION'), ('ONSET'), ('OPERA'), ('OPINE'), ('OPIUM'), ('OPTIC'), ('ORBIT'), ('ORDER'), ('ORGAN'), ('OTHER'), ('OTTER'), ('OUGHT'),
  ('OUNCE'), ('OUTDO'), ('OUTER'), ('OUTGO'), ('OVARY'), ('OVATE'), ('OVERT'), ('OVINE'), ('OVOID'), ('OWING'), ('OWNER'), ('OXIDE'),
  ('OZONE'), ('PADDY'), ('PAGAN'), ('PAINT'), ('PALER'), ('PALSY'), ('PANEL'), ('PANIC'), ('PANSY'), ('PAPAL'), ('PAPER'), ('PARER'),
  ('PARKA'), ('PARRY'), ('PARSE'), ('PARTY'), ('PASTA'), ('PASTE'), ('PASTY'), ('PATCH'), ('PATIO'), ('PATSY'), ('PATTY'), ('PAUSE'),
  ('PAYEE'), ('PAYER'), ('PEACE'), ('PEACH'), ('PEARL'), ('PECAN'), ('PEDAL'), ('PENAL'), ('PENCE'), ('PENNE'), ('PENNY'), ('PERCH'),
  ('PERIL'), ('PERKY'), ('PESKY'), ('PESTO'), ('PETAL'), ('PETTY'), ('PHASE'), ('PHONE'), ('PHONY'), ('PHOTO'), ('PIANO'), ('PICKY'),
  ('PIECE'), ('PIETY'), ('PIGGY'), ('PILOT'), ('PINCH'), ('PINEY'), ('PINKY'), ('PINTO'), ('PIPER'), ('PIQUE'), ('PITCH'), ('PITHY'),
  ('PIVOT'), ('PIXEL'), ('PIXIE'), ('PIZZA'), ('PLACE'), ('PLAID'), ('PLAIN'), ('PLAIT'), ('PLANE'), ('PLANK'), ('PLANT'), ('PLATE'),
  ('PLAZA'), ('PLEAD'), ('PLEAT'), ('PLIED'), ('PLIER'), ('PLUCK'), ('PLUMB'), ('PLUME'), ('PLUMP'), ('PLUNK'), ('PLUSH'), ('POESY'),
  ('POINT'), ('POISE'), ('POKER'), ('POLAR'), ('POLKA'), ('POLYP'), ('POOCH'), ('POPPY'), ('PORCH'), ('POSER'), ('POSIT'), ('POSSE'),
  ('POUCH'), ('POUND'), ('POUTY'), ('POWER'), ('PRANK'), ('PRAWN'), ('PREEN'), ('PRESS'), ('PRICE'), ('PRICK'), ('PRIDE'), ('PRIED'),
  ('PRIME'), ('PRIMO'), ('PRINT'), ('PRIOR'), ('PRISM'), ('PRIVY'), ('PRIZE'), ('PROBE'), ('PRONE'), ('PRONG'), ('PROOF'), ('PROSE'),
  ('PROUD'), ('PROVE'), ('PROWL'), ('PROXY'), ('PRUDE'), ('PRUNE'), ('PSALM'), ('PUBIC'), ('PUDGY'), ('PUFFY'), ('PULPY'), ('PULSE'),
  ('PUNCH'), ('PUPAL'), ('PUPIL'), ('PUPPY'), ('PUREE'), ('PURER'), ('PURGE'), ('PURSE'), ('PUSHY'), ('PUTTY'), ('PYGMY'), ('QUACK'),
  ('QUAIL'), ('QUAKE'), ('QUALM'), ('QUARK'), ('QUART'), ('QUASH'), ('QUASI'), ('QUEEN'), ('QUEER'), ('QUELL'), ('QUERY'), ('QUEST'),
  ('QUEUE'), ('QUICK'), ('QUIET'), ('QUILL'), ('QUILT'), ('QUIRK'), ('QUITE'), ('QUOTA'), ('QUOTE'), ('QUOTH'), ('RABBI'), ('RABID'),
  ('RACER'), ('RADAR'), ('RADII'), ('RADIO'), ('RAINY'), ('RAISE'), ('RAJAH'), ('RALLY'), ('RALPH'), ('RAMEN'), ('RANCH'), ('RANDY'),
  ('RANGE'), ('RAPID'), ('RARER'), ('RASPY'), ('RATIO'), ('RATTY'), ('RAVEN'), ('RAYON'), ('RAZOR'), ('REACH'), ('REACT'), ('READY'),
  ('REALM'), ('REARM'), ('REBAR'), ('REBEL'), ('REBUS'), ('REBUT'), ('RECAP'), ('RECUR'), ('RECUT'), ('REEDY'), ('REFER'), ('REFIT'),
  ('REGAL'), ('REHAB'), ('REIGN'), ('RELAX'), ('RELAY'), ('RELIC'), ('REMIT'), ('RENAL'), ('RENEW'), ('REPAY'), ('REPEL'), ('REPLY'),
  ('RERUN'), ('RESET'), ('RESIN'), ('RETCH'), ('RETRO'), ('RETRY'), ('REUSE'), ('REVEL'), ('REVUE'), ('RHINO'), ('RHYME'), ('RIDER'),
  ('RIDGE'), ('RIFLE'), ('RIGHT'), ('RIGID'), ('RIGOR'), ('RINSE'), ('RIPEN'), ('RIPER'), ('RISEN'), ('RISER'), ('RISKY'), ('RIVAL'),
  ('RIVER'), ('RIVET'), ('ROACH'), ('ROAST'), ('ROBIN'), ('ROBOT'), ('ROCKY'), ('RODEO'), ('ROGER'), ('ROGUE'), ('ROOMY'), ('ROOST'),
  ('ROTOR'), ('ROUGE'), ('ROUGH'), ('ROUND'), ('ROUSE'), ('ROUTE'), ('ROVER'), ('ROWDY'), ('ROWER'), ('ROYAL'), ('RUDDY'), ('RUDER'),
  ('RUGBY'), ('RULER'), ('RUMBA'), ('RUMOR'), ('RUPEE'), ('RURAL'), ('RUSTY'), ('SADLY'), ('SAFER'), ('SAINT'), ('SALAD'), ('SALLY'),
  ('SALON'), ('SALSA'), ('SALTY'), ('SALVE'), ('SALVO'), ('SANDY'), ('SANER'), ('SAPPY'), ('SASSY'), ('SATIN'), ('SATYR'), ('SAUCE'),
  ('SAUCY'), ('SAUNA'), ('SAUTE'), ('SAVOR'), ('SAVOY'), ('SAVVY'), ('SCALD'), ('SCALE'), ('SCALP'), ('SCALY'), ('SCAMP'), ('SCANT'),
  ('SCARE'), ('SCARF'), ('SCARY'), ('SCENE'), ('SCENT'), ('SCION'), ('SCOFF'), ('SCOLD'), ('SCONE'), ('SCOOP'), ('SCOPE'), ('SCORE'),
  ('SCORN'), ('SCOUR'), ('SCOUT'), ('SCOWL'), ('SCRAM'), ('SCRAP'), ('SCREE'), ('SCREW'), ('SCRUB'), ('SCRUM'), ('SCUBA'), ('SEDAN'),
  ('SEEDY'), ('SEGUE'), ('SEIZE'), ('SEMEN'), ('SENSE'), ('SEPIA'), ('SERIF'), ('SERUM'), ('SERVE'), ('SETUP'), ('SEVEN'), ('SEVER'),
  ('SEWER'), ('SHACK'), ('SHADE'), ('SHADY'), ('SHAFT'), ('SHAKE'), ('SHAKY'), ('SHALE'), ('SHALL'), ('SHALT'), ('SHAME'), ('SHANK'),
  ('SHAPE'), ('SHARD'), ('SHARE'), ('SHARK'), ('SHARP'), ('SHAVE'), ('SHAWL'), ('SHEAR'), ('SHEEN'), ('SHEEP'), ('SHEER'), ('SHEET'),
  ('SHEIK'), ('SHELF'), ('SHELL'), ('SHIED'), ('SHIFT'), ('SHINE'), ('SHINY'), ('SHIRE'), ('SHIRK'), ('SHIRT'), ('SHOAL'), ('SHOCK'),
  ('SHONE'), ('SHOOK'), ('SHOOT'), ('SHORE'), ('SHORN'), ('SHORT'), ('SHOUT'), ('SHOVE'), ('SHOWN'), ('SHOWY'), ('SHREW'), ('SHRUB'),
  ('SHRUG'), ('SHUCK'), ('SHUNT'), ('SHUSH'), ('SHYLY'), ('SIEGE'), ('SIEVE'), ('SIGHT'), ('SIGMA'), ('SILKY'), ('SILLY'), ('SINCE'),
  ('SINEW'), ('SINGE'), ('SIREN'), ('SISSY'), ('SIXTH'), ('SIXTY'), ('SKATE'), ('SKIER'), ('SKIFF'), ('SKILL'), ('SKIMP'), ('SKIRT'),
  ('SKULK'), ('SKULL'), ('SKUNK'), ('SLACK'), ('SLAIN'), ('SLANG'), ('SLANT'), ('SLASH'), ('SLATE'), ('SLEEK'), ('SLEEP'), ('SLEET'),
  ('SLEPT'), ('SLICE'), ('SLICK'), ('SLIDE'), ('SLIME'), ('SLIMY'), ('SLING'), ('SLINK'), ('SLOOP'), ('SLOPE'), ('SLOSH'), ('SLOTH'),
  ('SLUMP'), ('SLUNG'), ('SLUNK'), ('SLURP'), ('SLUSH'), ('SLYLY'), ('SMACK'), ('SMALL'), ('SMART'), ('SMASH'), ('SMEAR'), ('SMELL'),
  ('SMELT'), ('SMILE'), ('SMIRK'), ('SMITE'), ('SMITH'), ('SMOCK'), ('SMOKE'), ('SMOKY'), ('SMOTE'), ('SNACK'), ('SNAIL'), ('SNAKE'),
  ('SNAKY'), ('SNARE'), ('SNARL'), ('SNEAK'), ('SNEER'), ('SNIDE'), ('SNIFF'), ('SNIPE'), ('SNOOP'), ('SNORE'), ('SNORT'), ('SNOUT'),
  ('SNOWY'), ('SNUCK'), ('SNUFF'), ('SOAPY'), ('SOBER'), ('SOGGY'), ('SOLAR'), ('SOLID'), ('SOLVE'), ('SONAR'), ('SONIC'), ('SOOTH'),
  ('SOOTY'), ('SORRY'), ('SOUND'), ('SOUTH'), ('SOWER'), ('SPACE'), ('SPADE'), ('SPANK'), ('SPARE'), ('SPARK'), ('SPASM'), ('SPAWN'),
  ('SPEAK'), ('SPEAR'), ('SPECK'), ('SPEED'), ('SPELL'), ('SPELT'), ('SPEND'), ('SPENT'), ('SPICE'), ('SPICY'), ('SPIED'), ('SPIEL'),
  ('SPIKE'), ('SPIKY'), ('SPILL'), ('SPILT'), ('SPINE'), ('SPINY'), ('SPIRE'), ('SPITE'), ('SPLAT'), ('SPLIT'), ('SPOIL'), ('SPOKE'),
  ('SPOOF'), ('SPOOK'), ('SPOOL'), ('SPOON'), ('SPORE'), ('SPORT'), ('SPOUT'), ('SPRAY'), ('SPREE'), ('SPRIG'), ('SPUNK'), ('SPURN'),
  ('SPURT'), ('SQUAD'), ('SQUAT'), ('SQUIB'), ('STACK'), ('STAFF'), ('STAGE'), ('STAID'), ('STAIN'), ('STAIR'), ('STAKE'), ('STALE'),
  ('STALK'), ('STALL'), ('STAMP'), ('STAND'), ('STANK'), ('STARE'), ('STARK'), ('START'), ('STASH'), ('STATE'), ('STAVE'), ('STEAD'),
  ('STEAK'), ('STEAL'), ('STEAM'), ('STEED'), ('STEEL'), ('STEEP'), ('STEER'), ('STEIN'), ('STERN'), ('STICK'), ('STIFF'), ('STILL'),
  ('STILT'), ('STING'), ('STINK'), ('STINT'), ('STOCK'), ('STOIC'), ('STOKE'), ('STOLE'), ('STOMP'), ('STONE'), ('STONY'), ('STOOD'),
  ('STOOL'), ('STOOP'), ('STORE'), ('STORK'), ('STORM'), ('STORY'), ('STOUT'), ('STOVE'), ('STRAP'), ('STRAW'), ('STRAY'), ('STRIP'),
  ('STRUT'), ('STUCK'), ('STUDY'), ('STUFF'), ('STUMP'), ('STUNG'), ('STUNK'), ('STUNT'), ('STYLE'), ('SUAVE'), ('SUGAR'), ('SUING'),
  ('SUITE'), ('SULKY'), ('SULLY'), ('SUMAC'), ('SUNNY'), ('SUPER'), ('SURER'), ('SURGE'), ('SURLY'), ('SUSHI'), ('SWAMI'), ('SWAMP'),
  ('SWARM'), ('SWASH'), ('SWATH'), ('SWEAR'), ('SWEAT'), ('SWEEP'), ('SWEET'), ('SWELL'), ('SWEPT'), ('SWIFT'), ('SWILL'), ('SWINE'),
  ('SWING'), ('SWIRL'), ('SWISH'), ('SWOON'), ('SWOOP'), ('SWORD'), ('SWORE'), ('SWORN'), ('SWUNG'), ('SYNOD'), ('SYRUP'), ('TABBY'),
  ('TABLE'), ('TABOO'), ('TACIT'), ('TACKY'), ('TAFFY'), ('TAINT'), ('TAKEN'), ('TAKER'), ('TALLY'), ('TALON'), ('TAMER'), ('TANGO'),
  ('TANGY'), ('TAPER'), ('TAPIR'), ('TARDY'), ('TAROT'), ('TASTE'), ('TASTY'), ('TATTY'), ('TAUNT'), ('TAWNY'), ('TEACH'), ('TEARY'),
  ('TEASE'), ('TEDDY'), ('TEETH'), ('TEMPO'), ('TENET'), ('TENOR'), ('TENSE'), ('TENTH'), ('TEPEE'), ('TEPID'), ('TERRA'), ('TERSE'),
  ('TESTY'), ('THANK'), ('THEFT'), ('THEIR'), ('THEME'), ('THERE'), ('THESE'), ('THETA'), ('THICK'), ('THIEF'), ('THIGH'), ('THING'),
  ('THINK'), ('THIRD'), ('THONG'), ('THORN'), ('THOSE'), ('THREE'), ('THREW'), ('THROB'), ('THROW'), ('THRUM'), ('THUMB'), ('THUMP'),
  ('THYME'), ('TIARA'), ('TIBIA'), ('TIDAL'), ('TIGER'), ('TIGHT'), ('TILDE'), ('TIMER'), ('TIMID'), ('TIPSY'), ('TITAN'), ('TITHE'),
  ('TITLE'), ('TOAST'), ('TODAY'), ('TODDY'), ('TOKEN'), ('TONAL'), ('TONGA'), ('TONIC'), ('TOOTH'), ('TOPAZ'), ('TOPIC'), ('TORCH'),
  ('TORSO'), ('TORUS'), ('TOTAL'), ('TOTEM'), ('TOUCH'), ('TOUGH'), ('TOWEL'), ('TOWER'), ('TOXIC'), ('TOXIN'), ('TRACE'), ('TRACK'),
  ('TRACT'), ('TRADE'), ('TRAIL'), ('TRAIN'), ('TRAIT'), ('TRAMP'), ('TRASH'), ('TRAWL'), ('TREAD'), ('TREAT'), ('TREND'), ('TRIAD'),
  ('TRIAL'), ('TRIBE'), ('TRICE'), ('TRICK'), ('TRIED'), ('TRIPE'), ('TRITE'), ('TROLL'), ('TROOP'), ('TROPE'), ('TROUT'), ('TROVE'),
  ('TRUCE'), ('TRUCK'), ('TRUER'), ('TRULY'), ('TRUMP'), ('TRUNK'), ('TRUSS'), ('TRUST'), ('TRUTH'), ('TRYST'), ('TUBAL'), ('TUBER'),
  ('TULIP'), ('TULLE'), ('TUMOR'), ('TUNIC'), ('TURBO'), ('TUTOR'), ('TWANG'), ('TWEAK'), ('TWEED'), ('TWEET'), ('TWICE'), ('TWINE'),
  ('TWIRL'), ('TWIST'), ('TWIXT'), ('TYING'), ('UDDER'), ('ULCER'), ('ULTRA'), ('UMBRA'), ('UNCLE'), ('UNCUT'), ('UNDER'), ('UNDID'),
  ('UNDUE'), ('UNFED'), ('UNFIT'), ('UNIFY'), ('UNION'), ('UNITE'), ('UNITY'), ('UNLIT'), ('UNMET'), ('UNSET'), ('UNTIE'), ('UNTIL'),
  ('UNWED'), ('UNZIP'), ('UPPER'), ('UPSET'), ('URBAN'), ('URINE'), ('USAGE'), ('USHER'), ('USING'), ('USUAL'), ('USURP'), ('UTILE'),
  ('UTTER'), ('VAGUE'), ('VALET'), ('VALID'), ('VALOR'), ('VALUE'), ('VALVE'), ('VAPID'), ('VAPOR'), ('VAULT'), ('VAUNT'), ('VEGAN'),
  ('VENOM'), ('VENUE'), ('VERGE'), ('VERSE'), ('VERSO'), ('VERVE'), ('VICAR'), ('VIDEO'), ('VIGIL'), ('VIGOR'), ('VILLA'), ('VINYL'),
  ('VIOLA'), ('VIPER'), ('VIRAL'), ('VIRUS'), ('VISIT'), ('VISOR'), ('VISTA'), ('VITAL'), ('VIVID'), ('VIXEN'), ('VOCAL'), ('VODKA'),
  ('VOGUE'), ('VOICE'), ('VOILA'), ('VOMIT'), ('VOTER'), ('VOUCH'), ('VOWEL'), ('VYING'), ('WACKY'), ('WAFER'), ('WAGER'), ('WAGON'),
  ('WAIST'), ('WAIVE'), ('WALTZ'), ('WARTY'), ('WASTE'), ('WATCH'), ('WATER'), ('WAVER'), ('WAXEN'), ('WEARY'), ('WEAVE'), ('WEDGE'),
  ('WEEDY'), ('WEIGH'), ('WEIRD'), ('WELCH'), ('WELSH'), ('WHACK'), ('WHALE'), ('WHARF'), ('WHEAT'), ('WHEEL'), ('WHELP'), ('WHERE'),
  ('WHICH'), ('WHIFF'), ('WHILE'), ('WHINE'), ('WHINY'), ('WHIRL'), ('WHISK'), ('WHITE'), ('WHOLE'), ('WHOOP'), ('WHOSE'), ('WIDEN'),
  ('WIDER'), ('WIDOW'), ('WIDTH'), ('WIELD'), ('WIGHT'), ('WILLY'), ('WIMPY'), ('WINCE'), ('WINCH'), ('WINDY'), ('WISER'), ('WISPY'),
  ('WITCH'), ('WITTY'), ('WOKEN'), ('WOMAN'), ('WOMEN'), ('WOODY'), ('WOOER'), ('WOOLY'), ('WOOZY'), ('WORDY'), ('WORLD'), ('WORRY'),
  ('WORSE'), ('WORST'), ('WORTH'), ('WOULD'), ('WOUND'), ('WOVEN'), ('WRACK'), ('WRATH'), ('WREAK'), ('WRECK'), ('WREST'), ('WRING'),
  ('WRIST'), ('WRITE'), ('WRONG'), ('WROTE'), ('WRUNG'), ('WRYLY'), ('YACHT'), ('YEARN'), ('YEAST'), ('YIELD'), ('YOUNG'), ('YOUTH'),
  ('ZEBRA'), ('ZESTY'), ('ZONAL')
on conflict do nothing;
