-- Multi-Speaker: schema for the hosted, multi-house service.
--
-- Run this once in the Supabase SQL editor of the project that backs the
-- website. It is safe to re-run.
--
-- The shape of the system:
--
--   * A **house** is one Mac with speakers attached to it. It has an owner and
--     any number of members, all of them real signed-in users.
--   * A **device** is the Mac agent for a house. It authenticates with a bearer
--     token that this schema mints and only ever shows once. It is not a user
--     and cannot read anything except its own house's command queue.
--   * The **website** talks to Postgres directly with the anon key and the
--     signed-in user's JWT. Every policy below keys on `auth.uid()`, so the
--     anon key grants nothing on its own.
--
-- The service_role key is not used by anything outside Supabase itself. In
-- particular it is never handed to a user's Mac, which is what makes it safe to
-- run one backend for many people.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ------------------------------------------------------- v1 teardown
--
-- The first version of this schema had a single `rooms` table and no accounts.
-- Its speaker/playback/command rows are pure cache — the Mac republishes them
-- within two seconds of starting — so dropping them costs nothing.

do $$
begin
    if exists (
        select 1 from information_schema.columns
         where table_schema = 'public'
           and table_name = 'speakers'
           and column_name = 'room_id'
    ) then
        drop table if exists commands, playback, speakers, rooms cascade;
    end if;
end $$;

-- ----------------------------------------------------------- houses

create table if not exists houses (
    id          uuid primary key default gen_random_uuid(),
    owner_id    uuid not null references auth.users(id) on delete cascade,
    name        text not null check (length(btrim(name)) between 1 and 60),
    -- The tail of the invite link. Rotating it revokes every link handed out so
    -- far without disturbing the people who already joined.
    invite_code text not null unique
                default translate(encode(extensions.gen_random_bytes(9), 'base64'), '+/', '-_'),
    created_at  timestamptz not null default now()
);

create index if not exists houses_owner_idx on houses (owner_id);

-- Membership is explicit, including for the owner, so that one join against
-- this table answers "what can this user see?" for every other policy.
create table if not exists house_members (
    house_id uuid not null references houses(id) on delete cascade,
    user_id  uuid not null references auth.users(id) on delete cascade,
    role     text not null default 'member' check (role in ('owner', 'member')),
    joined_at timestamptz not null default now(),
    primary key (house_id, user_id)
);

create index if not exists house_members_user_idx on house_members (user_id);

-- ---------------------------------------------------------- devices
-- One row per Mac running the app. `token_hash` is sha256 of a token that is
-- returned exactly once, at creation, and never stored in plaintext.

create table if not exists devices (
    id           uuid primary key default gen_random_uuid(),
    house_id     uuid not null references houses(id) on delete cascade,
    name         text not null default 'Mac',
    token_hash   bytea not null unique,
    created_at   timestamptz not null default now(),
    last_seen_at timestamptz
);

create index if not exists devices_house_idx on devices (house_id);

-- --------------------------------------------------------- speakers
-- Written only by the Mac agent, through agent_publish().

create table if not exists speakers (
    house_id        uuid not null references houses(id) on delete cascade,
    address         text not null,               -- normalized MAC, e.g. 28-fa-19-96-23-7d
    name            text not null,
    is_connected    boolean not null default false,
    is_selected     boolean not null default false,
    volume          real    not null default 0,  -- 0..1
    supports_volume boolean not null default false,
    is_muted        boolean not null default false,
    supports_mute   boolean not null default false,
    delay_ms        integer not null default 0,
    updated_at      timestamptz not null default now(),
    primary key (house_id, address)
);

-- --------------------------------------------------------- playback

create table if not exists playback (
    house_id      uuid primary key references houses(id) on delete cascade,
    is_playing    boolean not null default false,
    track         text,
    artist        text,
    album         text,
    artwork_url   text,
    output_active boolean not null default false, -- is Multi-Speaker the system output?
    updated_at    timestamptz not null default now()
);

-- --------------------------------------------------------- commands
-- Written by phones, drained by the Mac agent every 750ms.

