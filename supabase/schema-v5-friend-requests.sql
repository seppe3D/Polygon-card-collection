-- Polygon Trading Cards — uitbreiding v5: vriendschapsverzoeken + statistieken van vrienden
-- Voer dit volledige bestand in één keer uit in Supabase SQL Editor,
-- ná schema-v4-friends-trading.sql. Veilig om opnieuw te draaien.

-- 1. Vriendschapsverzoeken -------------------------------------------------
-- Een openstaand verzoek is één rij. Bij accepteren/weigeren/annuleren wordt
-- de rij verwijderd (en bij accepteren komen er 2 rijen in friendships bij).
create table if not exists public.friend_requests (
  id bigserial primary key,
  sender_id uuid not null references auth.users(id) on delete cascade,
  recipient_id uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (sender_id, recipient_id),
  check (sender_id <> recipient_id)
);
create index if not exists friend_requests_recipient_idx on public.friend_requests (recipient_id);

alter table public.friend_requests enable row level security;
drop policy if exists "eigen vriendschapsverzoeken lezen" on public.friend_requests;
create policy "eigen vriendschapsverzoeken lezen" on public.friend_requests
  for select to authenticated using (auth.uid() = sender_id or auth.uid() = recipient_id);
-- Bewust GEEN insert/update/delete policy: alles verloopt via de functies hieronder.

-- 2. Niet meer rechtstreeks vrienden worden ----------------------------------
-- Vriendschappen ontstaan enkel nog via respond_friend_request / send_friend_request.
-- Verwijderen van een vriend blijft gewoon mogelijk (policy "vriend verwijderen").
drop policy if exists "vriend toevoegen" on public.friendships;

-- 3. send_friend_request: verzoek sturen op basis van vriendencode ----------
-- Heeft de andere persoon jou al een verzoek gestuurd? Dan worden jullie meteen vrienden.
create or replace function public.send_friend_request(p_code text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  v_target public.profiles;
  v_reverse bigint;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;

  select * into v_target from public.profiles where friend_code = upper(trim(p_code));
  if not found then raise exception 'Geen account gevonden met die code.'; end if;
  if v_target.id = me then raise exception 'Dat is je eigen code.'; end if;

  if exists (select 1 from public.friendships where user_id = me and friend_id = v_target.id) then
    raise exception '% is al je vriend.', v_target.display_name;
  end if;

  select id into v_reverse from public.friend_requests
    where sender_id = v_target.id and recipient_id = me;
  if found then
    insert into public.friendships (user_id, friend_id)
      values (me, v_target.id), (v_target.id, me)
      on conflict do nothing;
    delete from public.friend_requests where id = v_reverse;
    return jsonb_build_object('status', 'accepted', 'name', v_target.display_name);
  end if;

  if exists (select 1 from public.friend_requests where sender_id = me and recipient_id = v_target.id) then
    raise exception 'Je hebt al een verzoek gestuurd naar %.', v_target.display_name;
  end if;

  insert into public.friend_requests (sender_id, recipient_id) values (me, v_target.id);
  return jsonb_build_object('status', 'sent', 'name', v_target.display_name);
end;
$$;

-- 4. respond_friend_request: accepteren / weigeren (ontvanger) of annuleren (verzender)
create or replace function public.respond_friend_request(
  p_request_id bigint,
  p_action text
) returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
  r public.friend_requests;
begin
  if me is null then raise exception 'Niet ingelogd.'; end if;

  select * into r from public.friend_requests where id = p_request_id for update;
  if not found then raise exception 'Dit verzoek bestaat niet meer.'; end if;

  if p_action in ('accept', 'decline') then
    if me <> r.recipient_id then raise exception 'Dit verzoek is niet aan jou gericht.'; end if;
    if p_action = 'accept' then
      insert into public.friendships (user_id, friend_id)
        values (r.sender_id, r.recipient_id), (r.recipient_id, r.sender_id)
        on conflict do nothing;
    end if;
  elsif p_action = 'cancel' then
    if me <> r.sender_id then raise exception 'Dit is niet jouw verzoek.'; end if;
  else
    raise exception 'Onbekende actie.';
  end if;

  delete from public.friend_requests where id = p_request_id;
end;
$$;

grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.respond_friend_request(bigint, text) to authenticated;

-- 5. Vrienden mogen elkaars Wordle-geschiedenis zien (voor de statistieken) --
drop policy if exists "vrienden spelletjes lezen" on public.daily_plays;
create policy "vrienden spelletjes lezen" on public.daily_plays
  for select to authenticated using (
    exists (
      select 1 from public.friendships f
      where f.user_id = auth.uid() and f.friend_id = daily_plays.user_id
    )
  );
