// Supabase Edge Function: submit-wordle (v3)
// Vervang hiermee de volledige inhoud van je bestaande submit-wordle/index.ts.
//
// Wijziging t.o.v. v2:
// - Een kaart die je al had, komt er nu ook bij als dubbel (om te ruilen),
//   en je krijgt er daarnaast nog steeds polycoins voor.
//
// Wijzigingen t.o.v. v1:
// - Random wordt getrokken via crypto.getRandomValues i.p.v. Math.random
//   (elke trekking blijft sowieso al onafhankelijk per gebruiker/dag,
//   want elke aanroep gebeurt in een eigen functie-invocatie; dit is
//   gewoon een steviger random-bron).
// - Als je al kaart X bezit en trekt 'm opnieuw: polycoins (afhankelijk van
//   de zeldzaamheid) op je wallet.
import { createClient } from "npm:@supabase/supabase-js@2";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

// Kansen per aantal pogingen: [common, epic, legendary] in procent
const ODDS: Record<number, [number, number, number]> = {
  1: [0, 20, 80],
  2: [20, 50, 30],
  3: [55, 35, 10],
  4: [75, 22, 3],
  5: [88, 11, 1],
  6: [95, 4.5, 0.5],
};

// Polycoins die je bovenop de dubbele kaart krijgt wanneer je een kaart trekt die je al had
const COIN_VALUES: Record<string, number> = { common: 10, epic: 25, legendary: 60, cat: 5 };

function cryptoRandom(): number {
  const buf = new Uint32Array(1);
  crypto.getRandomValues(buf);
  return buf[0] / 4294967296; // 2^32
}

// Onzichtbare tekens die sommige Discord-clients/toetsenborden toevoegen aan emoji
// (variatieselector en zero-width joiner). Die halen we er eerst uit, zodat elk
// blokje/rondje daarna als precies 1 teken overblijft.
const INVISIBLE = /[\uFE0F\u200D]/g;

// Alle varianten van de Wordle-kleurjes die we accepteren.
const TILE = "\u{1F7E9}\u{1F7E8}\u{1F7E5}\u2B1B\u2B1C\u{1F7E2}\u{1F7E1}\u26AB\u26AA";
const TILE_RE = new RegExp(`[${TILE}]`, "u");
const GREEN = new RegExp(`^[\u{1F7E9}\u{1F7E2}]+$`, "u");

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, "Content-Type": "application/json" },
  });
}

function pickRarity(attempts: number): "common" | "epic" | "legendary" {
  const [_common, epic, legendary] = ODDS[attempts];
  const roll = cryptoRandom() * 100;
  if (roll < legendary) return "legendary";
  if (roll < legendary + epic) return "epic";
  return "common";
}

function parseShare(text: string): { puzzleNumber: number; solved: boolean; attempts: number } | { fail: string } {
  const clean = text.replace(/\r/g, "").replace(INVISIBLE, "");

  const headMatch = clean.match(/Wordle\D{0,10}?([\d.,]{3,7})\s*(X|[1-6])\/6/iu);
  if (!headMatch) return { fail: "geen kopregel (Wordle 1.234 4/6) gevonden" };
  const puzzleNumber = Number(headMatch[1].replace(/[.,]/g, ""));
  const failed = headMatch[2].toUpperCase() === "X";

  const rows = clean
    .split("\n")
    .map((l) => Array.from(l.trim()).filter((ch) => TILE_RE.test(ch)))
    .filter((arr) => arr.length === 5)
    .map((arr) => arr.join(""));

  if (rows.length < 1 || rows.length > 6) return { fail: `${rows.length} rijen van 5 blokjes gevonden (verwacht 1-6)` };
  if (!failed && rows.length !== Number(headMatch[2])) {
    return { fail: `kopregel zegt ${headMatch[2]}/6 maar er zijn ${rows.length} rijen` };
  }

  const solvedByGrid = !failed && GREEN.test(rows[rows.length - 1]);
  if (!failed && !solvedByGrid) return { fail: "laatste rij is niet volledig groen terwijl de kopregel geen X toont" };

  return { puzzleNumber, solved: !failed, attempts: rows.length };
}