create table if not exists commands (
    id          bigserial primary key,
    house_id    uuid not null references houses(id) on delete cascade,
    kind        text not null check (kind in (
                    'set_volume', 'set_muted', 'set_selected', 'set_delay',
                    'set_active', 'playpause', 'next', 'previous')),
    address     text,          -- speaker target; null for playback commands
    value       double precision,
    created_at  timestamptz not null default now(),
    consumed_at timestamptz
);

create index if not exists commands_pending_idx
    on commands (house_id, id) where consumed_at is null;

-- Keep the table from growing without bound; the agent never looks back.
create or replace function prune_commands() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
begin
    delete from commands
     where consumed_at is not null
       and consumed_at < now() - interval '1 hour';
    return null;
end;
$$;

drop trigger if exists prune_commands_trigger on commands;
create trigger prune_commands_trigger
    after insert on commands
    execute function prune_commands();

-- =====================================================================
-- Membership helper
--
-- Policies on houses and house_members cannot query house_members directly
-- without recursing through its own RLS. A security-definer function reads it
-- once, outside RLS, and every policy calls that instead.
-- =====================================================================

create or replace function is_house_member(p_house uuid) returns boolean
language sql security definer stable set search_path = public, pg_temp as $$
    select exists (
        select 1 from house_members
         where house_id = p_house and user_id = auth.uid()
    );
$$;

create or replace function is_house_owner(p_house uuid) returns boolean
language sql security definer stable set search_path = public, pg_temp as $$
    select exists (
        select 1 from houses
         where id = p_house and owner_id = auth.uid()
    );
$$;

-- =====================================================================
-- Row level security
--
-- Nothing in this schema is readable with the anon key alone. Every policy is
-- granted to `authenticated` and keyed on the caller's own user id.
-- =====================================================================

alter table houses        enable row level security;
alter table house_members enable row level security;
alter table devices       enable row level security;
alter table speakers      enable row level security;
alter table playback      enable row level security;
alter table commands      enable row level security;

-- houses: members see it, only the owner renames or deletes it. Creation goes
-- through create_house() so that the membership row is never missing.
drop policy if exists houses_select on houses;
create policy houses_select on houses for select to authenticated
    using (is_house_member(id));

drop policy if exists houses_update on houses;
create policy houses_update on houses for update to authenticated
    using (owner_id = auth.uid()) with check (owner_id = auth.uid());

drop policy if exists houses_delete on houses;
create policy houses_delete on houses for delete to authenticated
    using (owner_id = auth.uid());

-- members: everyone in the house sees who else is in it. The owner can remove
-- anyone; anyone can remove themselves. Joining goes through join_house().
drop policy if exists members_select on house_members;
create policy members_select on house_members for select to authenticated
    using (is_house_member(house_id));

drop policy if exists members_delete on house_members;
create policy members_delete on house_members for delete to authenticated
    using (
        (user_id = auth.uid() or is_house_owner(house_id))
        -- The owner's own membership is load-bearing; deleting the house is the
        -- way to get rid of it.
        and house_members.role <> 'owner'
    );

-- devices: the owner's business only. Members do not need to know which Mac is
-- serving them, and the token hash should have the smallest audience possible.
drop policy if exists devices_select on devices;
create policy devices_select on devices for select to authenticated
    using (is_house_owner(house_id));

drop policy if exists devices_delete on devices;
create policy devices_delete on devices for delete to authenticated
    using (is_house_owner(house_id));

-- speakers and playback: members read, nobody writes. The Mac agent writes
-- through agent_publish(), which is security definer and bypasses these.
drop policy if exists speakers_select on speakers;
create policy speakers_select on speakers for select to authenticated
    using (is_house_member(house_id));

drop policy if exists playback_select on playback;
create policy playback_select on playback for select to authenticated
    using (is_house_member(house_id));

-- commands: members queue instructions and cannot read the queue back.
drop policy if exists commands_insert on commands;
create policy commands_insert on commands for insert to authenticated
    with check (is_house_member(house_id));

-- =====================================================================
-- Website RPCs (called as the signed-in user)
-- =====================================================================

