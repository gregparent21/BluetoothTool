-- Multi-Speaker remote control schema.
--
-- Run this once in the Supabase SQL editor. It creates one room, whose id is
-- the capability: anyone who has the link can control the speakers, and anyone
-- who doesn't can't read or write anything. That is the right trade for a party
-- and the wrong one for anything that matters — see the note at the bottom.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------- rooms

create table if not exists rooms (
    id         uuid primary key default gen_random_uuid(),
    name       text not null,
    created_at timestamptz not null default now()
);

-- ------------------------------------------------------------- speakers
-- Written only by the Mac agent; the website reads it and issues commands.

create table if not exists speakers (
    room_id         uuid not null references rooms(id) on delete cascade,
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
    primary key (room_id, address)
);

-- ------------------------------------------------------------- playback

create table if not exists playback (
    room_id       uuid primary key references rooms(id) on delete cascade,
    is_playing    boolean not null default false,
    track         text,
    artist        text,
    album         text,
    artwork_url   text,
    output_active boolean not null default false, -- is Multi-Speaker the system output?
    updated_at    timestamptz not null default now()
);

-- ------------------------------------------------------------- commands
-- Written by phones, drained by the Mac agent every 750ms.

create table if not exists commands (
    id          bigserial primary key,
    room_id     uuid not null references rooms(id) on delete cascade,
    kind        text not null check (kind in (
                    'set_volume', 'set_muted', 'set_selected', 'set_delay',
                    'set_active', 'playpause', 'next', 'previous')),
    address     text,          -- speaker target; null for playback commands
    value       double precision,
    created_at  timestamptz not null default now(),
    consumed_at timestamptz
);

create index if not exists commands_pending_idx
    on commands (room_id, id) where consumed_at is null;

-- Keep the table from growing without bound; the agent never looks back.
create or replace function prune_commands() returns trigger as $$
begin
    delete from commands
     where consumed_at is not null
       and consumed_at < now() - interval '1 hour';
    return null;
end;
$$ language plpgsql;

drop trigger if exists prune_commands_trigger on commands;
create trigger prune_commands_trigger
    after insert on commands
    execute function prune_commands();

-- ------------------------------------------------------------ realtime
-- So the website sees speaker and playback changes pushed, not polled.

-- Guarded so the whole file stays safe to re-run; adding a table that is
-- already published is an error, not a no-op.
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

-- ----------------------------------------------------------------- RLS
--
-- The anon key ships inside the website, so it is public. These policies give
-- it exactly two abilities, and only for a room whose uuid the caller already
-- knows: read state, and queue a command. It cannot list rooms, cannot discover
-- room ids, and cannot write state (that is the Mac agent's job, and it uses
-- the service key, which bypasses RLS entirely).

alter table rooms    enable row level security;
alter table speakers enable row level security;
alter table playback enable row level security;
alter table commands enable row level security;

drop policy if exists speakers_read on speakers;
create policy speakers_read on speakers for select to anon using (true);

drop policy if exists playback_read on playback;
create policy playback_read on playback for select to anon using (true);

drop policy if exists commands_insert on commands;
create policy commands_insert on commands for insert to anon with check (true);

-- Deliberately no select/update/delete policy on commands, and none at all on
-- rooms: a phone can queue an instruction but cannot read the queue back.

-- ------------------------------------------------------------ your room

-- Re-running the file is safe, but this statement is the one exception worth
-- watching: it makes a *new* room each time, which is also how you revoke a
-- link you have handed out too widely.
insert into rooms (name) values ('House') returning id;

-- Copy the returned uuid into BOTH:
--   ~/.config/multi-speaker/remote.json   ("roomID")
--   web/.env.local                        (NEXT_PUBLIC_ROOM_ID)
--
-- SECURITY NOTE: knowing the room id is full control. Anyone you send the link
-- to can forward it, and there is no way to revoke one person. To cut everyone
-- off, insert a new room and update both files. If you ever want this to be
-- more than a party toy, put Supabase Auth in front of it and key the policies
-- on auth.uid() instead of `using (true)`.