async function fetchOfficial(date: string) {
  const res = await fetch(`https://www.nytimes.com/svc/wordle/v2/${date}.json`, {
    headers: {
      "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36",
      "Accept": "application/json",
    },
  });
  if (!res.ok) throw new Error(`NYT gaf status ${res.status} terug.`);
  const data = await res.json().catch(() => {
    throw new Error("NYT gaf geen geldig JSON-antwoord terug.");
  });
  const solution = String(data.solution ?? "").toUpperCase();
  const puzzleNumber = Number(data.days_since_launch);
  if (!/^[A-Z]{5}$/.test(solution)) throw new Error("Geen geldige oplossing ontvangen.");
  return { solution, puzzleNumber };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return json({ error: "Methode niet toegestaan." }, 405);

  try {
    const url = Deno.env.get("SUPABASE_URL")!;
    const userClient = createClient(url, Deno.env.get("SUPABASE_ANON_KEY")!, {
      global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } },
    });
    const { data: { user }, error: userErr } = await userClient.auth.getUser();
    if (userErr || !user) return json({ error: "Je bent niet ingelogd." }, 401);

    const admin = createClient(url, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const today = new Date().toLocaleDateString("sv-SE", { timeZone: "Europe/Brussels" });

    const { data: existing } = await admin
      .from("daily_plays")
      .select("user_id")
      .eq("user_id", user.id)
      .eq("play_date", today)
      .maybeSingle();
    if (existing) return json({ error: "Je hebt vandaag al een kaart getrokken. Kom morgen terug!" }, 409);

    const body = await req.json().catch(() => null);
    const text = body?.text;
    const word = String(body?.word ?? "").trim().toUpperCase();
    if (typeof text !== "string" || text.trim().length < 10 || text.length > 2000) {
      return json({ error: "Plak de volledige deeltekst van je Wordle-resultaat." }, 400);
    }

    const parsed = parseShare(text);
    if ("fail" in parsed) {
      console.error("Deeltekst niet herkend:", parsed.fail, "— tekst:", JSON.stringify(text));
      return json({ error: "Dit lijkt geen geldige Wordle-deeltekst. Klik in Discord op 'Share' en plak het resultaat hier onveranderd." }, 422);
    }

    if (parsed.solved && !/^[A-Z]{5}$/.test(word)) {
      return json({ error: "Vul het juiste woord van 5 letters in dat je geraden hebt." }, 400);
    }

    let official;
    try {
      official = await fetchOfficial(today);
    } catch (e) {
      console.error("NYT-oplossing ophalen mislukt:", e);
      return json({ error: "De oplossing van vandaag kon niet gecontroleerd worden. Probeer het over enkele minuten opnieuw." }, 502);
    }

    if (Number.isFinite(official.puzzleNumber) && official.puzzleNumber > 0 && parsed.puzzleNumber !== official.puzzleNumber) {
      return json({ error: "Dit is niet de Wordle van vandaag. Plak het resultaat van de puzzel van vandaag." }, 422);
    }
    if (parsed.solved && word !== official.solution) {
      return json({ error: "Dat is niet het juiste woord van vandaag. Vul het woord in dat je effectief geraden hebt." }, 422);
    }

    const rarity = parsed.solved ? pickRarity(parsed.attempts) : "cat";

    const { data: pool, error: poolErr } = await admin.from("cards").select("*").eq("rarity", rarity);
    if (poolErr || !pool || pool.length === 0) {
      return json({ error: "Geen kaarten gevonden voor deze zeldzaamheid." }, 500);
    }
    const card = pool[Math.floor(cryptoRandom() * pool.length)];

    const { count: ownedCount } = await admin
      .from("user_cards")
      .select("id", { count: "exact", head: true })
      .eq("user_id", user.id)
      .eq("card_id", card.id);
    const isDuplicate = (ownedCount || 0) > 0;

    const { error: playErr } = await admin.from("daily_plays").insert({
      user_id: user.id,
      play_date: today,
      attempts: parsed.solved ? parsed.attempts : null,
      solved: parsed.solved,
      card_id: card.id,
    });
    if (playErr) {
      if (playErr.code === "23505") return json({ error: "Je hebt vandaag al een kaart getrokken." }, 409);
      throw playErr;
    }

    // De kaart komt er altijd bij, ook als je ze al had (dan is het een dubbel om te ruilen)
    const { error: cardErr } = await admin.from("user_cards").insert({ user_id: user.id, card_id: card.id });
    if (cardErr) throw cardErr;

    let coinsEarned = 0;
    if (isDuplicate) {
      coinsEarned = COIN_VALUES[rarity] ?? 10;
      const { data: wallet } = await admin.from("user_wallet").select("polycoins").eq("user_id", user.id).maybeSingle();
      const current = wallet?.polycoins ?? 0;
      const { error: walletErr } = await admin.from("user_wallet").upsert({ user_id: user.id, polycoins: current + coinsEarned });
      if (walletErr) throw walletErr;
    }

    return json({ card, rarity, solved: parsed.solved, attempts: parsed.solved ? parsed.attempts : null, isDuplicate, coinsEarned, cardAdded: true });
  } catch (e) {
    console.error(e);
    return json({ error: e instanceof Error ? e.message : "Onbekende fout." }, 500);
  }
});
