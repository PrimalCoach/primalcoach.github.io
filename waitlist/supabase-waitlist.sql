-- ============================================================
--  PrimalCoach Waitlist backend
--  Paste this whole file into the Supabase SQL editor and Run.
--  Safe to re-run (idempotent).
-- ============================================================

-- 1. Table -----------------------------------------------------
create table if not exists public.waitlist (
  id             uuid primary key default gen_random_uuid(),
  email          text not null unique,
  ref_code       text not null unique,
  referred_by    text,
  referral_count int  not null default 0,
  created_at     timestamptz not null default now()
);

create index if not exists waitlist_ref_code_idx     on public.waitlist (ref_code);
create index if not exists waitlist_rank_idx          on public.waitlist (referral_count desc, created_at asc);

-- 2. Lock the table down (only the RPC, which runs as definer, may touch it)
alter table public.waitlist enable row level security;
-- No policies = no direct anon access. All access goes through join_waitlist().

-- 3. Short, human-friendly referral code generator -------------
create or replace function public.gen_ref_code()
returns text language plpgsql as $$
declare
  alphabet constant text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; -- no ambiguous chars
  code text;
  i int;
begin
  loop
    code := '';
    for i in 1..6 loop
      code := code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    exit when not exists (select 1 from public.waitlist where ref_code = code);
  end loop;
  return code;
end $$;

-- 4. The public RPC --------------------------------------------
--    Returns: { position, ref_code, referrals, total, already }
create or replace function public.join_waitlist(p_email text, p_ref text default null)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email     text := lower(trim(p_email));
  v_row       public.waitlist;
  v_position  int;
  v_total     int;
  v_already   boolean := false;
begin
  if v_email is null or v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    raise exception 'invalid_email';
  end if;

  -- Existing signup?
  select * into v_row from public.waitlist where email = v_email;

  if found then
    v_already := true;
  else
    -- New signup
    insert into public.waitlist (email, ref_code, referred_by)
    values (v_email, public.gen_ref_code(), nullif(upper(trim(p_ref)), ''))
    returning * into v_row;

    -- Credit the referrer (if the code exists and isn't self)
    if v_row.referred_by is not null then
      update public.waitlist
         set referral_count = referral_count + 1
       where ref_code = v_row.referred_by
         and email <> v_email;
    end if;
  end if;

  select count(*) into v_total from public.waitlist;

  -- Rank: more referrals first, then earlier signups. 1-based.
  select count(*) + 1 into v_position
    from public.waitlist w
   where (w.referral_count >  v_row.referral_count)
      or (w.referral_count =  v_row.referral_count and w.created_at < v_row.created_at);

  return json_build_object(
    'position',  v_position,
    'ref_code',  v_row.ref_code,
    'referrals', v_row.referral_count,
    'total',     v_total,
    'already',   v_already
  );
end $$;

-- 5. Expose only the RPC to the public anon/auth roles ----------
revoke all on function public.join_waitlist(text, text) from public;
grant execute on function public.join_waitlist(text, text) to anon, authenticated;

-- Done. Test it:
--   select public.join_waitlist('you@example.com', null);