-- Create a house, join yourself to it as owner, and seed its playback row so
-- the control page has something to render before the Mac ever connects.
create or replace function create_house(p_name text) returns houses
language plpgsql security definer set search_path = public, pg_temp as $$
declare
    v_house houses;
begin
    if auth.uid() is null then
        raise exception 'Not signed in';
    end if;
    if btrim(coalesce(p_name, '')) = '' then
        raise exception 'A house needs a name';
    end if;

    insert into houses (owner_id, name) values (auth.uid(), btrim(p_name))
    returning * into v_house;

    insert into house_members (house_id, user_id, role)
    values (v_house.id, auth.uid(), 'owner');

    insert into playback (house_id) values (v_house.id);

    return v_house;
end;
$$;

-- Accept an invite link. Returns the house so the page can redirect straight
-- into it. Idempotent: following your own link again is not an error.
-- Returns the composite `houses` row rather than named output columns. Output
-- parameters are in scope for the whole body, so a column named house_id would
-- make the ON CONFLICT clause below ambiguous and the join would never happen.
create or replace function join_house(p_code text) returns houses
language plpgsql security definer set search_path = public, pg_temp as $$
declare
    v_house houses;
begin
    if auth.uid() is null then
        raise exception 'Not signed in';
    end if;

    select * into v_house from houses where invite_code = p_code;
    if v_house.id is null then
        raise exception 'That invite link is not valid any more';
    end if;

    insert into house_members (house_id, user_id, role)
    values (v_house.id, auth.uid(), 'member')
    on conflict (house_id, user_id) do nothing;

    return v_house;
end;
$$;

-- Invalidate every link handed out so far and return the new one. Existing
-- members keep their access.
create or replace function rotate_invite_code(p_house uuid) returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare
    v_code text;
begin
    if not is_house_owner(p_house) then
        raise exception 'Only the owner can change the invite link';
    end if;

    update houses
       set invite_code = translate(encode(extensions.gen_random_bytes(9), 'base64'), '+/', '-_')
     where id = p_house
    returning invite_code into v_code;

    return v_code;
end;
$$;

-- Mint a token for a Mac. The plaintext is returned once, here, and cannot be
-- recovered afterwards — only the hash is kept.
create or replace function create_device(p_house uuid, p_name text default 'Mac')
returns text
language plpgsql security definer set search_path = public, pg_temp as $$
declare
    v_token text;
begin
    if not is_house_owner(p_house) then
        raise exception 'Only the owner can set up the Mac for a house';
    end if;

    v_token := 'ms_' || translate(
        encode(extensions.gen_random_bytes(32), 'base64'), '+/=', '-_');

    insert into devices (house_id, name, token_hash)
    values (p_house, coalesce(nullif(btrim(p_name), ''), 'Mac'),
            extensions.digest(v_token, 'sha256'));

    return v_token;
end;
$$;

-- =====================================================================
-- Agent RPCs (called with the anon key plus a device token)
--
-- These are the Mac's entire API surface. The token identifies the house, so
-- the agent cannot name a house it does not belong to, and there is no way to
-- widen these into a general read of the database.
-- =====================================================================

create or replace function device_house(p_token text) returns uuid
language plpgsql security definer set search_path = public, pg_temp as $$
declare
    v_house uuid;
begin
    update devices
       set last_seen_at = now()
     where token_hash = extensions.digest(p_token, 'sha256')
    returning house_id into v_house;

    if v_house is null then
        raise exception 'Unknown device token';
    end if;
    return v_house;
end;
$$;

-- Replace this house's published state in one round trip. `p_speakers` is the
-- full list, so speakers unpaired since the last call disappear.
create or replace function agent_publish(
    p_token    text,
    p_speakers jsonb,
    p_playback jsonb
) returns void
language plpgsql security definer set search_path = public, pg_temp as $$
declare
    v_house uuid := device_house(p_token);
begin
    insert into speakers (
        house_id, address, name, is_connected, is_selected, volume,
        supports_volume, is_muted, supports_mute, delay_ms, updated_at)
    select v_house, s.address, s.name, s.is_connected, s.is_selected, s.volume,
           s.supports_volume, s.is_muted, s.supports_mute, s.delay_ms, now()
      from jsonb_to_recordset(coalesce(p_speakers, '[]'::jsonb)) as s (
           address text, name text, is_connected boolean, is_selected boolean,
           volume real, supports_volume boolean, is_muted boolean,
           supports_mute boolean, delay_ms integer)
    on conflict (house_id, address) do update set
        name            = excluded.name,
        is_connected    = excluded.is_connected,
        is_selected     = excluded.is_selected,
        volume          = excluded.volume,
        supports_volume = excluded.supports_volume,
        is_muted        = excluded.is_muted,
        supports_mute   = excluded.supports_mute,
        delay_ms        = excluded.delay_ms,
        updated_at      = now();

    delete from speakers sp
     where sp.house_id = v_house
       and not exists (
           select 1
             from jsonb_to_recordset(coalesce(p_speakers, '[]'::jsonb))
               as s (address text)
            where s.address = sp.address);

    insert into playback (
        house_id, is_playing, track, artist, album, artwork_url,
        output_active, updated_at)
    select v_house, p.is_playing, p.track, p.artist, p.album, p.artwork_url,
           p.output_active, now()
      from jsonb_to_record(coalesce(p_playback, '{}'::jsonb)) as p (
           is_playing boolean, track text, artist text, album text,
           artwork_url text, output_active boolean)
    on conflict (house_id) do update set
        is_playing    = coalesce(excluded.is_playing, false),
        track         = excluded.track,
        artist        = excluded.artist,
        album         = excluded.album,
        artwork_url   = excluded.artwork_url,
        output_active = coalesce(excluded.output_active, false),
        updated_at    = now();
end;
$$;

-- Hand over everything queued since the last call and mark it consumed in the
-- same statement, so a command cannot be delivered twice.
create or replace function agent_poll(p_token text)
returns table (id bigint, kind text, address text, value double precision)
language plpgsql security definer set search_path = public, pg_temp as $$
declare
    v_house uuid := device_house(p_token);
begin
    return query
    with picked as (
        select c.id from commands c
         where c.house_id = v_house
           and c.consumed_at is null
         order by c.id
         limit 100
         for update skip locked
    ),
    drained as (
        update commands c
           set consumed_at = now()
          from picked p
         where c.id = p.id
        returning c.id, c.kind, c.address, c.value
    )
    select d.id, d.kind, d.address, d.value from drained d order by d.id;
end;
$$;

-- The agent authenticates with its token, not with a session, so these two are
-- reachable by the anon role. Nothing else in this schema is.
revoke all on function agent_publish(text, jsonb, jsonb) from public;
revoke all on function agent_poll(text) from public;
revoke all on function device_house(text) from public;
grant execute on function agent_publish(text, jsonb, jsonb) to anon, authenticated;
grant execute on function agent_poll(text) to anon, authenticated;

revoke all on function create_house(text) from public;
revoke all on function join_house(text) from public;
revoke all on function rotate_invite_code(uuid) from public;
revoke all on function create_device(uuid, text) from public;
grant execute on function create_house(text) to authenticated;
grant execute on function join_house(text) to authenticated;
grant execute on function rotate_invite_code(uuid) to authenticated;
grant execute on function create_device(uuid, text) to authenticated;

-- =====================================================================
-- Realtime
--
-- So the website sees speaker and playback changes pushed, not polled. Realtime
-- applies the same RLS policies as a normal read, so a subscriber only ever
-- receives rows for houses they belong to.
-- =====================================================================

do $$
begin
    if not exists (
        select 1 from pg_publication_tables
         where pubname = 'supabase_realtime' and tablename = 'speakers'
    ) then
        alter publication supabase_realtime add table speakers;
    end if;

    if not exists (
        select 1 from pg_publication_tables
         where pubname = 'supabase_realtime' and tablename = 'playback'
    ) then
        alter publication supabase_realtime add table playback;
    end if;
end $$;
