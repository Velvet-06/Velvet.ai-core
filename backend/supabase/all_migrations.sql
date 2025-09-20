/**
      ____                 _
     |  _ \               (_)
     | |_) | __ _ ___  ___ _ _   _ _ __ ___  _ __
     |  _ < / _` / __|/ _ \ | | | | '_ ` _ \| '_ \
     | |_) | (_| \__ \  __/ | |_| | | | | | | |_) |
     |____/ \__,_|___/\___| |\__,_|_| |_| |_| .__/
                         _/ |               | |
                        |__/                |_|

     Basejump is a starter kit for building SaaS products on top of Supabase.
     Learn more at https://usebasejump.com
 */


/**
  * -------------------------------------------------------
  * Section - Basejump schema setup and utility functions
  * -------------------------------------------------------
 */

-- revoke execution by default from public
ALTER DEFAULT PRIVILEGES REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA PUBLIC REVOKE EXECUTE ON FUNCTIONS FROM anon, authenticated;

-- Create basejump schema
CREATE SCHEMA IF NOT EXISTS basejump;
GRANT USAGE ON SCHEMA basejump to authenticated;
GRANT USAGE ON SCHEMA basejump to service_role;

/**
  * -------------------------------------------------------
  * Section - Enums
  * -------------------------------------------------------
 */

/**
 * Invitation types are either email or link. Email invitations are sent to
 * a single user and can only be claimed once.  Link invitations can be used multiple times
 * Both expire after 24 hours
 */
DO
$$
    BEGIN
        -- check it account_role already exists on basejump schema
        IF NOT EXISTS(SELECT 1
                      FROM pg_type t
                               JOIN pg_namespace n ON n.oid = t.typnamespace
                      WHERE t.typname = 'invitation_type'
                        AND n.nspname = 'basejump') THEN
            CREATE TYPE basejump.invitation_type AS ENUM ('one_time', '24_hour');
        end if;
    end;
$$;

/**
  * -------------------------------------------------------
  * Section - Basejump settings
  * -------------------------------------------------------
 */

CREATE TABLE IF NOT EXISTS basejump.config
(
    enable_team_accounts            boolean default true,
    enable_personal_account_billing boolean default true,
    enable_team_account_billing     boolean default true,
    billing_provider                text    default 'stripe'
);

-- create config row
INSERT INTO basejump.config (enable_team_accounts, enable_personal_account_billing, enable_team_account_billing)
VALUES (true, true, true);

-- enable select on the config table
GRANT SELECT ON basejump.config TO authenticated, service_role;

-- enable RLS on config
ALTER TABLE basejump.config
    ENABLE ROW LEVEL SECURITY;

create policy "Basejump settings can be read by authenticated users" on basejump.config
    for select
    to authenticated
    using (
    true
    );

/**
  * -------------------------------------------------------
  * Section - Basejump utility functions
  * -------------------------------------------------------
 */

/**
  basejump.get_config()
  Get the full config object to check basejump settings
  This is not accessible from the outside, so can only be used inside postgres functions
 */
CREATE OR REPLACE FUNCTION basejump.get_config()
    RETURNS json AS
$$
DECLARE
    result RECORD;
BEGIN
    SELECT * from basejump.config limit 1 into result;
    return row_to_json(result);
END;
$$ LANGUAGE plpgsql;

grant execute on function basejump.get_config() to authenticated, service_role;


/**
  basejump.is_set("field_name")
  Check a specific boolean config value
 */
CREATE OR REPLACE FUNCTION basejump.is_set(field_name text)
    RETURNS boolean AS
$$
DECLARE
    result BOOLEAN;
BEGIN
    execute format('select %I from basejump.config limit 1', field_name) into result;
    return result;
END;
$$ LANGUAGE plpgsql;

grant execute on function basejump.is_set(text) to authenticated;


/**
  * Automatic handling for maintaining created_at and updated_at timestamps
  * on tables
 */
CREATE OR REPLACE FUNCTION basejump.trigger_set_timestamps()
    RETURNS TRIGGER AS
$$
BEGIN
    if TG_OP = 'INSERT' then
        NEW.created_at = now();
        NEW.updated_at = now();
    else
        NEW.updated_at = now();
        NEW.created_at = OLD.created_at;
    end if;
    RETURN NEW;
END
$$ LANGUAGE plpgsql;


/**
  * Automatic handling for maintaining created_by and updated_by timestamps
  * on tables
 */
CREATE OR REPLACE FUNCTION basejump.trigger_set_user_tracking()
    RETURNS TRIGGER AS
$$
BEGIN
    if TG_OP = 'INSERT' then
        NEW.created_by = auth.uid();
        NEW.updated_by = auth.uid();
    else
        NEW.updated_by = auth.uid();
        NEW.created_by = OLD.created_by;
    end if;
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

/**
  basejump.generate_token(length)
  Generates a secure token - used internally for invitation tokens
  but could be used elsewhere.  Check out the invitations table for more info on
  how it's used
 */
CREATE OR REPLACE FUNCTION basejump.generate_token(length int)
    RETURNS text AS
$$
select regexp_replace(replace(
                              replace(replace(replace(encode(gen_random_bytes(length)::bytea, 'base64'), '/', ''), '+',
                                              ''), '\', ''),
                              '=',
                              ''), E'[\\n\\r]+', '', 'g');
$$ LANGUAGE sql;

grant execute on function basejump.generate_token(int) to authenticated;
/**
      ____                 _
     |  _ \               (_)
     | |_) | __ _ ___  ___ _ _   _ _ __ ___  _ __
     |  _ < / _` / __|/ _ \ | | | | '_ ` _ \| '_ \
     | |_) | (_| \__ \  __/ | |_| | | | | | | |_) |
     |____/ \__,_|___/\___| |\__,_|_| |_| |_| .__/
                         _/ |               | |
                        |__/                |_|

     Basejump is a starter kit for building SaaS products on top of Supabase.
     Learn more at https://usebasejump.com
 */

/**
  * -------------------------------------------------------
  * Section - Accounts
  * -------------------------------------------------------
 */

/**
 * Account roles allow you to provide permission levels to users
 * when they're acting on an account.  By default, we provide
 * "owner" and "member".  The only distinction is that owners can
 * also manage billing and invite/remove account members.
 */
DO
$$
    BEGIN
        -- check it account_role already exists on basejump schema
        IF NOT EXISTS(SELECT 1
                      FROM pg_type t
                               JOIN pg_namespace n ON n.oid = t.typnamespace
                      WHERE t.typname = 'account_role'
                        AND n.nspname = 'basejump') THEN
            CREATE TYPE basejump.account_role AS ENUM ('owner', 'member');
        end if;
    end;
$$;

/**
 * Accounts are the primary grouping for most objects within
 * the system. They have many users, and all billing is connected to
 * an account.
 */
CREATE TABLE IF NOT EXISTS basejump.accounts
(
    id                    uuid unique                NOT NULL DEFAULT extensions.uuid_generate_v4(),
    -- defaults to the user who creates the account
    -- this user cannot be removed from an account without changing
    -- the primary owner first
    primary_owner_user_id uuid references auth.users not null default auth.uid(),
    -- Account name
    name                  text,
    slug                  text unique,
    personal_account      boolean                             default false not null,
    updated_at            timestamp with time zone,
    created_at            timestamp with time zone,
    created_by            uuid references auth.users,
    updated_by            uuid references auth.users,
    private_metadata      jsonb                               default '{}'::jsonb,
    public_metadata       jsonb                               default '{}'::jsonb,
    PRIMARY KEY (id)
);

-- constraint that conditionally allows nulls on the slug ONLY if personal_account is true
-- remove this if you want to ignore accounts slugs entirely
ALTER TABLE basejump.accounts
    ADD CONSTRAINT basejump_accounts_slug_null_if_personal_account_true CHECK (
            (personal_account = true AND slug is null)
            OR (personal_account = false AND slug is not null)
        );

-- Open up access to accounts
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE basejump.accounts TO authenticated, service_role;

/**
 * We want to protect some fields on accounts from being updated
 * Specifically the primary owner user id and account id.
 * primary_owner_user_id should be updated using the dedicated function
 */
CREATE OR REPLACE FUNCTION basejump.protect_account_fields()
    RETURNS TRIGGER AS
$$
BEGIN
    IF current_user IN ('authenticated', 'anon') THEN
        -- these are protected fields that users are not allowed to update themselves
        -- platform admins should be VERY careful about updating them as well.
        if NEW.id <> OLD.id
            OR NEW.personal_account <> OLD.personal_account
            OR NEW.primary_owner_user_id <> OLD.primary_owner_user_id
        THEN
            RAISE EXCEPTION 'You do not have permission to update this field';
        end if;
    end if;

    RETURN NEW;
END
$$ LANGUAGE plpgsql;

-- trigger to protect account fields
CREATE TRIGGER basejump_protect_account_fields
    BEFORE UPDATE
    ON basejump.accounts
    FOR EACH ROW
EXECUTE FUNCTION basejump.protect_account_fields();

-- convert any character in the slug that's not a letter, number, or dash to a dash on insert/update for accounts
CREATE OR REPLACE FUNCTION basejump.slugify_account_slug()
    RETURNS TRIGGER AS
$$
BEGIN
    if NEW.slug is not null then
        NEW.slug = lower(regexp_replace(NEW.slug, '[^a-zA-Z0-9-]+', '-', 'g'));
    end if;

    RETURN NEW;
END
$$ LANGUAGE plpgsql;

-- trigger to slugify the account slug
CREATE TRIGGER basejump_slugify_account_slug
    BEFORE INSERT OR UPDATE
    ON basejump.accounts
    FOR EACH ROW
EXECUTE FUNCTION basejump.slugify_account_slug();

-- enable RLS for accounts
alter table basejump.accounts
    enable row level security;

-- protect the timestamps
CREATE TRIGGER basejump_set_accounts_timestamp
    BEFORE INSERT OR UPDATE
    ON basejump.accounts
    FOR EACH ROW
EXECUTE PROCEDURE basejump.trigger_set_timestamps();

-- set the user tracking
CREATE TRIGGER basejump_set_accounts_user_tracking
    BEFORE INSERT OR UPDATE
    ON basejump.accounts
    FOR EACH ROW
EXECUTE PROCEDURE basejump.trigger_set_user_tracking();

/**
  * Account users are the users that are associated with an account.
  * They can be invited to join the account, and can have different roles.
  * The system does not enforce any permissions for roles, other than restricting
  * billing and account membership to only owners
 */
create table if not exists basejump.account_user
(
    -- id of the user in the account
    user_id      uuid references auth.users on delete cascade        not null,
    -- id of the account the user is in
    account_id   uuid references basejump.accounts on delete cascade not null,
    -- role of the user in the account
    account_role basejump.account_role                               not null,
    constraint account_user_pkey primary key (user_id, account_id)
);

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE basejump.account_user TO authenticated, service_role;


-- enable RLS for account_user
alter table basejump.account_user
    enable row level security;

/**
  * When an account gets created, we want to insert the current user as the first
  * owner
 */
create or replace function basejump.add_current_user_to_new_account()
    returns trigger
    language plpgsql
    security definer
    set search_path = public
as
$$
begin
    if new.primary_owner_user_id = auth.uid() then
        insert into basejump.account_user (account_id, user_id, account_role)
        values (NEW.id, auth.uid(), 'owner');
    end if;
    return NEW;
end;
$$;

-- trigger the function whenever a new account is created
CREATE TRIGGER basejump_add_current_user_to_new_account
    AFTER INSERT
    ON basejump.accounts
    FOR EACH ROW
EXECUTE FUNCTION basejump.add_current_user_to_new_account();

/**
  * When a user signs up, we need to create a personal account for them
  * and add them to the account_user table so they can act on it
 */
create or replace function basejump.run_new_user_setup()
    returns trigger
    language plpgsql
    security definer
    set search_path = public
as
$$
declare
    first_account_id    uuid;
    generated_user_name text;
begin

    -- first we setup the user profile
    -- TODO: see if we can get the user's name from the auth.users table once we learn how oauth works
    if new.email IS NOT NULL then
        generated_user_name := split_part(new.email, '@', 1);
    end if;
    -- create the new users's personal account
    insert into basejump.accounts (name, primary_owner_user_id, personal_account, id)
    values (generated_user_name, NEW.id, true, NEW.id)
    returning id into first_account_id;

    -- add them to the account_user table so they can act on it
    insert into basejump.account_user (account_id, user_id, account_role)
    values (first_account_id, NEW.id, 'owner');

    return NEW;
end;
$$;

-- trigger the function every time a user is created
create trigger on_auth_user_created
    after insert
    on auth.users
    for each row
execute procedure basejump.run_new_user_setup();

/**
  * -------------------------------------------------------
  * Section - Account permission utility functions
  * -------------------------------------------------------
  * These functions are stored on the basejump schema, and useful for things like
  * generating RLS policies
 */

/**
  * Returns true if the current user has the pass in role on the passed in account
  * If no role is sent, will return true if the user is a member of the account
  * NOTE: This is an inefficient function when used on large query sets. You should reach for the get_accounts_with_role and lookup
  * the account ID in those cases.
 */
create or replace function basejump.has_role_on_account(account_id uuid, account_role basejump.account_role default null)
    returns boolean
    language sql
    security definer
    set search_path = public
as
$$
select exists(
               select 1
               from basejump.account_user wu
               where wu.user_id = auth.uid()
                 and wu.account_id = has_role_on_account.account_id
                 and (
                           wu.account_role = has_role_on_account.account_role
                       or has_role_on_account.account_role is null
                   )
           );
$$;

grant execute on function basejump.has_role_on_account(uuid, basejump.account_role) to authenticated, anon, public, service_role;


/**
  * Returns account_ids that the current user is a member of. If you pass in a role,
  * it'll only return accounts that the user is a member of with that role.
  */
create or replace function basejump.get_accounts_with_role(passed_in_role basejump.account_role default null)
    returns setof uuid
    language sql
    security definer
    set search_path = public
as
$$
select account_id
from basejump.account_user wu
where wu.user_id = auth.uid()
  and (
            wu.account_role = passed_in_role
        or passed_in_role is null
    );
$$;

grant execute on function basejump.get_accounts_with_role(basejump.account_role) to authenticated;

/**
  * -------------------------
  * Section - RLS Policies
  * -------------------------
  * This is where we define access to tables in the basejump schema
 */

create policy "users can view their own account_users" on basejump.account_user
    for select
    to authenticated
    using (
    user_id = auth.uid()
    );

create policy "users can view their teammates" on basejump.account_user
    for select
    to authenticated
    using (
    basejump.has_role_on_account(account_id) = true
    );

create policy "Account users can be deleted by owners except primary account owner" on basejump.account_user
    for delete
    to authenticated
    using (
        (basejump.has_role_on_account(account_id, 'owner') = true)
        AND
        user_id != (select primary_owner_user_id
                    from basejump.accounts
                    where account_id = accounts.id)
    );

create policy "Accounts are viewable by members" on basejump.accounts
    for select
    to authenticated
    using (
    basejump.has_role_on_account(id) = true
    );

-- Primary owner should always have access to the account
create policy "Accounts are viewable by primary owner" on basejump.accounts
    for select
    to authenticated
    using (
    primary_owner_user_id = auth.uid()
    );

create policy "Team accounts can be created by any user" on basejump.accounts
    for insert
    to authenticated
    with check (
            basejump.is_set('enable_team_accounts') = true
        and personal_account = false
    );


create policy "Accounts can be edited by owners" on basejump.accounts
    for update
    to authenticated
    using (
    basejump.has_role_on_account(id, 'owner') = true
    );

/**
  * -------------------------------------------------------
  * Section - Public functions
  * -------------------------------------------------------
  * Each of these functions exists in the public name space because they are accessible
  * via the API.  it is the primary way developers can interact with Basejump accounts
 */

/**
* Returns the account_id for a given account slug
*/

create or replace function public.get_account_id(slug text)
    returns uuid
    language sql
as
$$
select id
from basejump.accounts
where slug = get_account_id.slug;
$$;

grant execute on function public.get_account_id(text) to authenticated, service_role;

/**
 * Returns the current user's role within a given account_id
*/
create or replace function public.current_user_account_role(account_id uuid)
    returns jsonb
    language plpgsql
as
$$
DECLARE
    response jsonb;
BEGIN

    select jsonb_build_object(
                   'account_role', wu.account_role,
                   'is_primary_owner', a.primary_owner_user_id = auth.uid(),
                   'is_personal_account', a.personal_account
               )
    into response
    from basejump.account_user wu
             join basejump.accounts a on a.id = wu.account_id
    where wu.user_id = auth.uid()
      and wu.account_id = current_user_account_role.account_id;

    -- if the user is not a member of the account, throw an error
    if response ->> 'account_role' IS NULL then
        raise exception 'Not found';
    end if;

    return response;
END
$$;

grant execute on function public.current_user_account_role(uuid) to authenticated;

/**
  * Let's you update a users role within an account if you are an owner of that account
  **/
create or replace function public.update_account_user_role(account_id uuid, user_id uuid,
                                                           new_account_role basejump.account_role,
                                                           make_primary_owner boolean default false)
    returns void
    security definer
    set search_path = public
    language plpgsql
as
$$
declare
    is_account_owner         boolean;
    is_account_primary_owner boolean;
    changing_primary_owner   boolean;
begin
    -- check if the user is an owner, and if they are, allow them to update the role
    select basejump.has_role_on_account(update_account_user_role.account_id, 'owner') into is_account_owner;

    if not is_account_owner then
        raise exception 'You must be an owner of the account to update a users role';
    end if;

    -- check if the user being changed is the primary owner, if so its not allowed
    select primary_owner_user_id = auth.uid(), primary_owner_user_id = update_account_user_role.user_id
    into is_account_primary_owner, changing_primary_owner
    from basejump.accounts
    where id = update_account_user_role.account_id;

    if changing_primary_owner = true and is_account_primary_owner = false then
        raise exception 'You must be the primary owner of the account to change the primary owner';
    end if;

    update basejump.account_user au
    set account_role = new_account_role
    where au.account_id = update_account_user_role.account_id
      and au.user_id = update_account_user_role.user_id;

    if make_primary_owner = true then
        -- first we see if the current user is the owner, only they can do this
        if is_account_primary_owner = false then
            raise exception 'You must be the primary owner of the account to change the primary owner';
        end if;

        update basejump.accounts
        set primary_owner_user_id = update_account_user_role.user_id
        where id = update_account_user_role.account_id;
    end if;
end;
$$;

grant execute on function public.update_account_user_role(uuid, uuid, basejump.account_role, boolean) to authenticated;

/**
  Returns the current user's accounts
 */
create or replace function public.get_accounts()
    returns json
    language sql
as
$$
select coalesce(json_agg(
                        json_build_object(
                                'account_id', wu.account_id,
                                'account_role', wu.account_role,
                                'is_primary_owner', a.primary_owner_user_id = auth.uid(),
                                'name', a.name,
                                'slug', a.slug,
                                'personal_account', a.personal_account,
                                'created_at', a.created_at,
                                'updated_at', a.updated_at
                            )
                    ), '[]'::json)
from basejump.account_user wu
         join basejump.accounts a on a.id = wu.account_id
where wu.user_id = auth.uid();
$$;

grant execute on function public.get_accounts() to authenticated;

/**
  Returns a specific account that the current user has access to
 */
create or replace function public.get_account(account_id uuid)
    returns json
    language plpgsql
as
$$
BEGIN
    -- check if the user is a member of the account or a service_role user
    if current_user IN ('anon', 'authenticated') and
       (select current_user_account_role(get_account.account_id) ->> 'account_role' IS NULL) then
        raise exception 'You must be a member of an account to access it';
    end if;


    return (select json_build_object(
                           'account_id', a.id,
                           'account_role', wu.account_role,
                           'is_primary_owner', a.primary_owner_user_id = auth.uid(),
                           'name', a.name,
                           'slug', a.slug,
                           'personal_account', a.personal_account,
                           'billing_enabled', case
                                                  when a.personal_account = true then
                                                      config.enable_personal_account_billing
                                                  else
                                                      config.enable_team_account_billing
                               end,
                           'billing_status', bs.status,
                           'created_at', a.created_at,
                           'updated_at', a.updated_at,
                           'metadata', a.public_metadata
                       )
            from basejump.accounts a
                     left join basejump.account_user wu on a.id = wu.account_id and wu.user_id = auth.uid()
                     join basejump.config config on true
                     left join (select bs.account_id, status
                                from basejump.billing_subscriptions bs
                                where bs.account_id = get_account.account_id
                                order by created desc
                                limit 1) bs on bs.account_id = a.id
            where a.id = get_account.account_id);
END;
$$;

grant execute on function public.get_account(uuid) to authenticated, service_role;

/**
  Returns a specific account that the current user has access to
 */
create or replace function public.get_account_by_slug(slug text)
    returns json
    language plpgsql
as
$$
DECLARE
    internal_account_id uuid;
BEGIN
    select a.id
    into internal_account_id
    from basejump.accounts a
    where a.slug IS NOT NULL
      and a.slug = get_account_by_slug.slug;

    return public.get_account(internal_account_id);
END;
$$;

grant execute on function public.get_account_by_slug(text) to authenticated;

/**
  Returns the personal account for the current user
 */
create or replace function public.get_personal_account()
    returns json
    language plpgsql
as
$$
BEGIN
    return public.get_account(auth.uid());
END;
$$;

grant execute on function public.get_personal_account() to authenticated;

/**
  * Create an account
 */
create or replace function public.create_account(slug text default null, name text default null)
    returns json
    language plpgsql
as
$$
DECLARE
    new_account_id uuid;
BEGIN
    insert into basejump.accounts (slug, name)
    values (create_account.slug, create_account.name)
    returning id into new_account_id;

    return public.get_account(new_account_id);
EXCEPTION
    WHEN unique_violation THEN
        raise exception 'An account with that unique ID already exists';
END;
$$;

grant execute on function public.create_account(slug text, name text) to authenticated;

/**
  Update an account with passed in info. None of the info is required except for account ID.
  If you don't pass in a value for a field, it will not be updated.
  If you set replace_meta to true, the metadata will be replaced with the passed in metadata.
  If you set replace_meta to false, the metadata will be merged with the passed in metadata.
 */
create or replace function public.update_account(account_id uuid, slug text default null, name text default null,
                                                 public_metadata jsonb default null,
                                                 replace_metadata boolean default false)
    returns json
    language plpgsql
as
$$
BEGIN

    -- check if postgres role is service_role
    if current_user IN ('anon', 'authenticated') and
       not (select current_user_account_role(update_account.account_id) ->> 'account_role' = 'owner') then
        raise exception 'Only account owners can update an account';
    end if;

    update basejump.accounts accounts
    set slug            = coalesce(update_account.slug, accounts.slug),
        name            = coalesce(update_account.name, accounts.name),
        public_metadata = case
                              when update_account.public_metadata is null then accounts.public_metadata -- do nothing
                              when accounts.public_metadata IS NULL then update_account.public_metadata -- set metadata
                              when update_account.replace_metadata
                                  then update_account.public_metadata -- replace metadata
                              else accounts.public_metadata || update_account.public_metadata end -- merge metadata
    where accounts.id = update_account.account_id;

    return public.get_account(account_id);
END;
$$;

grant execute on function public.update_account(uuid, text, text, jsonb, boolean) to authenticated, service_role;

/**
  Returns a list of current account members. Only account owners can access this function.
  It's a security definer because it requries us to lookup personal_accounts for existing members so we can
  get their names.
 */
create or replace function public.get_account_members(account_id uuid, results_limit integer default 50,
                                                      results_offset integer default 0)
    returns json
    language plpgsql
    security definer
    set search_path = basejump
as
$$
BEGIN

    -- only account owners can access this function
    if (select public.current_user_account_role(get_account_members.account_id) ->> 'account_role' <> 'owner') then
        raise exception 'Only account owners can access this function';
    end if;

    return (select json_agg(
                           json_build_object(
                                   'user_id', wu.user_id,
                                   'account_role', wu.account_role,
                                   'name', p.name,
                                   'email', u.email,
                                   'is_primary_owner', a.primary_owner_user_id = wu.user_id
                               )
                       )
            from basejump.account_user wu
                     join basejump.accounts a on a.id = wu.account_id
                     join basejump.accounts p on p.primary_owner_user_id = wu.user_id and p.personal_account = true
                     join auth.users u on u.id = wu.user_id
            where wu.account_id = get_account_members.account_id
            limit coalesce(get_account_members.results_limit, 50) offset coalesce(get_account_members.results_offset, 0));
END;
$$;

grant execute on function public.get_account_members(uuid, integer, integer) to authenticated;

/**
  Allows an owner of the account to remove any member other than the primary owner
 */

create or replace function public.remove_account_member(account_id uuid, user_id uuid)
    returns void
    language plpgsql
as
$$
BEGIN
    -- only account owners can access this function
    if basejump.has_role_on_account(remove_account_member.account_id, 'owner') <> true then
        raise exception 'Only account owners can access this function';
    end if;

    delete
    from basejump.account_user wu
    where wu.account_id = remove_account_member.account_id
      and wu.user_id = remove_account_member.user_id;
END;
$$;

grant execute on function public.remove_account_member(uuid, uuid) to authenticated;
/**
  * -------------------------------------------------------
  * Section - Invitations
  * -------------------------------------------------------
 */

/**
  * Invitations are sent to users to join a account
  * They pre-define the role the user should have once they join
 */
create table if not exists basejump.invitations
(
    -- the id of the invitation
    id                 uuid unique                                              not null default extensions.uuid_generate_v4(),
    -- what role should invitation accepters be given in this account
    account_role       basejump.account_role                                    not null,
    -- the account the invitation is for
    account_id         uuid references basejump.accounts (id) on delete cascade not null,
    -- unique token used to accept the invitation
    token              text unique                                              not null default basejump.generate_token(30),
    -- who created the invitation
    invited_by_user_id uuid references auth.users                               not null,
    -- account name. filled in by a trigger
    account_name       text,
    -- when the invitation was last updated
    updated_at         timestamp with time zone,
    -- when the invitation was created
    created_at         timestamp with time zone,
    -- what type of invitation is this
    invitation_type    basejump.invitation_type                                 not null,
    primary key (id)
);

-- Open up access to invitations
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE basejump.invitations TO authenticated, service_role;

-- manage timestamps
CREATE TRIGGER basejump_set_invitations_timestamp
    BEFORE INSERT OR UPDATE
    ON basejump.invitations
    FOR EACH ROW
EXECUTE FUNCTION basejump.trigger_set_timestamps();

/**
  * This funciton fills in account info and inviting user email
  * so that the recipient can get more info about the invitation prior to
  * accepting.  It allows us to avoid complex permissions on accounts
 */
CREATE OR REPLACE FUNCTION basejump.trigger_set_invitation_details()
    RETURNS TRIGGER AS
$$
BEGIN
    NEW.invited_by_user_id = auth.uid();
    NEW.account_name = (select name from basejump.accounts where id = NEW.account_id);
    RETURN NEW;
END
$$ LANGUAGE plpgsql;

CREATE TRIGGER basejump_trigger_set_invitation_details
    BEFORE INSERT
    ON basejump.invitations
    FOR EACH ROW
EXECUTE FUNCTION basejump.trigger_set_invitation_details();

-- enable RLS on invitations
alter table basejump.invitations
    enable row level security;

/**
  * -------------------------
  * Section - RLS Policies
  * -------------------------
  * This is where we define access to tables in the basejump schema
 */

 create policy "Invitations viewable by account owners" on basejump.invitations
    for select
    to authenticated
    using (
            created_at > (now() - interval '24 hours')
        and
            basejump.has_role_on_account(account_id, 'owner') = true
    );


create policy "Invitations can be created by account owners" on basejump.invitations
    for insert
    to authenticated
    with check (
    -- team accounts should be enabled
            basejump.is_set('enable_team_accounts') = true
        -- this should not be a personal account
        and (SELECT personal_account
             FROM basejump.accounts
             WHERE id = account_id) = false
        -- the inserting user should be an owner of the account
        and
            (basejump.has_role_on_account(account_id, 'owner') = true)
    );

create policy "Invitations can be deleted by account owners" on basejump.invitations
    for delete
    to authenticated
    using (
    basejump.has_role_on_account(account_id, 'owner') = true
    );



/**
  * -------------------------------------------------------
  * Section - Public functions
  * -------------------------------------------------------
  * Each of these functions exists in the public name space because they are accessible
  * via the API.  it is the primary way developers can interact with Basejump accounts
 */


/**
  Returns a list of currently active invitations for a given account
 */

create or replace function public.get_account_invitations(account_id uuid, results_limit integer default 25,
                                                          results_offset integer default 0)
    returns json
    language plpgsql
as
$$
BEGIN
    -- only account owners can access this function
    if (select public.current_user_account_role(get_account_invitations.account_id) ->> 'account_role' <> 'owner') then
        raise exception 'Only account owners can access this function';
    end if;

    return (select json_agg(
                           json_build_object(
                                   'account_role', i.account_role,
                                   'created_at', i.created_at,
                                   'invitation_type', i.invitation_type,
                                   'invitation_id', i.id
                               )
                       )
            from basejump.invitations i
            where i.account_id = get_account_invitations.account_id
              and i.created_at > now() - interval '24 hours'
            limit coalesce(get_account_invitations.results_limit, 25) offset coalesce(get_account_invitations.results_offset, 0));
END;
$$;

grant execute on function public.get_account_invitations(uuid, integer, integer) to authenticated;


/**
  * Allows a user to accept an existing invitation and join a account
  * This one exists in the public schema because we want it to be called
  * using the supabase rpc method
 */
create or replace function public.accept_invitation(lookup_invitation_token text)
    returns jsonb
    language plpgsql
    security definer set search_path = public, basejump
as
$$
declare
    lookup_account_id       uuid;
    declare new_member_role basejump.account_role;
    lookup_account_slug     text;
begin
    select i.account_id, i.account_role, a.slug
    into lookup_account_id, new_member_role, lookup_account_slug
    from basejump.invitations i
             join basejump.accounts a on a.id = i.account_id
    where i.token = lookup_invitation_token
      and i.created_at > now() - interval '24 hours';

    if lookup_account_id IS NULL then
        raise exception 'Invitation not found';
    end if;

    if lookup_account_id is not null then
        -- we've validated the token is real, so grant the user access
        insert into basejump.account_user (account_id, user_id, account_role)
        values (lookup_account_id, auth.uid(), new_member_role);
        -- email types of invitations are only good for one usage
        delete from basejump.invitations where token = lookup_invitation_token and invitation_type = 'one_time';
    end if;
    return json_build_object('account_id', lookup_account_id, 'account_role', new_member_role, 'slug',
                             lookup_account_slug);
EXCEPTION
    WHEN unique_violation THEN
        raise exception 'You are already a member of this account';
end;
$$;

grant execute on function public.accept_invitation(text) to authenticated;


/**
  * Allows a user to lookup an existing invitation and join a account
  * This one exists in the public schema because we want it to be called
  * using the supabase rpc method
 */
create or replace function public.lookup_invitation(lookup_invitation_token text)
    returns json
    language plpgsql
    security definer set search_path = public, basejump
as
$$
declare
    name              text;
    invitation_active boolean;
begin
    select account_name,
           case when id IS NOT NULL then true else false end as active
    into name, invitation_active
    from basejump.invitations
    where token = lookup_invitation_token
      and created_at > now() - interval '24 hours'
    limit 1;
    return json_build_object('active', coalesce(invitation_active, false), 'account_name', name);
end;
$$;

grant execute on function public.lookup_invitation(text) to authenticated;


/**
  Allows a user to create a new invitation if they are an owner of an account
 */
create or replace function public.create_invitation(account_id uuid, account_role basejump.account_role,
                                                    invitation_type basejump.invitation_type)
    returns json
    language plpgsql
as
$$
declare
    new_invitation basejump.invitations;
begin
    insert into basejump.invitations (account_id, account_role, invitation_type, invited_by_user_id)
    values (account_id, account_role, invitation_type, auth.uid())
    returning * into new_invitation;

    return json_build_object('token', new_invitation.token);
end
$$;

grant execute on function public.create_invitation(uuid, basejump.account_role, basejump.invitation_type) to authenticated;

/**
  Allows an owner to delete an existing invitation
 */

create or replace function public.delete_invitation(invitation_id uuid)
    returns void
    language plpgsql
as
$$
begin
    -- verify account owner for the invitation
    if basejump.has_role_on_account(
               (select account_id from basejump.invitations where id = delete_invitation.invitation_id), 'owner') <>
       true then
        raise exception 'Only account owners can delete invitations';
    end if;

    delete from basejump.invitations where id = delete_invitation.invitation_id;
end
$$;

grant execute on function public.delete_invitation(uuid) to authenticated;
/**
  * -------------------------------------------------------
  * Section - Billing
  * -------------------------------------------------------
 */

/**
* Subscription Status
* Tracks the current status of the account subscription
*/
DO
$$
    BEGIN
        IF NOT EXISTS(SELECT 1
                      FROM pg_type t
                               JOIN pg_namespace n ON n.oid = t.typnamespace
                      WHERE t.typname = 'subscription_status'
                        AND n.nspname = 'basejump') THEN
            create type basejump.subscription_status as enum (
                'trialing',
                'active',
                'canceled',
                'incomplete',
                'incomplete_expired',
                'past_due',
                'unpaid'
                );
        end if;
    end;
$$;


/**
 * Billing customer
 * This is a private table that contains a mapping of user IDs to your billing providers IDs
 */
create table if not exists basejump.billing_customers
(
    -- UUID from auth.users
    account_id uuid references basejump.accounts (id) on delete cascade not null,
    -- The user's customer ID in Stripe. User must not be able to update this.
    id         text primary key,
    -- The email address the customer wants to use for invoicing
    email      text,
    -- The active status of a customer
    active     boolean,
    -- The billing provider the customer is using
    provider   text
);

-- Open up access to billing_customers
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE basejump.billing_customers TO service_role;
GRANT SELECT ON TABLE basejump.billing_customers TO authenticated;


-- enable RLS for billing_customers
alter table
    basejump.billing_customers
    enable row level security;

/**
  * Billing subscriptions
  * This is a private table that contains a mapping of account IDs to your billing providers subscription IDs
 */
create table if not exists basejump.billing_subscriptions
(
    -- Subscription ID from Stripe, e.g. sub_1234.
    id                   text primary key,
    account_id           uuid references basejump.accounts (id) on delete cascade          not null,
    billing_customer_id  text references basejump.billing_customers (id) on delete cascade not null,
    -- The status of the subscription object, one of subscription_status type above.
    status               basejump.subscription_status,
    -- Set of key-value pairs, used to store additional information about the object in a structured format.
    metadata             jsonb,
    -- ID of the price that created this subscription.
    price_id             text,
    plan_name            text,
    -- Quantity multiplied by the unit amount of the price creates the amount of the subscription. Can be used to charge multiple seats.
    quantity             integer,
    -- If true the subscription has been canceled by the user and will be deleted at the end of the billing period.
    cancel_at_period_end boolean,
    -- Time at which the subscription was created.
    created              timestamp with time zone default timezone('utc' :: text, now())   not null,
    -- Start of the current period that the subscription has been invoiced for.
    current_period_start timestamp with time zone default timezone('utc' :: text, now())   not null,
    -- End of the current period that the subscription has been invoiced for. At the end of this period, a new invoice will be created.
    current_period_end   timestamp with time zone default timezone('utc' :: text, now())   not null,
    -- If the subscription has ended, the timestamp of the date the subscription ended.
    ended_at             timestamp with time zone default timezone('utc' :: text, now()),
    -- A date in the future at which the subscription will automatically get canceled.
    cancel_at            timestamp with time zone default timezone('utc' :: text, now()),
    -- If the subscription has been canceled, the date of that cancellation. If the subscription was canceled with `cancel_at_period_end`, `canceled_at` will still reflect the date of the initial cancellation request, not the end of the subscription period when the subscription is automatically moved to a canceled state.
    canceled_at          timestamp with time zone default timezone('utc' :: text, now()),
    -- If the subscription has a trial, the beginning of that trial.
    trial_start          timestamp with time zone default timezone('utc' :: text, now()),
    -- If the subscription has a trial, the end of that trial.
    trial_end            timestamp with time zone default timezone('utc' :: text, now()),
    provider             text
);

-- Open up access to billing_subscriptions
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE basejump.billing_subscriptions TO service_role;
GRANT SELECT ON TABLE basejump.billing_subscriptions TO authenticated;

-- enable RLS for billing_subscriptions
alter table
    basejump.billing_subscriptions
    enable row level security;

/**
  * -------------------------
  * Section - RLS Policies
  * -------------------------
  * This is where we define access to tables in the basejump schema
 */

create policy "Can only view own billing customer data." on basejump.billing_customers for
    select
    using (
    basejump.has_role_on_account(account_id) = true
    );


create policy "Can only view own billing subscription data." on basejump.billing_subscriptions for
    select
    using (
    basejump.has_role_on_account(account_id) = true
    );

/**
  * -------------------------------------------------------
  * Section - Public functions
  * -------------------------------------------------------
  * Each of these functions exists in the public name space because they are accessible
  * via the API.  it is the primary way developers can interact with Basejump accounts
 */


/**
  * Returns the current billing status for an account
 */
CREATE OR REPLACE FUNCTION public.get_account_billing_status(account_id uuid)
    RETURNS jsonb
    security definer
    set search_path = public, basejump
AS
$$
DECLARE
    result      jsonb;
    role_result jsonb;
BEGIN
    select public.current_user_account_role(get_account_billing_status.account_id) into role_result;

    select jsonb_build_object(
                   'account_id', get_account_billing_status.account_id,
                   'billing_subscription_id', s.id,
                   'billing_enabled', case
                                          when a.personal_account = true then config.enable_personal_account_billing
                                          else config.enable_team_account_billing end,
                   'billing_status', s.status,
                   'billing_customer_id', c.id,
                   'billing_provider', config.billing_provider,
                   'billing_email',
                   coalesce(c.email, u.email) -- if we don't have a customer email, use the user's email as a fallback
               )
    into result
    from basejump.accounts a
             join auth.users u on u.id = a.primary_owner_user_id
             left join basejump.billing_subscriptions s on s.account_id = a.id
             left join basejump.billing_customers c on c.account_id = coalesce(s.account_id, a.id)
             join basejump.config config on true
    where a.id = get_account_billing_status.account_id
    order by s.created desc
    limit 1;

    return result || role_result;
END;
$$ LANGUAGE plpgsql;

grant execute on function public.get_account_billing_status(uuid) to authenticated;

/**
  * Allow service accounts to upsert the billing data for an account
 */
CREATE OR REPLACE FUNCTION public.service_role_upsert_customer_subscription(account_id uuid,
                                                                            customer jsonb default null,
                                                                            subscription jsonb default null)
    RETURNS void AS
$$
BEGIN
    -- if the customer is not null, upsert the data into billing_customers, only upsert fields that are present in the jsonb object
    if customer is not null then
        insert into basejump.billing_customers (id, account_id, email, provider)
        values (customer ->> 'id', service_role_upsert_customer_subscription.account_id, customer ->> 'billing_email',
                (customer ->> 'provider'))
        on conflict (id) do update
            set email = customer ->> 'billing_email';
    end if;

    -- if the subscription is not null, upsert the data into billing_subscriptions, only upsert fields that are present in the jsonb object
    if subscription is not null then
        insert into basejump.billing_subscriptions (id, account_id, billing_customer_id, status, metadata, price_id,
                                                    quantity, cancel_at_period_end, created, current_period_start,
                                                    current_period_end, ended_at, cancel_at, canceled_at, trial_start,
                                                    trial_end, plan_name, provider)
        values (subscription ->> 'id', service_role_upsert_customer_subscription.account_id,
                subscription ->> 'billing_customer_id', (subscription ->> 'status')::basejump.subscription_status,
                subscription -> 'metadata',
                subscription ->> 'price_id', (subscription ->> 'quantity')::int,
                (subscription ->> 'cancel_at_period_end')::boolean,
                (subscription ->> 'created')::timestamptz, (subscription ->> 'current_period_start')::timestamptz,
                (subscription ->> 'current_period_end')::timestamptz, (subscription ->> 'ended_at')::timestamptz,
                (subscription ->> 'cancel_at')::timestamptz,
                (subscription ->> 'canceled_at')::timestamptz, (subscription ->> 'trial_start')::timestamptz,
                (subscription ->> 'trial_end')::timestamptz,
                subscription ->> 'plan_name', (subscription ->> 'provider'))
        on conflict (id) do update
            set billing_customer_id  = subscription ->> 'billing_customer_id',
                status               = (subscription ->> 'status')::basejump.subscription_status,
                metadata             = subscription -> 'metadata',
                price_id             = subscription ->> 'price_id',
                quantity             = (subscription ->> 'quantity')::int,
                cancel_at_period_end = (subscription ->> 'cancel_at_period_end')::boolean,
                current_period_start = (subscription ->> 'current_period_start')::timestamptz,
                current_period_end   = (subscription ->> 'current_period_end')::timestamptz,
                ended_at             = (subscription ->> 'ended_at')::timestamptz,
                cancel_at            = (subscription ->> 'cancel_at')::timestamptz,
                canceled_at          = (subscription ->> 'canceled_at')::timestamptz,
                trial_start          = (subscription ->> 'trial_start')::timestamptz,
                trial_end            = (subscription ->> 'trial_end')::timestamptz,
                plan_name            = subscription ->> 'plan_name';
    end if;
end;
$$ LANGUAGE plpgsql;

GRANT EXECUTE ON FUNCTION public.service_role_upsert_customer_subscription(uuid, jsonb, jsonb) TO service_role;
UPDATE basejump.config SET enable_team_accounts = TRUE;
UPDATE basejump.config SET enable_personal_account_billing = TRUE;
UPDATE basejump.config SET enable_team_account_billing = TRUE;
-- Enable UUID extension
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Create devices table first
CREATE TABLE public.devices (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    account_id UUID NOT NULL,
    name TEXT,
    last_seen TIMESTAMP WITH TIME ZONE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    is_online BOOLEAN DEFAULT FALSE,
    CONSTRAINT fk_account FOREIGN KEY (account_id) REFERENCES basejump.accounts(id) ON DELETE CASCADE
);

-- Create recordings table
CREATE TABLE public.recordings (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    account_id UUID NOT NULL,
    device_id UUID NOT NULL,
    preprocessed_file_path TEXT,
    meta JSONB,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT now(),
    name TEXT,
    ui_annotated BOOLEAN DEFAULT FALSE,
    a11y_file_path TEXT,
    audio_file_path TEXT,
    action_annotated BOOLEAN DEFAULT FALSE,
    raw_data_file_path TEXT,
    metadata_file_path TEXT,
    action_training_file_path TEXT,
    CONSTRAINT fk_account FOREIGN KEY (account_id) REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    CONSTRAINT fk_device FOREIGN KEY (device_id) REFERENCES public.devices(id) ON DELETE CASCADE
);

-- Create indexes for foreign keys
CREATE INDEX idx_recordings_account_id ON public.recordings(account_id);
CREATE INDEX idx_recordings_device_id ON public.recordings(device_id);
CREATE INDEX idx_devices_account_id ON public.devices(account_id);

-- Add RLS policies (optional, can be customized as needed)
ALTER TABLE public.recordings ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.devices ENABLE ROW LEVEL SECURITY;

-- Create RLS policies for devices
CREATE POLICY "Account members can delete their own devices"
    ON public.devices FOR DELETE
    USING (basejump.has_role_on_account(account_id));

CREATE POLICY "Account members can insert their own devices"
    ON public.devices FOR INSERT
    WITH CHECK (basejump.has_role_on_account(account_id));

CREATE POLICY "Account members can only access their own devices"
    ON public.devices FOR ALL
    USING (basejump.has_role_on_account(account_id));

CREATE POLICY "Account members can update their own devices"
    ON public.devices FOR UPDATE
    USING (basejump.has_role_on_account(account_id));

CREATE POLICY "Account members can view their own devices"
    ON public.devices FOR SELECT
    USING (basejump.has_role_on_account(account_id));

-- Create RLS policies for recordings
CREATE POLICY "Account members can delete their own recordings"
    ON public.recordings FOR DELETE
    USING (basejump.has_role_on_account(account_id));

CREATE POLICY "Account members can insert their own recordings"
    ON public.recordings FOR INSERT
    WITH CHECK (basejump.has_role_on_account(account_id));

CREATE POLICY "Account members can only access their own recordings"
    ON public.recordings FOR ALL
    USING (basejump.has_role_on_account(account_id));

CREATE POLICY "Account members can update their own recordings"
    ON public.recordings FOR UPDATE
    USING (basejump.has_role_on_account(account_id));

CREATE POLICY "Account members can view their own recordings"
    ON public.recordings FOR SELECT
    USING (basejump.has_role_on_account(account_id));

-- Note: For threads and messages, you might want different RLS policies
-- depending on your application's requirements


-- Also drop the old function signature
DROP FUNCTION IF EXISTS transfer_device(UUID, UUID, TEXT);


CREATE OR REPLACE FUNCTION transfer_device(
  device_id UUID,      -- Parameter remains UUID
  new_account_id UUID, -- Changed parameter name and implies new ownership target
  device_name TEXT DEFAULT NULL
)
RETURNS SETOF devices AS $$
DECLARE
  device_exists BOOLEAN;
  updated_device devices;
BEGIN
  -- Check if a device with the specified UUID exists
  SELECT EXISTS (
    SELECT 1 FROM devices WHERE id = device_id
  ) INTO device_exists;

  IF device_exists THEN
    -- Device exists: update its account ownership and last_seen timestamp
    UPDATE devices
    SET
      account_id = new_account_id, -- Update account_id instead of user_id
      name = COALESCE(device_name, name),
      last_seen = NOW()
    WHERE id = device_id
    RETURNING * INTO updated_device;

    RETURN NEXT updated_device;
  ELSE
    -- Device doesn't exist; return nothing so the caller can handle creation
    RETURN;
  END IF;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute permission so that authenticated users can call this function
-- Updated function signature
GRANT EXECUTE ON FUNCTION transfer_device(UUID, UUID, TEXT) TO authenticated;




-- Create the ui_grounding bucket
INSERT INTO storage.buckets (id, name, public)
VALUES ('ui_grounding', 'ui_grounding', false)
ON CONFLICT (id) DO NOTHING; -- Avoid error if bucket already exists

-- Create the ui_grounding_trajs bucket
INSERT INTO storage.buckets (id, name, public)
VALUES ('ui_grounding_trajs', 'ui_grounding_trajs', false)
ON CONFLICT (id) DO NOTHING; -- Avoid error if bucket already exists

-- Create the recordings bucket
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES ('recordings', 'recordings', false, null, null) -- Set file size limit and mime types as needed
ON CONFLICT (id) DO NOTHING; -- Avoid error if bucket already exists


-- RLS policies for the 'recordings' bucket
-- Allow members to view files in accounts they belong to
CREATE POLICY "Account members can select recording files"
    ON storage.objects FOR SELECT
    TO authenticated
    USING (
        bucket_id = 'recordings' AND
        (storage.foldername(name))[1]::uuid IN (SELECT basejump.get_accounts_with_role())
    );

-- Allow members to insert files into accounts they belong to
CREATE POLICY "Account members can insert recording files"
    ON storage.objects FOR INSERT
    TO authenticated
    WITH CHECK (
        bucket_id = 'recordings' AND
        (storage.foldername(name))[1]::uuid IN (SELECT basejump.get_accounts_with_role())
    );

-- Allow members to update files in accounts they belong to
CREATE POLICY "Account members can update recording files"
    ON storage.objects FOR UPDATE
    TO authenticated
    USING (
        bucket_id = 'recordings' AND
        (storage.foldername(name))[1]::uuid IN (SELECT basejump.get_accounts_with_role())
    );

-- Allow members to delete files from accounts they belong to
-- Consider restricting this further, e.g., to 'owner' role if needed:
-- (storage.foldername(name))[1]::uuid IN (SELECT basejump.get_accounts_with_role('owner'))
CREATE POLICY "Account members can delete recording files"
    ON storage.objects FOR DELETE
    TO authenticated
    USING (
        bucket_id = 'recordings' AND
        (storage.foldername(name))[1]::uuid IN (SELECT basejump.get_accounts_with_role())
    );
-- AGENTPRESS SCHEMA:
-- Create projects table
CREATE TABLE projects (
    project_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    description TEXT,
    account_id UUID NOT NULL REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    sandbox JSONB DEFAULT '{}'::jsonb,
    is_public BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, NOW()) NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, NOW()) NOT NULL
);

-- Create threads table
CREATE TABLE threads (
    thread_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    project_id UUID REFERENCES projects(project_id) ON DELETE CASCADE,
    is_public BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, NOW()) NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, NOW()) NOT NULL
);

-- Create messages table
CREATE TABLE messages (
    message_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id UUID NOT NULL REFERENCES threads(thread_id) ON DELETE CASCADE,
    type TEXT NOT NULL,
    is_llm_message BOOLEAN NOT NULL DEFAULT TRUE,
    content JSONB NOT NULL,
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, NOW()) NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, NOW()) NOT NULL
);

-- Create agent_runs table
CREATE TABLE agent_runs (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id UUID NOT NULL REFERENCES threads(thread_id),
    status TEXT NOT NULL DEFAULT 'running',
    started_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, NOW()) NOT NULL,
    completed_at TIMESTAMP WITH TIME ZONE,
    responses JSONB NOT NULL DEFAULT '[]'::jsonb, -- TO BE REMOVED, NOT USED 
    error TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, NOW()) NOT NULL,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT TIMEZONE('utc'::text, NOW()) NOT NULL
);

-- Create updated_at trigger function
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = TIMEZONE('utc'::text, NOW());
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Create triggers for updated_at
CREATE TRIGGER update_threads_updated_at
    BEFORE UPDATE ON threads
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_messages_updated_at
    BEFORE UPDATE ON messages
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_agent_runs_updated_at
    BEFORE UPDATE ON agent_runs
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_projects_updated_at
    BEFORE UPDATE ON projects
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_column();

-- Create indexes for better query performance
CREATE INDEX idx_threads_created_at ON threads(created_at);
CREATE INDEX idx_threads_account_id ON threads(account_id);
CREATE INDEX idx_threads_project_id ON threads(project_id);
CREATE INDEX idx_agent_runs_thread_id ON agent_runs(thread_id);
CREATE INDEX idx_agent_runs_status ON agent_runs(status);
CREATE INDEX idx_agent_runs_created_at ON agent_runs(created_at);
CREATE INDEX idx_projects_account_id ON projects(account_id);
CREATE INDEX idx_projects_created_at ON projects(created_at);
CREATE INDEX idx_messages_thread_id ON messages(thread_id);
CREATE INDEX idx_messages_created_at ON messages(created_at);

-- Enable Row Level Security
ALTER TABLE threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE projects ENABLE ROW LEVEL SECURITY;

-- Project policies
CREATE POLICY project_select_policy ON projects
    FOR SELECT
    USING (
        is_public = TRUE OR
        basejump.has_role_on_account(account_id) = true
    );

CREATE POLICY project_insert_policy ON projects
    FOR INSERT
    WITH CHECK (basejump.has_role_on_account(account_id) = true);

CREATE POLICY project_update_policy ON projects
    FOR UPDATE
    USING (basejump.has_role_on_account(account_id) = true);

CREATE POLICY project_delete_policy ON projects
    FOR DELETE
    USING (basejump.has_role_on_account(account_id) = true);

-- Thread policies based on project and account ownership
CREATE POLICY thread_select_policy ON threads
    FOR SELECT
    USING (
        basejump.has_role_on_account(account_id) = true OR 
        EXISTS (
            SELECT 1 FROM projects
            WHERE projects.project_id = threads.project_id
            AND (
                projects.is_public = TRUE OR
                basejump.has_role_on_account(projects.account_id) = true
            )
        )
    );

CREATE POLICY thread_insert_policy ON threads
    FOR INSERT
    WITH CHECK (
        basejump.has_role_on_account(account_id) = true OR 
        EXISTS (
            SELECT 1 FROM projects
            WHERE projects.project_id = threads.project_id
            AND basejump.has_role_on_account(projects.account_id) = true
        )
    );

CREATE POLICY thread_update_policy ON threads
    FOR UPDATE
    USING (
        basejump.has_role_on_account(account_id) = true OR 
        EXISTS (
            SELECT 1 FROM projects
            WHERE projects.project_id = threads.project_id
            AND basejump.has_role_on_account(projects.account_id) = true
        )
    );

CREATE POLICY thread_delete_policy ON threads
    FOR DELETE
    USING (
        basejump.has_role_on_account(account_id) = true OR 
        EXISTS (
            SELECT 1 FROM projects
            WHERE projects.project_id = threads.project_id
            AND basejump.has_role_on_account(projects.account_id) = true
        )
    );

-- Create policies for agent_runs based on thread ownership
CREATE POLICY agent_run_select_policy ON agent_runs
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM threads
            LEFT JOIN projects ON threads.project_id = projects.project_id
            WHERE threads.thread_id = agent_runs.thread_id
            AND (
                projects.is_public = TRUE OR
                basejump.has_role_on_account(threads.account_id) = true OR 
                basejump.has_role_on_account(projects.account_id) = true
            )
        )
    );

CREATE POLICY agent_run_insert_policy ON agent_runs
    FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM threads
            LEFT JOIN projects ON threads.project_id = projects.project_id
            WHERE threads.thread_id = agent_runs.thread_id
            AND (
                basejump.has_role_on_account(threads.account_id) = true OR 
                basejump.has_role_on_account(projects.account_id) = true
            )
        )
    );

CREATE POLICY agent_run_update_policy ON agent_runs
    FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM threads
            LEFT JOIN projects ON threads.project_id = projects.project_id
            WHERE threads.thread_id = agent_runs.thread_id
            AND (
                basejump.has_role_on_account(threads.account_id) = true OR 
                basejump.has_role_on_account(projects.account_id) = true
            )
        )
    );

CREATE POLICY agent_run_delete_policy ON agent_runs
    FOR DELETE
    USING (
        EXISTS (
            SELECT 1 FROM threads
            LEFT JOIN projects ON threads.project_id = projects.project_id
            WHERE threads.thread_id = agent_runs.thread_id
            AND (
                basejump.has_role_on_account(threads.account_id) = true OR 
                basejump.has_role_on_account(projects.account_id) = true
            )
        )
    );

-- Create message policies based on thread ownership
CREATE POLICY message_select_policy ON messages
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM threads
            LEFT JOIN projects ON threads.project_id = projects.project_id
            WHERE threads.thread_id = messages.thread_id
            AND (
                projects.is_public = TRUE OR
                basejump.has_role_on_account(threads.account_id) = true OR 
                basejump.has_role_on_account(projects.account_id) = true
            )
        )
    );

CREATE POLICY message_insert_policy ON messages
    FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM threads
            LEFT JOIN projects ON threads.project_id = projects.project_id
            WHERE threads.thread_id = messages.thread_id
            AND (
                basejump.has_role_on_account(threads.account_id) = true OR 
                basejump.has_role_on_account(projects.account_id) = true
            )
        )
    );

CREATE POLICY message_update_policy ON messages
    FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM threads
            LEFT JOIN projects ON threads.project_id = projects.project_id
            WHERE threads.thread_id = messages.thread_id
            AND (
                basejump.has_role_on_account(threads.account_id) = true OR 
                basejump.has_role_on_account(projects.account_id) = true
            )
        )
    );

CREATE POLICY message_delete_policy ON messages
    FOR DELETE
    USING (
        EXISTS (
            SELECT 1 FROM threads
            LEFT JOIN projects ON threads.project_id = projects.project_id
            WHERE threads.thread_id = messages.thread_id
            AND (
                basejump.has_role_on_account(threads.account_id) = true OR 
                basejump.has_role_on_account(projects.account_id) = true
            )
        )
    );

-- Grant permissions to roles
GRANT ALL PRIVILEGES ON TABLE projects TO authenticated, service_role;
GRANT SELECT ON TABLE projects TO anon;
GRANT SELECT ON TABLE threads TO authenticated, anon, service_role;
GRANT SELECT ON TABLE messages TO authenticated, anon, service_role;
GRANT ALL PRIVILEGES ON TABLE agent_runs TO authenticated, service_role;

-- Create a function that matches the Python get_messages behavior
CREATE OR REPLACE FUNCTION get_llm_formatted_messages(p_thread_id UUID)
RETURNS JSONB
SECURITY DEFINER -- Changed to SECURITY DEFINER to allow service role access
LANGUAGE plpgsql
AS $$
DECLARE
    messages_array JSONB := '[]'::JSONB;
    has_access BOOLEAN;
    current_role TEXT;
    latest_summary_id UUID;
    latest_summary_time TIMESTAMP WITH TIME ZONE;
    is_project_public BOOLEAN;
BEGIN
    -- Get current role
    SELECT current_user INTO current_role;
    
    -- Check if associated project is public
    SELECT p.is_public INTO is_project_public
    FROM threads t
    LEFT JOIN projects p ON t.project_id = p.project_id
    WHERE t.thread_id = p_thread_id;
    
    -- Skip access check for service_role or public projects
    IF current_role = 'authenticated' AND NOT is_project_public THEN
        -- Check if thread exists and user has access
        SELECT EXISTS (
            SELECT 1 FROM threads t
            LEFT JOIN projects p ON t.project_id = p.project_id
            WHERE t.thread_id = p_thread_id
            AND (
                basejump.has_role_on_account(t.account_id) = true OR 
                basejump.has_role_on_account(p.account_id) = true
            )
        ) INTO has_access;
        
        IF NOT has_access THEN
            RAISE EXCEPTION 'Thread not found or access denied';
        END IF;
    END IF;

    -- Find the latest summary message if it exists
    SELECT message_id, created_at
    INTO latest_summary_id, latest_summary_time
    FROM messages
    WHERE thread_id = p_thread_id
    AND type = 'summary'
    AND is_llm_message = TRUE
    ORDER BY created_at DESC
    LIMIT 1;
    
    -- Log whether a summary was found (helpful for debugging)
    IF latest_summary_id IS NOT NULL THEN
        RAISE NOTICE 'Found latest summary message: id=%, time=%', latest_summary_id, latest_summary_time;
    ELSE
        RAISE NOTICE 'No summary message found for thread %', p_thread_id;
    END IF;

    -- Parse content if it's stored as a string and return proper JSON objects
    WITH parsed_messages AS (
        SELECT 
            message_id,
            CASE 
                WHEN jsonb_typeof(content) = 'string' THEN content::text::jsonb
                ELSE content
            END AS parsed_content,
            created_at,
            type
        FROM messages
        WHERE thread_id = p_thread_id
        AND is_llm_message = TRUE
        AND (
            -- Include the latest summary and all messages after it,
            -- or all messages if no summary exists
            latest_summary_id IS NULL 
            OR message_id = latest_summary_id 
            OR created_at > latest_summary_time
        )
        ORDER BY created_at
    )
    SELECT JSONB_AGG(parsed_content)
    INTO messages_array
    FROM parsed_messages;
    
    -- Handle the case when no messages are found
    IF messages_array IS NULL THEN
        RETURN '[]'::JSONB;
    END IF;
    
    RETURN messages_array;
END;
$$;

-- Grant execute permissions
GRANT EXECUTE ON FUNCTION get_llm_formatted_messages TO authenticated, anon, service_role;
-- Workflow System Migration
-- This migration creates all necessary tables for the agent workflow system

-- Enable UUID extension if not already enabled
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Enum types for workflow system
DO $$ BEGIN
    CREATE TYPE workflow_status AS ENUM ('draft', 'active', 'paused', 'disabled', 'archived');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE execution_status AS ENUM ('pending', 'running', 'completed', 'failed', 'cancelled', 'timeout');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE trigger_type AS ENUM ('webhook', 'schedule', 'event', 'polling', 'manual', 'workflow');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE node_type AS ENUM ('trigger', 'agent', 'tool', 'condition', 'loop', 'parallel', 'webhook', 'transform', 'delay', 'output');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE connection_type AS ENUM ('data', 'tool', 'processed_data', 'action', 'condition');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- Workflows table
CREATE TABLE IF NOT EXISTS workflows (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    description TEXT,
    project_id UUID NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    created_by UUID NOT NULL REFERENCES auth.users(id),
    status workflow_status DEFAULT 'draft',
    version INTEGER DEFAULT 1,
    definition JSONB NOT NULL,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Indexes
    CONSTRAINT workflows_name_project_unique UNIQUE (name, project_id)
);

-- Create indexes for workflows
CREATE INDEX IF NOT EXISTS idx_workflows_project_id ON workflows(project_id);
CREATE INDEX IF NOT EXISTS idx_workflows_account_id ON workflows(account_id);
CREATE INDEX IF NOT EXISTS idx_workflows_status ON workflows(status);
CREATE INDEX IF NOT EXISTS idx_workflows_created_by ON workflows(created_by);

-- Workflow executions table
CREATE TABLE IF NOT EXISTS workflow_executions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workflow_id UUID NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
    workflow_version INTEGER NOT NULL,
    workflow_name VARCHAR(255) NOT NULL,
    execution_context JSONB NOT NULL,
    project_id UUID NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    triggered_by VARCHAR(255),
    scheduled_for TIMESTAMP WITH TIME ZONE,
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    duration_seconds FLOAT,
    status execution_status NOT NULL DEFAULT 'pending',
    result JSONB,
    error TEXT,
    nodes_executed INTEGER DEFAULT 0,
    tokens_used INTEGER DEFAULT 0,
    cost DECIMAL(10, 4) DEFAULT 0.0,
    ip_address INET,
    user_agent TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes for workflow_executions
CREATE INDEX IF NOT EXISTS idx_workflow_executions_workflow_id ON workflow_executions(workflow_id);
CREATE INDEX IF NOT EXISTS idx_workflow_executions_project_id ON workflow_executions(project_id);
CREATE INDEX IF NOT EXISTS idx_workflow_executions_account_id ON workflow_executions(account_id);
CREATE INDEX IF NOT EXISTS idx_workflow_executions_status ON workflow_executions(status);
CREATE INDEX IF NOT EXISTS idx_workflow_executions_started_at ON workflow_executions(started_at DESC);

-- Triggers table
CREATE TABLE IF NOT EXISTS triggers (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workflow_id UUID NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
    type trigger_type NOT NULL,
    config JSONB NOT NULL,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes for triggers
CREATE INDEX IF NOT EXISTS idx_triggers_workflow_id ON triggers(workflow_id);
CREATE INDEX IF NOT EXISTS idx_triggers_type ON triggers(type);
CREATE INDEX IF NOT EXISTS idx_triggers_is_active ON triggers(is_active);

-- Webhook registrations table
CREATE TABLE IF NOT EXISTS webhook_registrations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workflow_id UUID NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
    trigger_id VARCHAR(255) NOT NULL,
    path VARCHAR(255) UNIQUE NOT NULL,
    secret VARCHAR(255) NOT NULL,
    method VARCHAR(10) DEFAULT 'POST',
    headers_validation JSONB,
    body_schema JSONB,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_triggered TIMESTAMP WITH TIME ZONE,
    trigger_count INTEGER DEFAULT 0
);

-- Create indexes for webhook_registrations
CREATE INDEX IF NOT EXISTS idx_webhook_registrations_workflow_id ON webhook_registrations(workflow_id);
CREATE INDEX IF NOT EXISTS idx_webhook_registrations_path ON webhook_registrations(path);
CREATE INDEX IF NOT EXISTS idx_webhook_registrations_is_active ON webhook_registrations(is_active);

-- Scheduled jobs table
CREATE TABLE IF NOT EXISTS scheduled_jobs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workflow_id UUID NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
    trigger_id VARCHAR(255) NOT NULL,
    cron_expression VARCHAR(255) NOT NULL,
    timezone VARCHAR(50) DEFAULT 'UTC',
    start_date TIMESTAMP WITH TIME ZONE,
    end_date TIMESTAMP WITH TIME ZONE,
    is_active BOOLEAN DEFAULT TRUE,
    last_run TIMESTAMP WITH TIME ZONE,
    next_run TIMESTAMP WITH TIME ZONE,
    run_count INTEGER DEFAULT 0,
    consecutive_failures INTEGER DEFAULT 0,
    max_consecutive_failures INTEGER DEFAULT 5,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes for scheduled_jobs
CREATE INDEX IF NOT EXISTS idx_scheduled_jobs_workflow_id ON scheduled_jobs(workflow_id);
CREATE INDEX IF NOT EXISTS idx_scheduled_jobs_is_active ON scheduled_jobs(is_active);
CREATE INDEX IF NOT EXISTS idx_scheduled_jobs_next_run ON scheduled_jobs(next_run);

-- Workflow templates table
CREATE TABLE IF NOT EXISTS workflow_templates (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name VARCHAR(255) NOT NULL,
    description TEXT NOT NULL,
    category VARCHAR(100) NOT NULL,
    workflow_definition JSONB NOT NULL,
    required_variables JSONB,
    required_tools TEXT[],
    required_models TEXT[],
    author VARCHAR(255) NOT NULL,
    version VARCHAR(50) NOT NULL,
    tags TEXT[],
    preview_image TEXT,
    usage_count INTEGER DEFAULT 0,
    rating DECIMAL(3, 2) DEFAULT 0.0,
    is_featured BOOLEAN DEFAULT FALSE,
    is_verified BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes for workflow_templates
CREATE INDEX IF NOT EXISTS idx_workflow_templates_category ON workflow_templates(category);
CREATE INDEX IF NOT EXISTS idx_workflow_templates_is_featured ON workflow_templates(is_featured);
CREATE INDEX IF NOT EXISTS idx_workflow_templates_rating ON workflow_templates(rating DESC);

-- Workflow execution logs table (for detailed logging)
CREATE TABLE IF NOT EXISTS workflow_execution_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    execution_id UUID NOT NULL REFERENCES workflow_executions(id) ON DELETE CASCADE,
    node_id VARCHAR(255) NOT NULL,
    node_name VARCHAR(255),
    node_type node_type,
    started_at TIMESTAMP WITH TIME ZONE NOT NULL,
    completed_at TIMESTAMP WITH TIME ZONE,
    duration_ms INTEGER,
    status execution_status NOT NULL,
    input_data JSONB,
    output_data JSONB,
    error TEXT,
    tokens_used INTEGER DEFAULT 0,
    cost DECIMAL(10, 4) DEFAULT 0.0,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes for workflow_execution_logs
CREATE INDEX IF NOT EXISTS idx_workflow_execution_logs_execution_id ON workflow_execution_logs(execution_id);
CREATE INDEX IF NOT EXISTS idx_workflow_execution_logs_node_id ON workflow_execution_logs(node_id);
CREATE INDEX IF NOT EXISTS idx_workflow_execution_logs_status ON workflow_execution_logs(status);

-- Workflow variables table (for storing workflow-specific variables/secrets)
CREATE TABLE IF NOT EXISTS workflow_variables (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workflow_id UUID NOT NULL REFERENCES workflows(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    value TEXT,
    is_secret BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    CONSTRAINT workflow_variables_unique UNIQUE (workflow_id, name)
);

-- Create indexes for workflow_variables
CREATE INDEX IF NOT EXISTS idx_workflow_variables_workflow_id ON workflow_variables(workflow_id);

-- Row Level Security (RLS) Policies

-- Enable RLS on all tables
ALTER TABLE workflows ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_executions ENABLE ROW LEVEL SECURITY;
ALTER TABLE triggers ENABLE ROW LEVEL SECURITY;
ALTER TABLE webhook_registrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE scheduled_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_execution_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_variables ENABLE ROW LEVEL SECURITY;

-- Workflows policies (using basejump pattern)
DO $$ BEGIN
    CREATE POLICY "Users can view workflows in their accounts" ON workflows
        FOR SELECT USING (
            basejump.has_role_on_account(account_id) = true OR
            EXISTS (
                SELECT 1 FROM projects
                WHERE projects.project_id = workflows.project_id
                AND projects.is_public = TRUE
            )
        );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;
    
DO $$ BEGIN
    CREATE POLICY "Users can create workflows in their accounts" ON workflows
        FOR INSERT WITH CHECK (
            basejump.has_role_on_account(account_id) = true
        );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE POLICY "Users can update workflows in their accounts" ON workflows
        FOR UPDATE USING (
            basejump.has_role_on_account(account_id) = true
        );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE POLICY "Users can delete workflows in their accounts" ON workflows
        FOR DELETE USING (
            basejump.has_role_on_account(account_id) = true
        );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- Workflow executions policies
DO $$ BEGIN
    CREATE POLICY "Users can view executions in their accounts" ON workflow_executions
        FOR SELECT USING (
            basejump.has_role_on_account(account_id) = true OR
            EXISTS (
                SELECT 1 FROM workflows w
                JOIN projects p ON w.project_id = p.project_id
                WHERE w.id = workflow_executions.workflow_id
                AND p.is_public = TRUE
            )
        );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE POLICY "Service role can insert executions" ON workflow_executions
        FOR INSERT WITH CHECK (auth.jwt() ->> 'role' = 'service_role');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE POLICY "Service role can update executions" ON workflow_executions
        FOR UPDATE USING (auth.jwt() ->> 'role' = 'service_role');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- Triggers policies
DO $$ BEGIN
    CREATE POLICY "Users can view triggers in their workflows" ON triggers
        FOR SELECT USING (
            EXISTS (
                SELECT 1 FROM workflows 
                WHERE workflows.id = triggers.workflow_id
                AND basejump.has_role_on_account(workflows.account_id) = true
            )
        );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE POLICY "Service role full access to webhook_registrations" ON webhook_registrations
        FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE POLICY "Service role full access to scheduled_jobs" ON scheduled_jobs
        FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE POLICY "Public can view workflow templates" ON workflow_templates
        FOR SELECT USING (true);
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE POLICY "Service role can manage workflow templates" ON workflow_templates
        FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE POLICY "Users can view execution logs in their accounts" ON workflow_execution_logs
        FOR SELECT USING (
            EXISTS (
                SELECT 1 FROM workflow_executions 
                WHERE workflow_executions.id = workflow_execution_logs.execution_id
                AND basejump.has_role_on_account(workflow_executions.account_id) = true
            )
        );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE POLICY "Service role can insert execution logs" ON workflow_execution_logs
        FOR INSERT WITH CHECK (auth.jwt() ->> 'role' = 'service_role');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE POLICY "Users can manage variables for their workflows" ON workflow_variables
        FOR ALL USING (
            EXISTS (
                SELECT 1 FROM workflows 
                WHERE workflows.id = workflow_variables.workflow_id
                AND basejump.has_role_on_account(workflows.account_id) = true
            )
        );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- Functions for automatic timestamp updates
-- Note: update_updated_at_column function already exists from previous migrations

-- Create triggers for updated_at
DO $$ BEGIN
    CREATE TRIGGER update_workflows_updated_at BEFORE UPDATE ON workflows
        FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TRIGGER update_triggers_updated_at BEFORE UPDATE ON triggers
        FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TRIGGER update_scheduled_jobs_updated_at BEFORE UPDATE ON scheduled_jobs
        FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TRIGGER update_workflow_templates_updated_at BEFORE UPDATE ON workflow_templates
        FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TRIGGER update_workflow_variables_updated_at BEFORE UPDATE ON workflow_variables
        FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- Function to clean up old execution logs (can be called periodically)
CREATE OR REPLACE FUNCTION cleanup_old_execution_logs(days_to_keep INTEGER DEFAULT 30)
RETURNS INTEGER AS $$
DECLARE
    deleted_count INTEGER;
BEGIN
    DELETE FROM workflow_execution_logs
    WHERE created_at < NOW() - INTERVAL '1 day' * days_to_keep;
    
    GET DIAGNOSTICS deleted_count = ROW_COUNT;
    RETURN deleted_count;
END;
$$ LANGUAGE plpgsql;

-- Function to get workflow execution statistics
CREATE OR REPLACE FUNCTION get_workflow_statistics(p_workflow_id UUID)
RETURNS TABLE (
    total_executions BIGINT,
    successful_executions BIGINT,
    failed_executions BIGINT,
    average_duration_seconds FLOAT,
    total_cost DECIMAL,
    total_tokens BIGINT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        COUNT(*)::BIGINT as total_executions,
        COUNT(*) FILTER (WHERE status = 'completed')::BIGINT as successful_executions,
        COUNT(*) FILTER (WHERE status = 'failed')::BIGINT as failed_executions,
        AVG(duration_seconds)::FLOAT as average_duration_seconds,
        SUM(cost)::DECIMAL as total_cost,
        SUM(tokens_used)::BIGINT as total_tokens
    FROM workflow_executions
    WHERE workflow_id = p_workflow_id;
END;
$$ LANGUAGE plpgsql;

-- Grant permissions to roles
GRANT ALL PRIVILEGES ON TABLE workflows TO authenticated, service_role;
GRANT ALL PRIVILEGES ON TABLE workflow_executions TO authenticated, service_role;
GRANT ALL PRIVILEGES ON TABLE triggers TO authenticated, service_role;
GRANT ALL PRIVILEGES ON TABLE webhook_registrations TO service_role;
GRANT ALL PRIVILEGES ON TABLE scheduled_jobs TO service_role;
GRANT SELECT ON TABLE workflow_templates TO authenticated, anon;
GRANT ALL PRIVILEGES ON TABLE workflow_templates TO service_role;
GRANT SELECT ON TABLE workflow_execution_logs TO authenticated;
GRANT ALL PRIVILEGES ON TABLE workflow_execution_logs TO service_role;
GRANT ALL PRIVILEGES ON TABLE workflow_variables TO authenticated, service_role;

-- Add comments for documentation
COMMENT ON TABLE workflows IS 'Stores workflow definitions and configurations';
COMMENT ON TABLE workflow_executions IS 'Records of workflow execution instances';
COMMENT ON TABLE triggers IS 'Workflow trigger configurations';
COMMENT ON TABLE webhook_registrations IS 'Webhook endpoints for workflow triggers';
COMMENT ON TABLE scheduled_jobs IS 'Scheduled workflow executions';
COMMENT ON TABLE workflow_templates IS 'Pre-built workflow templates';
COMMENT ON TABLE workflow_execution_logs IS 'Detailed logs for workflow node executions';
COMMENT ON TABLE workflow_variables IS 'Workflow-specific variables and secrets'; 
-- Add workflow_flows table for storing visual flow representations
-- This table stores the visual flow data (nodes and edges) separately from the workflow definition

CREATE TABLE IF NOT EXISTS workflow_flows (
    workflow_id UUID PRIMARY KEY REFERENCES workflows(id) ON DELETE CASCADE,
    nodes JSONB NOT NULL DEFAULT '[]',
    edges JSONB NOT NULL DEFAULT '[]',
    metadata JSONB NOT NULL DEFAULT '{}',
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Enable RLS
ALTER TABLE workflow_flows ENABLE ROW LEVEL SECURITY;

-- RLS policies
DO $$ BEGIN
    CREATE POLICY "Users can view flows for their workflows" ON workflow_flows
        FOR SELECT USING (
            EXISTS (
                SELECT 1 FROM workflows 
            WHERE workflows.id = workflow_flows.workflow_id
            AND basejump.has_role_on_account(workflows.account_id) = true
        )
    );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE POLICY "Users can manage flows for their workflows" ON workflow_flows
        FOR ALL USING (
            EXISTS (
                SELECT 1 FROM workflows 
                WHERE workflows.id = workflow_flows.workflow_id
                AND basejump.has_role_on_account(workflows.account_id) = true
            )
        );
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- Create trigger for updated_at
DO $$ BEGIN
    CREATE TRIGGER update_workflow_flows_updated_at BEFORE UPDATE ON workflow_flows
        FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- Grant permissions
GRANT ALL PRIVILEGES ON TABLE workflow_flows TO authenticated, service_role;

-- Add comment
COMMENT ON TABLE workflow_flows IS 'Stores visual flow representations (nodes and edges) for workflows'; 
DROP POLICY IF EXISTS thread_select_policy ON threads;

CREATE POLICY thread_select_policy ON threads
FOR SELECT
USING (
    is_public IS TRUE
    OR basejump.has_role_on_account(account_id) = true
    OR EXISTS (
        SELECT 1 FROM projects
        WHERE projects.project_id = threads.project_id
        AND (
            projects.is_public IS TRUE
            OR basejump.has_role_on_account(projects.account_id) = true
        )
    )
);
DROP POLICY IF EXISTS "Give read only access to internal users" ON threads;

CREATE POLICY "Give read only access to internal users" ON threads
FOR SELECT
USING (
    ((auth.jwt() ->> 'email'::text) ~~ '%@kortix.ai'::text)
);


DROP POLICY IF EXISTS "Give read only access to internal users" ON messages;

CREATE POLICY "Give read only access to internal users" ON messages
FOR SELECT
USING (
    ((auth.jwt() ->> 'email'::text) ~~ '%@kortix.ai'::text)
);


DROP POLICY IF EXISTS "Give read only access to internal users" ON projects;

CREATE POLICY "Give read only access to internal users" ON projects
FOR SELECT
USING (
    ((auth.jwt() ->> 'email'::text) ~~ '%@kortix.ai'::text)
);
BEGIN;

-- Create agents table for storing agent configurations
CREATE TABLE IF NOT EXISTS agents (
    agent_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    system_prompt TEXT NOT NULL,
    configured_mcps JSONB DEFAULT '[]'::jsonb,
    agentpress_tools JSONB DEFAULT '{}'::jsonb,
    is_default BOOLEAN DEFAULT false,
    avatar VARCHAR(10),
    avatar_color VARCHAR(7),
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Add indexes for performance on agents table
CREATE INDEX IF NOT EXISTS idx_agents_account_id ON agents(account_id);
CREATE INDEX IF NOT EXISTS idx_agents_is_default ON agents(is_default);
CREATE INDEX IF NOT EXISTS idx_agents_created_at ON agents(created_at);

-- Add unique constraint to ensure only one default agent per account
CREATE UNIQUE INDEX IF NOT EXISTS idx_agents_account_default ON agents(account_id, is_default) WHERE is_default = true;

-- Create function to update updated_at timestamp
CREATE OR REPLACE FUNCTION update_agents_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create trigger for updated_at (drop first if exists to avoid conflicts)
DROP TRIGGER IF EXISTS trigger_agents_updated_at ON agents;
CREATE TRIGGER trigger_agents_updated_at
    BEFORE UPDATE ON agents
    FOR EACH ROW
    EXECUTE FUNCTION update_agents_updated_at();

-- Enable RLS on agents table
ALTER TABLE agents ENABLE ROW LEVEL SECURITY;

-- Drop existing policies if they exist to avoid conflicts
DROP POLICY IF EXISTS agents_select_own ON agents;
DROP POLICY IF EXISTS agents_insert_own ON agents;
DROP POLICY IF EXISTS agents_update_own ON agents;
DROP POLICY IF EXISTS agents_delete_own ON agents;

-- Policy for users to see their own agents
CREATE POLICY agents_select_own ON agents
    FOR SELECT
    USING (basejump.has_role_on_account(account_id));

-- Policy for users to insert their own agents
CREATE POLICY agents_insert_own ON agents
    FOR INSERT
    WITH CHECK (basejump.has_role_on_account(account_id, 'owner'));

-- Policy for users to update their own agents
CREATE POLICY agents_update_own ON agents
    FOR UPDATE
    USING (basejump.has_role_on_account(account_id, 'owner'));

-- Policy for users to delete their own agents (except default)
CREATE POLICY agents_delete_own ON agents
    FOR DELETE
    USING (basejump.has_role_on_account(account_id, 'owner') AND is_default = false);

-- NOTE: Default agent insertion has been removed per requirement

-- Add agent_id column to threads table if it doesn't exist
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns 
                   WHERE table_name='threads' AND column_name='agent_id') THEN
        ALTER TABLE threads ADD COLUMN agent_id UUID REFERENCES agents(agent_id) ON DELETE SET NULL;
        CREATE INDEX idx_threads_agent_id ON threads(agent_id);
        COMMENT ON COLUMN threads.agent_id IS 'ID of the agent used for this conversation thread. If NULL, uses account default agent.';
    END IF;
END $$;

-- Update existing threads to leave agent_id NULL (no default agents inserted)
-- (Optional: if you prefer to leave existing threads with NULL agent_id, this step can be omitted.)
-- UPDATE threads 
-- SET agent_id = NULL
-- WHERE agent_id IS NULL;

COMMIT;
BEGIN;

CREATE TABLE IF NOT EXISTS agent_versions (
    version_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id UUID NOT NULL REFERENCES agents(agent_id) ON DELETE CASCADE,
    version_number INTEGER NOT NULL,
    version_name VARCHAR(50) NOT NULL,
    system_prompt TEXT NOT NULL,
    configured_mcps JSONB DEFAULT '[]'::jsonb,
    custom_mcps JSONB DEFAULT '[]'::jsonb,
    agentpress_tools JSONB DEFAULT '{}'::jsonb,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    created_by UUID REFERENCES basejump.accounts(id),
    
    UNIQUE(agent_id, version_number),
    UNIQUE(agent_id, version_name)
);

-- Indexes for agent_versions
CREATE INDEX IF NOT EXISTS idx_agent_versions_agent_id ON agent_versions(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_versions_version_number ON agent_versions(version_number);
CREATE INDEX IF NOT EXISTS idx_agent_versions_is_active ON agent_versions(is_active);
CREATE INDEX IF NOT EXISTS idx_agent_versions_created_at ON agent_versions(created_at);

-- Add current version tracking to agents table
ALTER TABLE agents ADD COLUMN IF NOT EXISTS current_version_id UUID REFERENCES agent_versions(version_id);
ALTER TABLE agents ADD COLUMN IF NOT EXISTS version_count INTEGER DEFAULT 1;

-- Add index for current version
CREATE INDEX IF NOT EXISTS idx_agents_current_version ON agents(current_version_id);

-- Add version tracking to threads (which version is being used in this thread)
ALTER TABLE threads ADD COLUMN IF NOT EXISTS agent_version_id UUID REFERENCES agent_versions(version_id);

-- Add index for thread version
CREATE INDEX IF NOT EXISTS idx_threads_agent_version ON threads(agent_version_id);

-- Track version changes and history
CREATE TABLE IF NOT EXISTS agent_version_history (
    history_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id UUID NOT NULL REFERENCES agents(agent_id) ON DELETE CASCADE,
    version_id UUID NOT NULL REFERENCES agent_versions(version_id) ON DELETE CASCADE,
    action VARCHAR(50) NOT NULL, -- 'created', 'updated', 'activated', 'deactivated'
    changed_by UUID REFERENCES basejump.accounts(id),
    change_description TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for version history
CREATE INDEX IF NOT EXISTS idx_agent_version_history_agent_id ON agent_version_history(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_version_history_version_id ON agent_version_history(version_id);
CREATE INDEX IF NOT EXISTS idx_agent_version_history_created_at ON agent_version_history(created_at);

-- Update updated_at timestamp for agent_versions
CREATE OR REPLACE FUNCTION update_agent_versions_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Drop trigger if it exists, then create it
DROP TRIGGER IF EXISTS trigger_agent_versions_updated_at ON agent_versions;
CREATE TRIGGER trigger_agent_versions_updated_at
    BEFORE UPDATE ON agent_versions
    FOR EACH ROW
    EXECUTE FUNCTION update_agent_versions_updated_at();

-- Enable RLS on new tables
ALTER TABLE agent_versions ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_version_history ENABLE ROW LEVEL SECURITY;

-- Policies for agent_versions
DROP POLICY IF EXISTS agent_versions_select_policy ON agent_versions;
CREATE POLICY agent_versions_select_policy ON agent_versions
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM agents
            WHERE agents.agent_id = agent_versions.agent_id
            AND basejump.has_role_on_account(agents.account_id)
        )
    );

DROP POLICY IF EXISTS agent_versions_insert_policy ON agent_versions;
CREATE POLICY agent_versions_insert_policy ON agent_versions
    FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM agents
            WHERE agents.agent_id = agent_versions.agent_id
            AND basejump.has_role_on_account(agents.account_id, 'owner')
        )
    );

DROP POLICY IF EXISTS agent_versions_update_policy ON agent_versions;
CREATE POLICY agent_versions_update_policy ON agent_versions
    FOR UPDATE
    USING (
        EXISTS (
            SELECT 1 FROM agents
            WHERE agents.agent_id = agent_versions.agent_id
            AND basejump.has_role_on_account(agents.account_id, 'owner')
        )
    );

DROP POLICY IF EXISTS agent_versions_delete_policy ON agent_versions;
CREATE POLICY agent_versions_delete_policy ON agent_versions
    FOR DELETE
    USING (
        EXISTS (
            SELECT 1 FROM agents
            WHERE agents.agent_id = agent_versions.agent_id
            AND basejump.has_role_on_account(agents.account_id, 'owner')
        )
    );

-- Policies for agent_version_history
DROP POLICY IF EXISTS agent_version_history_select_policy ON agent_version_history;
CREATE POLICY agent_version_history_select_policy ON agent_version_history
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM agents
            WHERE agents.agent_id = agent_version_history.agent_id
            AND basejump.has_role_on_account(agents.account_id)
        )
    );

DROP POLICY IF EXISTS agent_version_history_insert_policy ON agent_version_history;
CREATE POLICY agent_version_history_insert_policy ON agent_version_history
    FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM agents
            WHERE agents.agent_id = agent_version_history.agent_id
            AND basejump.has_role_on_account(agents.account_id, 'owner')
        )
    );

-- Function to migrate existing agents to versioned system
CREATE OR REPLACE FUNCTION migrate_agents_to_versioned()
RETURNS void
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
    v_agent RECORD;
    v_version_id UUID;
BEGIN
    -- For each existing agent, create a v1 version
    FOR v_agent IN SELECT * FROM agents WHERE current_version_id IS NULL
    LOOP
        -- Create v1 version with current agent data
        INSERT INTO agent_versions (
            agent_id,
            version_number,
            version_name,
            system_prompt,
            configured_mcps,
            custom_mcps,
            agentpress_tools,
            is_active,
            created_by
        ) VALUES (
            v_agent.agent_id,
            1,
            'v1',
            v_agent.system_prompt,
            v_agent.configured_mcps,
            '[]'::jsonb, -- agents table doesn't have custom_mcps column
            v_agent.agentpress_tools,
            TRUE,
            v_agent.account_id
        ) RETURNING version_id INTO v_version_id;
        
        -- Update agent with current version
        UPDATE agents 
        SET current_version_id = v_version_id,
            version_count = 1
        WHERE agent_id = v_agent.agent_id;
        
        -- Add history entry
        INSERT INTO agent_version_history (
            agent_id,
            version_id,
            action,
            changed_by,
            change_description
        ) VALUES (
            v_agent.agent_id,
            v_version_id,
            'created',
            v_agent.account_id,
            'Initial version created from existing agent'
        );
    END LOOP;
END;
$$;

-- Function to create a new version of an agent
CREATE OR REPLACE FUNCTION create_agent_version(
    p_agent_id UUID,
    p_system_prompt TEXT,
    p_configured_mcps JSONB DEFAULT '[]'::jsonb,
    p_custom_mcps JSONB DEFAULT '[]'::jsonb,
    p_agentpress_tools JSONB DEFAULT '{}'::jsonb,
    p_created_by UUID DEFAULT NULL
)
RETURNS UUID
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
    v_version_id UUID;
    v_version_number INTEGER;
    v_version_name VARCHAR(50);
BEGIN
    -- Check if user has permission
    IF NOT EXISTS (
        SELECT 1 FROM agents 
        WHERE agent_id = p_agent_id 
        AND basejump.has_role_on_account(account_id, 'owner')
    ) THEN
        RAISE EXCEPTION 'Agent not found or access denied';
    END IF;
    
    -- Get next version number
    SELECT COALESCE(MAX(version_number), 0) + 1 INTO v_version_number
    FROM agent_versions
    WHERE agent_id = p_agent_id;
    
    -- Generate version name
    v_version_name := 'v' || v_version_number;
    
    -- Create new version
    INSERT INTO agent_versions (
        agent_id,
        version_number,
        version_name,
        system_prompt,
        configured_mcps,
        custom_mcps,
        agentpress_tools,
        is_active,
        created_by
    ) VALUES (
        p_agent_id,
        v_version_number,
        v_version_name,
        p_system_prompt,
        p_configured_mcps,
        p_custom_mcps,
        p_agentpress_tools,
        TRUE,
        p_created_by
    ) RETURNING version_id INTO v_version_id;
    
    -- Update agent version count
    UPDATE agents 
    SET version_count = v_version_number,
        current_version_id = v_version_id
    WHERE agent_id = p_agent_id;
    
    -- Add history entry
    INSERT INTO agent_version_history (
        agent_id,
        version_id,
        action,
        changed_by,
        change_description
    ) VALUES (
        p_agent_id,
        v_version_id,
        'created',
        p_created_by,
        'New version ' || v_version_name || ' created'
    );
    
    RETURN v_version_id;
END;
$$;

-- Function to switch agent to a different version
CREATE OR REPLACE FUNCTION switch_agent_version(
    p_agent_id UUID,
    p_version_id UUID,
    p_changed_by UUID DEFAULT NULL
)
RETURNS void
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Check if user has permission and version exists
    IF NOT EXISTS (
        SELECT 1 FROM agents a
        JOIN agent_versions av ON a.agent_id = av.agent_id
        WHERE a.agent_id = p_agent_id 
        AND av.version_id = p_version_id
        AND basejump.has_role_on_account(a.account_id, 'owner')
    ) THEN
        RAISE EXCEPTION 'Agent/version not found or access denied';
    END IF;
    
    -- Update current version
    UPDATE agents 
    SET current_version_id = p_version_id
    WHERE agent_id = p_agent_id;
    
    -- Add history entry
    INSERT INTO agent_version_history (
        agent_id,
        version_id,
        action,
        changed_by,
        change_description
    ) VALUES (
        p_agent_id,
        p_version_id,
        'activated',
        p_changed_by,
        'Switched to this version'
    );
END;
$$;

-- =====================================================
-- 9. RUN MIGRATION
-- =====================================================
-- Migrate existing agents to versioned system
SELECT migrate_agents_to_versioned();

COMMIT; 
BEGIN;

-- =====================================================
-- SECURE MCP CREDENTIAL ARCHITECTURE MIGRATION
-- =====================================================
-- This migration implements a secure architecture where:
-- 1. Agent templates contain MCP requirements (no credentials)
-- 2. User credentials are stored encrypted separately
-- 3. Agent instances combine templates with user credentials at runtime

-- =====================================================
-- 1. AGENT TEMPLATES TABLE
-- =====================================================
-- Stores marketplace agent templates without any credentials
CREATE TABLE IF NOT EXISTS agent_templates (
    template_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    creator_id UUID NOT NULL REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    system_prompt TEXT NOT NULL,
    mcp_requirements JSONB DEFAULT '[]'::jsonb, -- No credentials, just requirements
    agentpress_tools JSONB DEFAULT '{}'::jsonb,
    tags TEXT[] DEFAULT '{}',
    is_public BOOLEAN DEFAULT FALSE,
    marketplace_published_at TIMESTAMPTZ,
    download_count INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    avatar VARCHAR(10),
    avatar_color VARCHAR(7),
    metadata JSONB DEFAULT '{}'::jsonb
);

-- Indexes for agent_templates
CREATE INDEX IF NOT EXISTS idx_agent_templates_creator_id ON agent_templates(creator_id);
CREATE INDEX IF NOT EXISTS idx_agent_templates_is_public ON agent_templates(is_public);
CREATE INDEX IF NOT EXISTS idx_agent_templates_marketplace_published_at ON agent_templates(marketplace_published_at);
CREATE INDEX IF NOT EXISTS idx_agent_templates_download_count ON agent_templates(download_count);
CREATE INDEX IF NOT EXISTS idx_agent_templates_tags ON agent_templates USING gin(tags);
CREATE INDEX IF NOT EXISTS idx_agent_templates_created_at ON agent_templates(created_at);
CREATE INDEX IF NOT EXISTS idx_agent_templates_metadata ON agent_templates USING gin(metadata);

-- =====================================================
-- 2. USER MCP CREDENTIALS TABLE
-- =====================================================
-- Stores encrypted MCP credentials per user
CREATE TABLE IF NOT EXISTS user_mcp_credentials (
    credential_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    mcp_qualified_name VARCHAR(255) NOT NULL,
    display_name VARCHAR(255) NOT NULL,
    encrypted_config TEXT NOT NULL, -- Encrypted JSON config
    config_hash VARCHAR(64) NOT NULL, -- SHA-256 hash for integrity checking
    is_active BOOLEAN DEFAULT TRUE,
    last_used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Ensure one credential per user per MCP
    UNIQUE(account_id, mcp_qualified_name)
);

-- Indexes for user_mcp_credentials
CREATE INDEX IF NOT EXISTS idx_user_mcp_credentials_account_id ON user_mcp_credentials(account_id);
CREATE INDEX IF NOT EXISTS idx_user_mcp_credentials_mcp_name ON user_mcp_credentials(mcp_qualified_name);
CREATE INDEX IF NOT EXISTS idx_user_mcp_credentials_is_active ON user_mcp_credentials(is_active);
CREATE INDEX IF NOT EXISTS idx_user_mcp_credentials_last_used ON user_mcp_credentials(last_used_at);

-- =====================================================
-- 3. AGENT INSTANCES TABLE
-- =====================================================
-- Links templates with user credentials to create runnable agents
CREATE TABLE IF NOT EXISTS agent_instances (
    instance_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    template_id UUID REFERENCES agent_templates(template_id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    credential_mappings JSONB DEFAULT '{}'::jsonb, -- Maps MCP qualified_name to credential_id
    custom_system_prompt TEXT, -- Optional override of template system prompt
    is_active BOOLEAN DEFAULT TRUE,
    is_default BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    avatar VARCHAR(10),
    avatar_color VARCHAR(7),
    
    -- For backward compatibility, allow instances without templates (existing agents)
    CONSTRAINT check_template_or_legacy CHECK (
        template_id IS NOT NULL OR 
        (template_id IS NULL AND created_at < NOW()) -- Legacy agents
    )
);

-- Indexes for agent_instances
CREATE INDEX IF NOT EXISTS idx_agent_instances_template_id ON agent_instances(template_id);
CREATE INDEX IF NOT EXISTS idx_agent_instances_account_id ON agent_instances(account_id);
CREATE INDEX IF NOT EXISTS idx_agent_instances_is_active ON agent_instances(is_active);
CREATE INDEX IF NOT EXISTS idx_agent_instances_is_default ON agent_instances(is_default);
CREATE INDEX IF NOT EXISTS idx_agent_instances_created_at ON agent_instances(created_at);

-- Ensure only one default agent per account
CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_instances_account_default 
ON agent_instances(account_id, is_default) WHERE is_default = true;

-- =====================================================
-- 4. CREDENTIAL USAGE TRACKING
-- =====================================================
-- Track when and how credentials are used for auditing
CREATE TABLE IF NOT EXISTS credential_usage_log (
    log_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    credential_id UUID NOT NULL REFERENCES user_mcp_credentials(credential_id) ON DELETE CASCADE,
    instance_id UUID REFERENCES agent_instances(instance_id) ON DELETE SET NULL,
    action VARCHAR(50) NOT NULL, -- 'connect', 'tool_call', 'disconnect'
    success BOOLEAN NOT NULL,
    error_message TEXT,
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for credential_usage_log
CREATE INDEX IF NOT EXISTS idx_credential_usage_log_credential_id ON credential_usage_log(credential_id);
CREATE INDEX IF NOT EXISTS idx_credential_usage_log_instance_id ON credential_usage_log(instance_id);
CREATE INDEX IF NOT EXISTS idx_credential_usage_log_created_at ON credential_usage_log(created_at);
CREATE INDEX IF NOT EXISTS idx_credential_usage_log_action ON credential_usage_log(action);

-- =====================================================
-- 5. UPDATE TRIGGERS
-- =====================================================
-- Update triggers for updated_at timestamps
CREATE OR REPLACE FUNCTION update_updated_at_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply triggers
DROP TRIGGER IF EXISTS trigger_agent_templates_updated_at ON agent_templates;
CREATE TRIGGER trigger_agent_templates_updated_at
    BEFORE UPDATE ON agent_templates
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_timestamp();

DROP TRIGGER IF EXISTS trigger_user_mcp_credentials_updated_at ON user_mcp_credentials;
CREATE TRIGGER trigger_user_mcp_credentials_updated_at
    BEFORE UPDATE ON user_mcp_credentials
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_timestamp();

DROP TRIGGER IF EXISTS trigger_agent_instances_updated_at ON agent_instances;
CREATE TRIGGER trigger_agent_instances_updated_at
    BEFORE UPDATE ON agent_instances
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_timestamp();

-- =====================================================
-- 6. ROW LEVEL SECURITY POLICIES
-- =====================================================

-- Enable RLS on all new tables
ALTER TABLE agent_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_mcp_credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_instances ENABLE ROW LEVEL SECURITY;
ALTER TABLE credential_usage_log ENABLE ROW LEVEL SECURITY;

-- Agent Templates Policies
DROP POLICY IF EXISTS agent_templates_select_policy ON agent_templates;
CREATE POLICY agent_templates_select_policy ON agent_templates
    FOR SELECT
    USING (
        is_public = true OR 
        basejump.has_role_on_account(creator_id)
    );

DROP POLICY IF EXISTS agent_templates_insert_policy ON agent_templates;
CREATE POLICY agent_templates_insert_policy ON agent_templates
    FOR INSERT
    WITH CHECK (basejump.has_role_on_account(creator_id, 'owner'));

DROP POLICY IF EXISTS agent_templates_update_policy ON agent_templates;
CREATE POLICY agent_templates_update_policy ON agent_templates
    FOR UPDATE
    USING (basejump.has_role_on_account(creator_id, 'owner'));

DROP POLICY IF EXISTS agent_templates_delete_policy ON agent_templates;
CREATE POLICY agent_templates_delete_policy ON agent_templates
    FOR DELETE
    USING (basejump.has_role_on_account(creator_id, 'owner'));

-- User MCP Credentials Policies (users can only access their own credentials)
DROP POLICY IF EXISTS user_mcp_credentials_select_policy ON user_mcp_credentials;
CREATE POLICY user_mcp_credentials_select_policy ON user_mcp_credentials
    FOR SELECT
    USING (basejump.has_role_on_account(account_id));

DROP POLICY IF EXISTS user_mcp_credentials_insert_policy ON user_mcp_credentials;
CREATE POLICY user_mcp_credentials_insert_policy ON user_mcp_credentials
    FOR INSERT
    WITH CHECK (basejump.has_role_on_account(account_id, 'owner'));

DROP POLICY IF EXISTS user_mcp_credentials_update_policy ON user_mcp_credentials;
CREATE POLICY user_mcp_credentials_update_policy ON user_mcp_credentials
    FOR UPDATE
    USING (basejump.has_role_on_account(account_id, 'owner'));

DROP POLICY IF EXISTS user_mcp_credentials_delete_policy ON user_mcp_credentials;
CREATE POLICY user_mcp_credentials_delete_policy ON user_mcp_credentials
    FOR DELETE
    USING (basejump.has_role_on_account(account_id, 'owner'));

-- Agent Instances Policies
DROP POLICY IF EXISTS agent_instances_select_policy ON agent_instances;
CREATE POLICY agent_instances_select_policy ON agent_instances
    FOR SELECT
    USING (basejump.has_role_on_account(account_id));

DROP POLICY IF EXISTS agent_instances_insert_policy ON agent_instances;
CREATE POLICY agent_instances_insert_policy ON agent_instances
    FOR INSERT
    WITH CHECK (basejump.has_role_on_account(account_id, 'owner'));

DROP POLICY IF EXISTS agent_instances_update_policy ON agent_instances;
CREATE POLICY agent_instances_update_policy ON agent_instances
    FOR UPDATE
    USING (basejump.has_role_on_account(account_id, 'owner'));

DROP POLICY IF EXISTS agent_instances_delete_policy ON agent_instances;
CREATE POLICY agent_instances_delete_policy ON agent_instances
    FOR DELETE
    USING (basejump.has_role_on_account(account_id, 'owner') AND is_default = false);

-- Credential Usage Log Policies
DROP POLICY IF EXISTS credential_usage_log_select_policy ON credential_usage_log;
CREATE POLICY credential_usage_log_select_policy ON credential_usage_log
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM user_mcp_credentials 
            WHERE user_mcp_credentials.credential_id = credential_usage_log.credential_id
            AND basejump.has_role_on_account(user_mcp_credentials.account_id)
        )
    );

DROP POLICY IF EXISTS credential_usage_log_insert_policy ON credential_usage_log;
CREATE POLICY credential_usage_log_insert_policy ON credential_usage_log
    FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM user_mcp_credentials 
            WHERE user_mcp_credentials.credential_id = credential_usage_log.credential_id
            AND basejump.has_role_on_account(user_mcp_credentials.account_id)
        )
    );

-- =====================================================
-- 7. HELPER FUNCTIONS
-- =====================================================

-- Function to create agent template from existing agent
CREATE OR REPLACE FUNCTION create_template_from_agent(
    p_agent_id UUID,
    p_creator_id UUID
)
RETURNS UUID
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
    v_template_id UUID;
    v_agent agents%ROWTYPE;
    v_mcp_requirements JSONB := '[]'::jsonb;
    v_mcp_config JSONB;
BEGIN
    -- Get the agent
    SELECT * INTO v_agent FROM agents WHERE agent_id = p_agent_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Agent not found';
    END IF;
    
    -- Check ownership
    IF NOT basejump.has_role_on_account(v_agent.account_id, 'owner') THEN
        RAISE EXCEPTION 'Access denied';
    END IF;
    
    -- Extract MCP requirements (remove credentials)
    FOR v_mcp_config IN SELECT * FROM jsonb_array_elements(v_agent.configured_mcps)
    LOOP
        v_mcp_requirements := v_mcp_requirements || jsonb_build_object(
            'qualifiedName', v_mcp_config->>'qualifiedName',
            'name', v_mcp_config->>'name',
            'enabledTools', v_mcp_config->'enabledTools',
            'requiredConfig', (
                SELECT jsonb_agg(key) 
                FROM jsonb_object_keys(v_mcp_config->'config') AS key
            )
        );
    END LOOP;
    
    -- Create template
    INSERT INTO agent_templates (
        creator_id,
        name,
        description,
        system_prompt,
        mcp_requirements,
        agentpress_tools,
        tags,
        avatar,
        avatar_color
    ) VALUES (
        p_creator_id,
        v_agent.name,
        v_agent.description,
        v_agent.system_prompt,
        v_mcp_requirements,
        v_agent.agentpress_tools,
        v_agent.tags,
        v_agent.avatar,
        v_agent.avatar_color
    ) RETURNING template_id INTO v_template_id;
    
    RETURN v_template_id;
END;
$$;

-- Function to install template as agent instance
CREATE OR REPLACE FUNCTION install_template_as_instance(
    p_template_id UUID,
    p_account_id UUID,
    p_instance_name VARCHAR(255) DEFAULT NULL
)
RETURNS UUID
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
    v_instance_id UUID;
    v_template agent_templates%ROWTYPE;
    v_instance_name VARCHAR(255);
    v_credential_mappings JSONB := '{}'::jsonb;
    v_mcp_req JSONB;
    v_credential_id UUID;
BEGIN
    -- Get template
    SELECT * INTO v_template FROM agent_templates WHERE template_id = p_template_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Template not found';
    END IF;
    
    -- Check if template is public or user owns it
    IF NOT (v_template.is_public OR basejump.has_role_on_account(v_template.creator_id)) THEN
        RAISE EXCEPTION 'Access denied to template';
    END IF;
    
    -- Set instance name
    v_instance_name := COALESCE(p_instance_name, v_template.name || ' (from marketplace)');
    
    -- Build credential mappings
    FOR v_mcp_req IN SELECT * FROM jsonb_array_elements(v_template.mcp_requirements)
    LOOP
        -- Find user's credential for this MCP
        SELECT credential_id INTO v_credential_id
        FROM user_mcp_credentials
        WHERE account_id = p_account_id 
        AND mcp_qualified_name = (v_mcp_req->>'qualifiedName')
        AND is_active = true;
        
        IF v_credential_id IS NOT NULL THEN
            v_credential_mappings := v_credential_mappings || 
                jsonb_build_object(v_mcp_req->>'qualifiedName', v_credential_id);
        END IF;
    END LOOP;
    
    -- Create agent instance
    INSERT INTO agent_instances (
        template_id,
        account_id,
        name,
        description,
        credential_mappings,
        avatar,
        avatar_color
    ) VALUES (
        p_template_id,
        p_account_id,
        v_instance_name,
        v_template.description,
        v_credential_mappings,
        v_template.avatar,
        v_template.avatar_color
    ) RETURNING instance_id INTO v_instance_id;
    
    -- Update template download count
    UPDATE agent_templates 
    SET download_count = download_count + 1 
    WHERE template_id = p_template_id;
    
    RETURN v_instance_id;
END;
$$;

-- Function to get missing credentials for template
CREATE OR REPLACE FUNCTION get_missing_credentials_for_template(
    p_template_id UUID,
    p_account_id UUID
)
RETURNS TABLE (
    qualified_name VARCHAR(255),
    display_name VARCHAR(255),
    required_config TEXT[]
)
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        (mcp_req->>'qualifiedName')::VARCHAR(255) as qualified_name,
        (mcp_req->>'name')::VARCHAR(255) as display_name,
        ARRAY(SELECT jsonb_array_elements_text(mcp_req->'requiredConfig')) as required_config
    FROM agent_templates t,
         jsonb_array_elements(t.mcp_requirements) as mcp_req
    WHERE t.template_id = p_template_id
    AND NOT EXISTS (
        SELECT 1 FROM user_mcp_credentials c
        WHERE c.account_id = p_account_id
        AND c.mcp_qualified_name = (mcp_req->>'qualifiedName')
        AND c.is_active = true
    );
END;
$$;

GRANT EXECUTE ON FUNCTION create_template_from_agent(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION install_template_as_instance(UUID, UUID, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION get_missing_credentials_for_template(UUID, UUID) TO authenticated;

GRANT ALL PRIVILEGES ON TABLE agent_templates TO authenticated, service_role;
GRANT ALL PRIVILEGES ON TABLE user_mcp_credentials TO authenticated, service_role;
GRANT ALL PRIVILEGES ON TABLE agent_instances TO authenticated, service_role;
GRANT ALL PRIVILEGES ON TABLE credential_usage_log TO authenticated, service_role;

COMMIT; 
BEGIN;

-- Add marketplace fields to agents table
ALTER TABLE agents ADD COLUMN IF NOT EXISTS is_public BOOLEAN DEFAULT false;
ALTER TABLE agents ADD COLUMN IF NOT EXISTS marketplace_published_at TIMESTAMPTZ;
ALTER TABLE agents ADD COLUMN IF NOT EXISTS download_count INTEGER DEFAULT 0;
ALTER TABLE agents ADD COLUMN IF NOT EXISTS tags TEXT[] DEFAULT '{}';

CREATE INDEX IF NOT EXISTS idx_agents_is_public ON agents(is_public);
CREATE INDEX IF NOT EXISTS idx_agents_marketplace_published_at ON agents(marketplace_published_at);
CREATE INDEX IF NOT EXISTS idx_agents_download_count ON agents(download_count);
CREATE INDEX IF NOT EXISTS idx_agents_tags ON agents USING gin(tags);

CREATE TABLE IF NOT EXISTS user_agent_library (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_account_id UUID NOT NULL REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    original_agent_id UUID NOT NULL REFERENCES agents(agent_id) ON DELETE CASCADE,
    agent_id UUID NOT NULL REFERENCES agents(agent_id) ON DELETE CASCADE,
    added_at TIMESTAMPTZ DEFAULT NOW(),
    is_favorite BOOLEAN DEFAULT false,
    
    UNIQUE(user_account_id, original_agent_id)
);

CREATE INDEX IF NOT EXISTS idx_user_agent_library_user_account ON user_agent_library(user_account_id);
CREATE INDEX IF NOT EXISTS idx_user_agent_library_original_agent ON user_agent_library(original_agent_id);
CREATE INDEX IF NOT EXISTS idx_user_agent_library_agent_id ON user_agent_library(agent_id);
CREATE INDEX IF NOT EXISTS idx_user_agent_library_added_at ON user_agent_library(added_at);

ALTER TABLE user_agent_library ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS user_agent_library_select_own ON user_agent_library;
DROP POLICY IF EXISTS user_agent_library_insert_own ON user_agent_library;
DROP POLICY IF EXISTS user_agent_library_update_own ON user_agent_library;
DROP POLICY IF EXISTS user_agent_library_delete_own ON user_agent_library;

CREATE POLICY user_agent_library_select_own ON user_agent_library
    FOR SELECT
    USING (basejump.has_role_on_account(user_account_id));

CREATE POLICY user_agent_library_insert_own ON user_agent_library
    FOR INSERT
    WITH CHECK (basejump.has_role_on_account(user_account_id));

CREATE POLICY user_agent_library_update_own ON user_agent_library
    FOR UPDATE
    USING (basejump.has_role_on_account(user_account_id));

CREATE POLICY user_agent_library_delete_own ON user_agent_library
    FOR DELETE
    USING (basejump.has_role_on_account(user_account_id));

DROP POLICY IF EXISTS agents_select_marketplace ON agents;
CREATE POLICY agents_select_marketplace ON agents
    FOR SELECT
    USING (
        is_public = true OR
        basejump.has_role_on_account(account_id)
    );

CREATE OR REPLACE FUNCTION publish_agent_to_marketplace(p_agent_id UUID)
RETURNS void
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM agents 
        WHERE agent_id = p_agent_id 
        AND basejump.has_role_on_account(account_id, 'owner')
    ) THEN
        RAISE EXCEPTION 'Agent not found or access denied';
    END IF;
    
    UPDATE agents 
    SET 
        is_public = true,
        marketplace_published_at = NOW()
    WHERE agent_id = p_agent_id;
END;
$$;

CREATE OR REPLACE FUNCTION unpublish_agent_from_marketplace(p_agent_id UUID)
RETURNS void
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM agents 
        WHERE agent_id = p_agent_id 
        AND basejump.has_role_on_account(account_id, 'owner')
    ) THEN
        RAISE EXCEPTION 'Agent not found or access denied';
    END IF;
    
    UPDATE agents 
    SET 
        is_public = false,
        marketplace_published_at = NULL
    WHERE agent_id = p_agent_id;
END;
$$;

-- Drop existing functions to avoid conflicts
DROP FUNCTION IF EXISTS add_agent_to_library(UUID);
DROP FUNCTION IF EXISTS add_agent_to_library(UUID, UUID);

CREATE OR REPLACE FUNCTION add_agent_to_library(
    p_original_agent_id UUID,
    p_user_account_id UUID
)
RETURNS UUID
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
    v_new_agent_id UUID;
    v_original_agent agents%ROWTYPE;
BEGIN
    SELECT * INTO v_original_agent
    FROM agents 
    WHERE agent_id = p_original_agent_id AND is_public = true;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Agent not found or not public';
    END IF;
    
    IF EXISTS (
        SELECT 1 FROM user_agent_library 
        WHERE user_account_id = p_user_account_id 
        AND original_agent_id = p_original_agent_id
    ) THEN
        RAISE EXCEPTION 'Agent already in your library';
    END IF;
    
    INSERT INTO agents (
        account_id,
        name,
        description,
        system_prompt,
        configured_mcps,
        agentpress_tools,
        is_default,
        is_public,
        tags,
        avatar,
        avatar_color
    ) VALUES (
        p_user_account_id,
        v_original_agent.name || ' (from marketplace)',
        v_original_agent.description,
        v_original_agent.system_prompt,
        v_original_agent.configured_mcps,
        v_original_agent.agentpress_tools,
        false,
        false,
        v_original_agent.tags,
        v_original_agent.avatar,
        v_original_agent.avatar_color
    ) RETURNING agent_id INTO v_new_agent_id;
    
    INSERT INTO user_agent_library (
        user_account_id,
        original_agent_id,
        agent_id
    ) VALUES (
        p_user_account_id,
        p_original_agent_id,
        v_new_agent_id
    );
    
    UPDATE agents 
    SET download_count = download_count + 1 
    WHERE agent_id = p_original_agent_id;
    
    RETURN v_new_agent_id;
END;
$$;

-- Drop existing function to avoid type conflicts
DROP FUNCTION IF EXISTS get_marketplace_agents(INTEGER, INTEGER, TEXT, TEXT[]);

CREATE OR REPLACE FUNCTION get_marketplace_agents(
    p_limit INTEGER DEFAULT 50,
    p_offset INTEGER DEFAULT 0,
    p_search TEXT DEFAULT NULL,
    p_tags TEXT[] DEFAULT NULL
)
RETURNS TABLE (
    agent_id UUID,
    name VARCHAR(255),
    description TEXT,
    system_prompt TEXT,
    configured_mcps JSONB,
    agentpress_tools JSONB,
    tags TEXT[],
    download_count INTEGER,
    marketplace_published_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    creator_name TEXT,
    avatar TEXT,
    avatar_color TEXT
)
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        a.agent_id,
        a.name,
        a.description,
        a.system_prompt,
        a.configured_mcps,
        a.agentpress_tools,
        a.tags,
        a.download_count,
        a.marketplace_published_at,
        a.created_at,
        COALESCE(acc.name, 'Anonymous')::TEXT as creator_name,
        a.avatar::TEXT,
        a.avatar_color::TEXT
    FROM agents a
    LEFT JOIN basejump.accounts acc ON a.account_id = acc.id
    WHERE a.is_public = true
    AND (p_search IS NULL OR 
         a.name ILIKE '%' || p_search || '%' OR 
         a.description ILIKE '%' || p_search || '%')
    AND (p_tags IS NULL OR a.tags && p_tags)
    ORDER BY a.marketplace_published_at DESC
    LIMIT p_limit
    OFFSET p_offset;
END;
$$;

GRANT EXECUTE ON FUNCTION publish_agent_to_marketplace TO authenticated;
GRANT EXECUTE ON FUNCTION unpublish_agent_from_marketplace TO authenticated;
GRANT EXECUTE ON FUNCTION add_agent_to_library(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION get_marketplace_agents(INTEGER, INTEGER, TEXT, TEXT[]) TO authenticated, anon;
GRANT ALL PRIVILEGES ON TABLE user_agent_library TO authenticated, service_role;

COMMIT; 
-- Add metadata column to threads table to store additional context
ALTER TABLE threads ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}'::jsonb;

-- Create index for metadata queries
CREATE INDEX IF NOT EXISTS idx_threads_metadata ON threads USING GIN (metadata);

-- Comment on the column
COMMENT ON COLUMN threads.metadata IS 'Stores additional thread context like agent builder mode and target agent';

-- Add agent_id to messages table to support per-message agent selection
ALTER TABLE messages ADD COLUMN IF NOT EXISTS agent_id UUID REFERENCES agents(agent_id) ON DELETE SET NULL;

-- Create index for message agent queries
CREATE INDEX IF NOT EXISTS idx_messages_agent_id ON messages(agent_id);

-- Comment on the new column
COMMENT ON COLUMN messages.agent_id IS 'ID of the agent that generated this message. For user messages, this represents the agent that should respond to this message.';

-- Make thread agent_id nullable to allow agent-agnostic threads
-- This is already nullable from the existing migration, but we'll add a comment
COMMENT ON COLUMN threads.agent_id IS 'Optional default agent for the thread. If NULL, agent can be selected per message.'; 
BEGIN;

ALTER TABLE agents ADD COLUMN IF NOT EXISTS custom_mcps JSONB DEFAULT '[]'::jsonb;

CREATE INDEX IF NOT EXISTS idx_agents_custom_mcps ON agents USING GIN (custom_mcps);

COMMENT ON COLUMN agents.custom_mcps IS 'Stores custom MCP server configurations added by users (JSON or SSE endpoints)';

COMMIT; 
BEGIN;

-- Fix encrypted_config column type to store base64 strings properly
-- Change from BYTEA to TEXT to avoid encoding issues

-- Only proceed if the table exists
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'user_mcp_credentials') THEN
        DELETE FROM user_mcp_credentials;
        ALTER TABLE user_mcp_credentials 
        ALTER COLUMN encrypted_config TYPE TEXT;
    END IF;
END $$;

COMMIT; 
BEGIN;

CREATE TABLE user_mcp_credential_profiles (
    profile_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL,
    mcp_qualified_name TEXT NOT NULL,
    profile_name TEXT NOT NULL,
    display_name TEXT NOT NULL,
    encrypted_config TEXT NOT NULL,
    config_hash TEXT NOT NULL,
    is_active BOOLEAN DEFAULT true,
    is_default BOOLEAN DEFAULT false,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    last_used_at TIMESTAMP WITH TIME ZONE,
    
    UNIQUE(account_id, mcp_qualified_name, profile_name),
    CONSTRAINT fk_credential_profiles_account 
        FOREIGN KEY (account_id) 
        REFERENCES auth.users(id) 
        ON DELETE CASCADE
);

CREATE INDEX idx_credential_profiles_account_mcp 
    ON user_mcp_credential_profiles(account_id, mcp_qualified_name);

CREATE INDEX idx_credential_profiles_account_active 
    ON user_mcp_credential_profiles(account_id, is_active) 
    WHERE is_active = true;

CREATE INDEX idx_credential_profiles_default 
    ON user_mcp_credential_profiles(account_id, mcp_qualified_name, is_default) 
    WHERE is_default = true;

ALTER TABLE user_mcp_credential_profiles ENABLE ROW LEVEL SECURITY;

CREATE POLICY credential_profiles_user_access 
    ON user_mcp_credential_profiles 
    FOR ALL 
    USING (auth.uid() = account_id);

ALTER TABLE workflows 
ADD COLUMN mcp_credential_mappings JSONB DEFAULT '{}';

COMMENT ON COLUMN workflows.mcp_credential_mappings IS 
'JSON mapping of MCP qualified names to credential profile IDs. Example: {"@smithery-ai/slack": "profile_id_123", "github": "profile_id_456"}';

-- Migrate existing credentials if the table exists
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'user_mcp_credentials') THEN
        INSERT INTO user_mcp_credential_profiles (
            account_id,
            mcp_qualified_name,
            profile_name,
            display_name,
            encrypted_config,
            config_hash,
            is_active,
            is_default,
            created_at,
            updated_at,
            last_used_at
        )
        SELECT 
            account_id,
            mcp_qualified_name,
            'Default' as profile_name,
            COALESCE(display_name, mcp_qualified_name) as display_name,
            encrypted_config,
            config_hash,
            is_active,
            true as is_default,
            created_at,
            updated_at,
            last_used_at
        FROM user_mcp_credentials
        WHERE is_active = true;
    END IF;
END $$;

CREATE OR REPLACE FUNCTION ensure_single_default_profile()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.is_default = true THEN
        UPDATE user_mcp_credential_profiles 
        SET is_default = false, updated_at = NOW()
        WHERE account_id = NEW.account_id 
          AND mcp_qualified_name = NEW.mcp_qualified_name 
          AND profile_id != NEW.profile_id
          AND is_default = true;
    END IF;
    
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_ensure_single_default_profile
    BEFORE INSERT OR UPDATE ON user_mcp_credential_profiles
    FOR EACH ROW
    EXECUTE FUNCTION ensure_single_default_profile();

CREATE OR REPLACE FUNCTION update_credential_profile_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_update_credential_profile_timestamp
    BEFORE UPDATE ON user_mcp_credential_profiles
    FOR EACH ROW
    EXECUTE FUNCTION update_credential_profile_timestamp();

COMMIT; 
BEGIN;

-- =====================================================
-- SECURE MCP CREDENTIAL ARCHITECTURE MIGRATION
-- =====================================================
-- This migration implements a secure architecture where:
-- 1. Agent templates contain MCP requirements (no credentials)
-- 2. User credentials are stored encrypted separately
-- 3. Agent instances combine templates with user credentials at runtime

-- =====================================================
-- 1. AGENT TEMPLATES TABLE
-- =====================================================
-- Stores marketplace agent templates without any credentials
CREATE TABLE IF NOT EXISTS agent_templates (
    template_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    creator_id UUID NOT NULL REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    system_prompt TEXT NOT NULL,
    mcp_requirements JSONB DEFAULT '[]'::jsonb, -- No credentials, just requirements
    agentpress_tools JSONB DEFAULT '{}'::jsonb,
    tags TEXT[] DEFAULT '{}',
    is_public BOOLEAN DEFAULT FALSE,
    marketplace_published_at TIMESTAMPTZ,
    download_count INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    avatar VARCHAR(10),
    avatar_color VARCHAR(7),
    metadata JSONB DEFAULT '{}'::jsonb
);

-- Indexes for agent_templates
CREATE INDEX IF NOT EXISTS idx_agent_templates_creator_id ON agent_templates(creator_id);
CREATE INDEX IF NOT EXISTS idx_agent_templates_is_public ON agent_templates(is_public);
CREATE INDEX IF NOT EXISTS idx_agent_templates_marketplace_published_at ON agent_templates(marketplace_published_at);
CREATE INDEX IF NOT EXISTS idx_agent_templates_download_count ON agent_templates(download_count);
CREATE INDEX IF NOT EXISTS idx_agent_templates_tags ON agent_templates USING gin(tags);
CREATE INDEX IF NOT EXISTS idx_agent_templates_created_at ON agent_templates(created_at);
CREATE INDEX IF NOT EXISTS idx_agent_templates_metadata ON agent_templates USING gin(metadata);

-- =====================================================
-- 2. USER MCP CREDENTIALS TABLE
-- =====================================================
-- Stores encrypted MCP credentials per user
CREATE TABLE IF NOT EXISTS user_mcp_credentials (
    credential_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id UUID NOT NULL REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    mcp_qualified_name VARCHAR(255) NOT NULL,
    display_name VARCHAR(255) NOT NULL,
    encrypted_config TEXT NOT NULL, -- Encrypted JSON config
    config_hash VARCHAR(64) NOT NULL, -- SHA-256 hash for integrity checking
    is_active BOOLEAN DEFAULT TRUE,
    last_used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    
    -- Ensure one credential per user per MCP
    UNIQUE(account_id, mcp_qualified_name)
);

-- Indexes for user_mcp_credentials
CREATE INDEX IF NOT EXISTS idx_user_mcp_credentials_account_id ON user_mcp_credentials(account_id);
CREATE INDEX IF NOT EXISTS idx_user_mcp_credentials_mcp_name ON user_mcp_credentials(mcp_qualified_name);
CREATE INDEX IF NOT EXISTS idx_user_mcp_credentials_is_active ON user_mcp_credentials(is_active);
CREATE INDEX IF NOT EXISTS idx_user_mcp_credentials_last_used ON user_mcp_credentials(last_used_at);

-- =====================================================
-- 3. AGENT INSTANCES TABLE
-- =====================================================
-- Links templates with user credentials to create runnable agents
CREATE TABLE IF NOT EXISTS agent_instances (
    instance_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    template_id UUID REFERENCES agent_templates(template_id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    credential_mappings JSONB DEFAULT '{}'::jsonb, -- Maps MCP qualified_name to credential_id
    custom_system_prompt TEXT, -- Optional override of template system prompt
    is_active BOOLEAN DEFAULT TRUE,
    is_default BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    avatar VARCHAR(10),
    avatar_color VARCHAR(7),
    
    -- For backward compatibility, allow instances without templates (existing agents)
    CONSTRAINT check_template_or_legacy CHECK (
        template_id IS NOT NULL OR 
        (template_id IS NULL AND created_at < NOW()) -- Legacy agents
    )
);

-- Indexes for agent_instances
CREATE INDEX IF NOT EXISTS idx_agent_instances_template_id ON agent_instances(template_id);
CREATE INDEX IF NOT EXISTS idx_agent_instances_account_id ON agent_instances(account_id);
CREATE INDEX IF NOT EXISTS idx_agent_instances_is_active ON agent_instances(is_active);
CREATE INDEX IF NOT EXISTS idx_agent_instances_is_default ON agent_instances(is_default);
CREATE INDEX IF NOT EXISTS idx_agent_instances_created_at ON agent_instances(created_at);

-- Ensure only one default agent per account
CREATE UNIQUE INDEX IF NOT EXISTS idx_agent_instances_account_default 
ON agent_instances(account_id, is_default) WHERE is_default = true;

-- =====================================================
-- 4. CREDENTIAL USAGE TRACKING
-- =====================================================
-- Track when and how credentials are used for auditing
CREATE TABLE IF NOT EXISTS credential_usage_log (
    log_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    credential_id UUID NOT NULL REFERENCES user_mcp_credentials(credential_id) ON DELETE CASCADE,
    instance_id UUID REFERENCES agent_instances(instance_id) ON DELETE SET NULL,
    action VARCHAR(50) NOT NULL, -- 'connect', 'tool_call', 'disconnect'
    success BOOLEAN NOT NULL,
    error_message TEXT,
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Indexes for credential_usage_log
CREATE INDEX IF NOT EXISTS idx_credential_usage_log_credential_id ON credential_usage_log(credential_id);
CREATE INDEX IF NOT EXISTS idx_credential_usage_log_instance_id ON credential_usage_log(instance_id);
CREATE INDEX IF NOT EXISTS idx_credential_usage_log_created_at ON credential_usage_log(created_at);
CREATE INDEX IF NOT EXISTS idx_credential_usage_log_action ON credential_usage_log(action);

-- =====================================================
-- 5. UPDATE TRIGGERS
-- =====================================================
-- Update triggers for updated_at timestamps
CREATE OR REPLACE FUNCTION update_updated_at_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Apply triggers
DROP TRIGGER IF EXISTS trigger_agent_templates_updated_at ON agent_templates;
CREATE TRIGGER trigger_agent_templates_updated_at
    BEFORE UPDATE ON agent_templates
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_timestamp();

DROP TRIGGER IF EXISTS trigger_user_mcp_credentials_updated_at ON user_mcp_credentials;
CREATE TRIGGER trigger_user_mcp_credentials_updated_at
    BEFORE UPDATE ON user_mcp_credentials
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_timestamp();

DROP TRIGGER IF EXISTS trigger_agent_instances_updated_at ON agent_instances;
CREATE TRIGGER trigger_agent_instances_updated_at
    BEFORE UPDATE ON agent_instances
    FOR EACH ROW
    EXECUTE FUNCTION update_updated_at_timestamp();

-- =====================================================
-- 6. ROW LEVEL SECURITY POLICIES
-- =====================================================

-- Enable RLS on all new tables
ALTER TABLE agent_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE user_mcp_credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_instances ENABLE ROW LEVEL SECURITY;
ALTER TABLE credential_usage_log ENABLE ROW LEVEL SECURITY;

-- Agent Templates Policies
DROP POLICY IF EXISTS agent_templates_select_policy ON agent_templates;
CREATE POLICY agent_templates_select_policy ON agent_templates
    FOR SELECT
    USING (
        is_public = true OR 
        basejump.has_role_on_account(creator_id)
    );

DROP POLICY IF EXISTS agent_templates_insert_policy ON agent_templates;
CREATE POLICY agent_templates_insert_policy ON agent_templates
    FOR INSERT
    WITH CHECK (basejump.has_role_on_account(creator_id, 'owner'));

DROP POLICY IF EXISTS agent_templates_update_policy ON agent_templates;
CREATE POLICY agent_templates_update_policy ON agent_templates
    FOR UPDATE
    USING (basejump.has_role_on_account(creator_id, 'owner'));

DROP POLICY IF EXISTS agent_templates_delete_policy ON agent_templates;
CREATE POLICY agent_templates_delete_policy ON agent_templates
    FOR DELETE
    USING (basejump.has_role_on_account(creator_id, 'owner'));

-- User MCP Credentials Policies (users can only access their own credentials)
DROP POLICY IF EXISTS user_mcp_credentials_select_policy ON user_mcp_credentials;
CREATE POLICY user_mcp_credentials_select_policy ON user_mcp_credentials
    FOR SELECT
    USING (basejump.has_role_on_account(account_id));

DROP POLICY IF EXISTS user_mcp_credentials_insert_policy ON user_mcp_credentials;
CREATE POLICY user_mcp_credentials_insert_policy ON user_mcp_credentials
    FOR INSERT
    WITH CHECK (basejump.has_role_on_account(account_id, 'owner'));

DROP POLICY IF EXISTS user_mcp_credentials_update_policy ON user_mcp_credentials;
CREATE POLICY user_mcp_credentials_update_policy ON user_mcp_credentials
    FOR UPDATE
    USING (basejump.has_role_on_account(account_id, 'owner'));

DROP POLICY IF EXISTS user_mcp_credentials_delete_policy ON user_mcp_credentials;
CREATE POLICY user_mcp_credentials_delete_policy ON user_mcp_credentials
    FOR DELETE
    USING (basejump.has_role_on_account(account_id, 'owner'));

-- Agent Instances Policies
DROP POLICY IF EXISTS agent_instances_select_policy ON agent_instances;
CREATE POLICY agent_instances_select_policy ON agent_instances
    FOR SELECT
    USING (basejump.has_role_on_account(account_id));

DROP POLICY IF EXISTS agent_instances_insert_policy ON agent_instances;
CREATE POLICY agent_instances_insert_policy ON agent_instances
    FOR INSERT
    WITH CHECK (basejump.has_role_on_account(account_id, 'owner'));

DROP POLICY IF EXISTS agent_instances_update_policy ON agent_instances;
CREATE POLICY agent_instances_update_policy ON agent_instances
    FOR UPDATE
    USING (basejump.has_role_on_account(account_id, 'owner'));

DROP POLICY IF EXISTS agent_instances_delete_policy ON agent_instances;
CREATE POLICY agent_instances_delete_policy ON agent_instances
    FOR DELETE
    USING (basejump.has_role_on_account(account_id, 'owner') AND is_default = false);

-- Credential Usage Log Policies
DROP POLICY IF EXISTS credential_usage_log_select_policy ON credential_usage_log;
CREATE POLICY credential_usage_log_select_policy ON credential_usage_log
    FOR SELECT
    USING (
        EXISTS (
            SELECT 1 FROM user_mcp_credentials 
            WHERE user_mcp_credentials.credential_id = credential_usage_log.credential_id
            AND basejump.has_role_on_account(user_mcp_credentials.account_id)
        )
    );

DROP POLICY IF EXISTS credential_usage_log_insert_policy ON credential_usage_log;
CREATE POLICY credential_usage_log_insert_policy ON credential_usage_log
    FOR INSERT
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM user_mcp_credentials 
            WHERE user_mcp_credentials.credential_id = credential_usage_log.credential_id
            AND basejump.has_role_on_account(user_mcp_credentials.account_id)
        )
    );

-- =====================================================
-- 7. HELPER FUNCTIONS
-- =====================================================

-- Function to create agent template from existing agent
CREATE OR REPLACE FUNCTION create_template_from_agent(
    p_agent_id UUID,
    p_creator_id UUID
)
RETURNS UUID
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
    v_template_id UUID;
    v_agent agents%ROWTYPE;
    v_mcp_requirements JSONB := '[]'::jsonb;
    v_mcp_config JSONB;
BEGIN
    -- Get the agent
    SELECT * INTO v_agent FROM agents WHERE agent_id = p_agent_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Agent not found';
    END IF;
    
    -- Check ownership
    IF NOT basejump.has_role_on_account(v_agent.account_id, 'owner') THEN
        RAISE EXCEPTION 'Access denied';
    END IF;
    
    -- Extract MCP requirements (remove credentials)
    FOR v_mcp_config IN SELECT * FROM jsonb_array_elements(v_agent.configured_mcps)
    LOOP
        v_mcp_requirements := v_mcp_requirements || jsonb_build_object(
            'qualifiedName', v_mcp_config->>'qualifiedName',
            'name', v_mcp_config->>'name',
            'enabledTools', v_mcp_config->'enabledTools',
            'requiredConfig', (
                SELECT jsonb_agg(key) 
                FROM jsonb_object_keys(v_mcp_config->'config') AS key
            )
        );
    END LOOP;
    
    -- Create template
    INSERT INTO agent_templates (
        creator_id,
        name,
        description,
        system_prompt,
        mcp_requirements,
        agentpress_tools,
        tags,
        avatar,
        avatar_color
    ) VALUES (
        p_creator_id,
        v_agent.name,
        v_agent.description,
        v_agent.system_prompt,
        v_mcp_requirements,
        v_agent.agentpress_tools,
        v_agent.tags,
        v_agent.avatar,
        v_agent.avatar_color
    ) RETURNING template_id INTO v_template_id;
    
    RETURN v_template_id;
END;
$$;

-- Function to install template as agent instance
CREATE OR REPLACE FUNCTION install_template_as_instance(
    p_template_id UUID,
    p_account_id UUID,
    p_instance_name VARCHAR(255) DEFAULT NULL
)
RETURNS UUID
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
    v_instance_id UUID;
    v_template agent_templates%ROWTYPE;
    v_instance_name VARCHAR(255);
    v_credential_mappings JSONB := '{}'::jsonb;
    v_mcp_req JSONB;
    v_credential_id UUID;
BEGIN
    -- Get template
    SELECT * INTO v_template FROM agent_templates WHERE template_id = p_template_id;
    
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Template not found';
    END IF;
    
    -- Check if template is public or user owns it
    IF NOT (v_template.is_public OR basejump.has_role_on_account(v_template.creator_id)) THEN
        RAISE EXCEPTION 'Access denied to template';
    END IF;
    
    -- Set instance name
    v_instance_name := COALESCE(p_instance_name, v_template.name || ' (from marketplace)');
    
    -- Build credential mappings
    FOR v_mcp_req IN SELECT * FROM jsonb_array_elements(v_template.mcp_requirements)
    LOOP
        -- Find user's credential for this MCP
        SELECT credential_id INTO v_credential_id
        FROM user_mcp_credentials
        WHERE account_id = p_account_id 
        AND mcp_qualified_name = (v_mcp_req->>'qualifiedName')
        AND is_active = true;
        
        IF v_credential_id IS NOT NULL THEN
            v_credential_mappings := v_credential_mappings || 
                jsonb_build_object(v_mcp_req->>'qualifiedName', v_credential_id);
        END IF;
    END LOOP;
    
    -- Create agent instance
    INSERT INTO agent_instances (
        template_id,
        account_id,
        name,
        description,
        credential_mappings,
        avatar,
        avatar_color
    ) VALUES (
        p_template_id,
        p_account_id,
        v_instance_name,
        v_template.description,
        v_credential_mappings,
        v_template.avatar,
        v_template.avatar_color
    ) RETURNING instance_id INTO v_instance_id;
    
    -- Update template download count
    UPDATE agent_templates 
    SET download_count = download_count + 1 
    WHERE template_id = p_template_id;
    
    RETURN v_instance_id;
END;
$$;

-- Function to get missing credentials for template
CREATE OR REPLACE FUNCTION get_missing_credentials_for_template(
    p_template_id UUID,
    p_account_id UUID
)
RETURNS TABLE (
    qualified_name VARCHAR(255),
    display_name VARCHAR(255),
    required_config TEXT[]
)
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        (mcp_req->>'qualifiedName')::VARCHAR(255) as qualified_name,
        (mcp_req->>'name')::VARCHAR(255) as display_name,
        ARRAY(SELECT jsonb_array_elements_text(mcp_req->'requiredConfig')) as required_config
    FROM agent_templates t,
         jsonb_array_elements(t.mcp_requirements) as mcp_req
    WHERE t.template_id = p_template_id
    AND NOT EXISTS (
        SELECT 1 FROM user_mcp_credentials c
        WHERE c.account_id = p_account_id
        AND c.mcp_qualified_name = (mcp_req->>'qualifiedName')
        AND c.is_active = true
    );
END;
$$;

GRANT EXECUTE ON FUNCTION create_template_from_agent(UUID, UUID) TO authenticated;
GRANT EXECUTE ON FUNCTION install_template_as_instance(UUID, UUID, VARCHAR) TO authenticated;
GRANT EXECUTE ON FUNCTION get_missing_credentials_for_template(UUID, UUID) TO authenticated;

GRANT ALL PRIVILEGES ON TABLE agent_templates TO authenticated, service_role;
GRANT ALL PRIVILEGES ON TABLE user_mcp_credentials TO authenticated, service_role;
GRANT ALL PRIVILEGES ON TABLE agent_instances TO authenticated, service_role;
GRANT ALL PRIVILEGES ON TABLE credential_usage_log TO authenticated, service_role;

COMMIT; 
BEGIN;

CREATE TABLE IF NOT EXISTS knowledge_base_entries (
    entry_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id UUID NOT NULL REFERENCES threads(thread_id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    
    name VARCHAR(255) NOT NULL,
    description TEXT,
    
    content TEXT NOT NULL,
    content_tokens INTEGER, -- Token count for content management
    
    usage_context VARCHAR(100) DEFAULT 'always', -- 'always', 'on_request', 'contextual'
    
    is_active BOOLEAN DEFAULT TRUE,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    last_accessed_at TIMESTAMPTZ,

    CONSTRAINT kb_entries_valid_usage_context CHECK (
        usage_context IN ('always', 'on_request', 'contextual')
    ),
    CONSTRAINT kb_entries_content_not_empty CHECK (
        content IS NOT NULL AND LENGTH(TRIM(content)) > 0
    )
);


CREATE TABLE IF NOT EXISTS knowledge_base_usage_log (
    log_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entry_id UUID NOT NULL REFERENCES knowledge_base_entries(entry_id) ON DELETE CASCADE,
    thread_id UUID NOT NULL REFERENCES threads(thread_id) ON DELETE CASCADE,

    usage_type VARCHAR(50) NOT NULL, -- 'context_injection', 'manual_reference'
    tokens_used INTEGER, -- How many tokens were used
    
    -- Timestamps
    used_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_kb_entries_thread_id ON knowledge_base_entries(thread_id);
CREATE INDEX IF NOT EXISTS idx_kb_entries_account_id ON knowledge_base_entries(account_id);
CREATE INDEX IF NOT EXISTS idx_kb_entries_is_active ON knowledge_base_entries(is_active);
CREATE INDEX IF NOT EXISTS idx_kb_entries_usage_context ON knowledge_base_entries(usage_context);
CREATE INDEX IF NOT EXISTS idx_kb_entries_created_at ON knowledge_base_entries(created_at);

CREATE INDEX IF NOT EXISTS idx_kb_usage_entry_id ON knowledge_base_usage_log(entry_id);
CREATE INDEX IF NOT EXISTS idx_kb_usage_thread_id ON knowledge_base_usage_log(thread_id);
CREATE INDEX IF NOT EXISTS idx_kb_usage_used_at ON knowledge_base_usage_log(used_at);

ALTER TABLE knowledge_base_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE knowledge_base_usage_log ENABLE ROW LEVEL SECURITY;

CREATE POLICY kb_entries_user_access ON knowledge_base_entries
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM threads t
            LEFT JOIN projects p ON t.project_id = p.project_id
            WHERE t.thread_id = knowledge_base_entries.thread_id
            AND (
                basejump.has_role_on_account(t.account_id) = true OR 
                basejump.has_role_on_account(p.account_id) = true OR
                basejump.has_role_on_account(knowledge_base_entries.account_id) = true
            )
        )
    );

CREATE POLICY kb_usage_log_user_access ON knowledge_base_usage_log
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM threads t
            LEFT JOIN projects p ON t.project_id = p.project_id
            WHERE t.thread_id = knowledge_base_usage_log.thread_id
            AND (
                basejump.has_role_on_account(t.account_id) = true OR 
                basejump.has_role_on_account(p.account_id) = true
            )
        )
    );

CREATE OR REPLACE FUNCTION get_thread_knowledge_base(
    p_thread_id UUID,
    p_include_inactive BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_id UUID,
    name VARCHAR(255),
    description TEXT,
    content TEXT,
    usage_context VARCHAR(100),
    is_active BOOLEAN,
    created_at TIMESTAMPTZ
)
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        kbe.entry_id,
        kbe.name,
        kbe.description,
        kbe.content,
        kbe.usage_context,
        kbe.is_active,
        kbe.created_at
    FROM knowledge_base_entries kbe
    WHERE kbe.thread_id = p_thread_id
    AND (p_include_inactive OR kbe.is_active = TRUE)
    ORDER BY kbe.created_at DESC;
END;
$$;

CREATE OR REPLACE FUNCTION get_knowledge_base_context(
    p_thread_id UUID,
    p_max_tokens INTEGER DEFAULT 4000
)
RETURNS TEXT
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
    context_text TEXT := '';
    entry_record RECORD;
    current_tokens INTEGER := 0;
    estimated_tokens INTEGER;
BEGIN
    FOR entry_record IN
        SELECT 
            name,
            description,
            content,
            content_tokens
        FROM knowledge_base_entries
        WHERE thread_id = p_thread_id
        AND is_active = TRUE
        AND usage_context IN ('always', 'contextual')
        ORDER BY created_at DESC
    LOOP
        estimated_tokens := COALESCE(entry_record.content_tokens, LENGTH(entry_record.content) / 4);
        
        IF current_tokens + estimated_tokens > p_max_tokens THEN
            EXIT;
        END IF;
        
        context_text := context_text || E'\n\n## Knowledge Base: ' || entry_record.name || E'\n';
        
        IF entry_record.description IS NOT NULL AND entry_record.description != '' THEN
            context_text := context_text || entry_record.description || E'\n\n';
        END IF;
        
        context_text := context_text || entry_record.content;
        
        current_tokens := current_tokens + estimated_tokens;
        
        INSERT INTO knowledge_base_usage_log (entry_id, thread_id, usage_type, tokens_used)
        SELECT entry_id, p_thread_id, 'context_injection', estimated_tokens
        FROM knowledge_base_entries
        WHERE thread_id = p_thread_id AND name = entry_record.name
        LIMIT 1;
    END LOOP;
    
    RETURN CASE 
        WHEN context_text = '' THEN NULL
        ELSE E'# KNOWLEDGE BASE CONTEXT\n\nThe following information is from your knowledge base and should be used as reference when responding to the user:' || context_text
    END;
END;
$$;

CREATE OR REPLACE FUNCTION update_kb_entry_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    IF NEW.content != OLD.content THEN
        NEW.content_tokens = LENGTH(NEW.content) / 4;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_kb_entries_updated_at
    BEFORE UPDATE ON knowledge_base_entries
    FOR EACH ROW
    EXECUTE FUNCTION update_kb_entry_timestamp();

CREATE OR REPLACE FUNCTION calculate_kb_entry_tokens()
RETURNS TRIGGER AS $$
BEGIN
    NEW.content_tokens = LENGTH(NEW.content) / 4;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_kb_entries_calculate_tokens
    BEFORE INSERT ON knowledge_base_entries
    FOR EACH ROW
    EXECUTE FUNCTION calculate_kb_entry_tokens();

GRANT ALL PRIVILEGES ON TABLE knowledge_base_entries TO authenticated, service_role;
GRANT ALL PRIVILEGES ON TABLE knowledge_base_usage_log TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION get_thread_knowledge_base TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION get_knowledge_base_context TO authenticated, service_role;

COMMENT ON TABLE knowledge_base_entries IS 'Stores manual knowledge base entries for threads, similar to ChatGPT custom instructions';
COMMENT ON TABLE knowledge_base_usage_log IS 'Logs when and how knowledge base entries are used';

COMMENT ON FUNCTION get_thread_knowledge_base IS 'Retrieves all knowledge base entries for a specific thread';
COMMENT ON FUNCTION get_knowledge_base_context IS 'Generates knowledge base context text for agent prompts';

COMMIT;
-- Migration: Make threads agent-agnostic with proper agent versioning support
-- This migration enables per-message agent selection with version tracking

BEGIN;

-- Add agent version tracking to messages table
ALTER TABLE messages ADD COLUMN IF NOT EXISTS agent_id UUID REFERENCES agents(agent_id) ON DELETE SET NULL;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS agent_version_id UUID REFERENCES agent_versions(version_id) ON DELETE SET NULL;

-- Create indexes for message agent queries
CREATE INDEX IF NOT EXISTS idx_messages_agent_id ON messages(agent_id);
CREATE INDEX IF NOT EXISTS idx_messages_agent_version_id ON messages(agent_version_id);

-- Comments on the new columns
COMMENT ON COLUMN messages.agent_id IS 'ID of the agent that generated this message. For user messages, this represents the agent that should respond to this message.';
COMMENT ON COLUMN messages.agent_version_id IS 'Specific version of the agent used for this message. This is the actual configuration that was active.';

-- Update comment on thread agent_id to reflect new agent-agnostic approach
COMMENT ON COLUMN threads.agent_id IS 'Optional default agent for the thread. If NULL, agent can be selected per message. Threads are now agent-agnostic.';

-- Add agent version tracking to agent_runs
ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS agent_id UUID REFERENCES agents(agent_id) ON DELETE SET NULL;
ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS agent_version_id UUID REFERENCES agent_versions(version_id) ON DELETE SET NULL;

-- Create indexes for agent run queries
CREATE INDEX IF NOT EXISTS idx_agent_runs_agent_id ON agent_runs(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_runs_agent_version_id ON agent_runs(agent_version_id);

-- Comments on the agent_runs columns
COMMENT ON COLUMN agent_runs.agent_id IS 'ID of the agent used for this specific agent run.';
COMMENT ON COLUMN agent_runs.agent_version_id IS 'Specific version of the agent used for this run. This tracks the exact configuration.';

COMMIT; 
-- Migration: Add is_kortix_team field to agent_templates
-- This migration adds support for marking templates as Kortix team templates

BEGIN;

-- Add is_kortix_team column to agent_templates table
ALTER TABLE agent_templates ADD COLUMN IF NOT EXISTS is_kortix_team BOOLEAN DEFAULT false;

-- Create index for better performance
CREATE INDEX IF NOT EXISTS idx_agent_templates_is_kortix_team ON agent_templates(is_kortix_team);

-- Add comment
COMMENT ON COLUMN agent_templates.is_kortix_team IS 'Indicates if this template is created by the Kortix team (official templates)';

COMMIT; 
-- Agent Triggers System Migration
-- This migration creates tables for the agent trigger system

BEGIN;

-- Enable UUID extension if not already enabled
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Enum for trigger types
DO $$ BEGIN
    CREATE TYPE agent_trigger_type AS ENUM ('telegram', 'slack', 'webhook', 'schedule', 'email', 'github', 'discord', 'teams');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- Agent triggers table
CREATE TABLE IF NOT EXISTS agent_triggers (
    trigger_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id UUID NOT NULL REFERENCES agents(agent_id) ON DELETE CASCADE,
    trigger_type agent_trigger_type NOT NULL,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    is_active BOOLEAN DEFAULT TRUE,
    config JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Trigger events log table for auditing
CREATE TABLE IF NOT EXISTS trigger_events (
    event_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    trigger_id UUID NOT NULL REFERENCES agent_triggers(trigger_id) ON DELETE CASCADE,
    agent_id UUID NOT NULL REFERENCES agents(agent_id) ON DELETE CASCADE,
    trigger_type agent_trigger_type NOT NULL,
    timestamp TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    success BOOLEAN NOT NULL,
    should_execute_agent BOOLEAN DEFAULT FALSE,
    error_message TEXT,
    metadata JSONB DEFAULT '{}'::jsonb
);

-- Custom trigger providers table for dynamic provider definitions
CREATE TABLE IF NOT EXISTS custom_trigger_providers (
    provider_id VARCHAR(255) PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    description TEXT NOT NULL,
    trigger_type VARCHAR(50) NOT NULL,
    provider_class TEXT, -- Full import path for custom providers
    config_schema JSONB DEFAULT '{}'::jsonb,
    webhook_enabled BOOLEAN DEFAULT FALSE,
    webhook_config JSONB,
    response_template JSONB,
    field_mappings JSONB,
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    created_by UUID REFERENCES basejump.accounts(id)
);

-- OAuth installations table for storing OAuth integration data
CREATE TABLE IF NOT EXISTS oauth_installations (
    installation_id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    trigger_id UUID NOT NULL REFERENCES agent_triggers(trigger_id) ON DELETE CASCADE,
    provider VARCHAR(50) NOT NULL, -- slack, discord, teams, etc.
    access_token TEXT NOT NULL,
    refresh_token TEXT,
    expires_in INTEGER,
    scope TEXT,
    provider_data JSONB DEFAULT '{}'::jsonb, -- Provider-specific data like workspace info
    installed_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_agent_triggers_agent_id ON agent_triggers(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_triggers_trigger_type ON agent_triggers(trigger_type);
CREATE INDEX IF NOT EXISTS idx_agent_triggers_is_active ON agent_triggers(is_active);
CREATE INDEX IF NOT EXISTS idx_agent_triggers_created_at ON agent_triggers(created_at);

CREATE INDEX IF NOT EXISTS idx_trigger_events_trigger_id ON trigger_events(trigger_id);
CREATE INDEX IF NOT EXISTS idx_trigger_events_agent_id ON trigger_events(agent_id);
CREATE INDEX IF NOT EXISTS idx_trigger_events_timestamp ON trigger_events(timestamp);
CREATE INDEX IF NOT EXISTS idx_trigger_events_success ON trigger_events(success);

CREATE INDEX IF NOT EXISTS idx_custom_trigger_providers_trigger_type ON custom_trigger_providers(trigger_type);
CREATE INDEX IF NOT EXISTS idx_custom_trigger_providers_is_active ON custom_trigger_providers(is_active);

CREATE INDEX IF NOT EXISTS idx_oauth_installations_trigger_id ON oauth_installations(trigger_id);
CREATE INDEX IF NOT EXISTS idx_oauth_installations_provider ON oauth_installations(provider);
CREATE INDEX IF NOT EXISTS idx_oauth_installations_installed_at ON oauth_installations(installed_at);

-- Create updated_at trigger function if it doesn't exist
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ language 'plpgsql';

-- Create triggers for updated_at
CREATE TRIGGER update_agent_triggers_updated_at 
    BEFORE UPDATE ON agent_triggers
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_custom_trigger_providers_updated_at 
    BEFORE UPDATE ON custom_trigger_providers
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_oauth_installations_updated_at 
    BEFORE UPDATE ON oauth_installations
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Enable RLS on all tables
ALTER TABLE agent_triggers ENABLE ROW LEVEL SECURITY;
ALTER TABLE trigger_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE custom_trigger_providers ENABLE ROW LEVEL SECURITY;
ALTER TABLE oauth_installations ENABLE ROW LEVEL SECURITY;

-- RLS Policies for agent_triggers
-- Users can only see triggers for agents they own
CREATE POLICY agent_triggers_select_policy ON agent_triggers
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM agents
            WHERE agents.agent_id = agent_triggers.agent_id
            AND basejump.has_role_on_account(agents.account_id)
        )
    );

CREATE POLICY agent_triggers_insert_policy ON agent_triggers
    FOR INSERT WITH CHECK (
        EXISTS (
            SELECT 1 FROM agents
            WHERE agents.agent_id = agent_triggers.agent_id
            AND basejump.has_role_on_account(agents.account_id, 'owner')
        )
    );

CREATE POLICY agent_triggers_update_policy ON agent_triggers
    FOR UPDATE USING (
        EXISTS (
            SELECT 1 FROM agents
            WHERE agents.agent_id = agent_triggers.agent_id
            AND basejump.has_role_on_account(agents.account_id, 'owner')
        )
    );

CREATE POLICY agent_triggers_delete_policy ON agent_triggers
    FOR DELETE USING (
        EXISTS (
            SELECT 1 FROM agents
            WHERE agents.agent_id = agent_triggers.agent_id
            AND basejump.has_role_on_account(agents.account_id, 'owner')
        )
    );

-- RLS Policies for trigger_events
-- Users can see events for triggers on agents they own
CREATE POLICY trigger_events_select_policy ON trigger_events
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM agents
            WHERE agents.agent_id = trigger_events.agent_id
            AND basejump.has_role_on_account(agents.account_id)
        )
    );

-- Service role can insert trigger events
CREATE POLICY trigger_events_insert_policy ON trigger_events
    FOR INSERT WITH CHECK (auth.jwt() ->> 'role' = 'service_role');

-- RLS Policies for custom_trigger_providers
-- All authenticated users can view active custom providers
CREATE POLICY custom_trigger_providers_select_policy ON custom_trigger_providers
    FOR SELECT USING (is_active = true);

-- Only users can create custom providers for their account
CREATE POLICY custom_trigger_providers_insert_policy ON custom_trigger_providers
    FOR INSERT WITH CHECK (basejump.has_role_on_account(created_by));

-- Only creator can update their custom providers
CREATE POLICY custom_trigger_providers_update_policy ON custom_trigger_providers
    FOR UPDATE USING (basejump.has_role_on_account(created_by, 'owner'));

-- Only creator can delete their custom providers
CREATE POLICY custom_trigger_providers_delete_policy ON custom_trigger_providers
    FOR DELETE USING (basejump.has_role_on_account(created_by, 'owner'));

-- RLS Policies for oauth_installations
-- Users can see OAuth installations for triggers on agents they own
CREATE POLICY oauth_installations_select_policy ON oauth_installations
    FOR SELECT USING (
        EXISTS (
            SELECT 1 FROM agent_triggers
            JOIN agents ON agents.agent_id = agent_triggers.agent_id
            WHERE agent_triggers.trigger_id = oauth_installations.trigger_id
            AND basejump.has_role_on_account(agents.account_id)
        )
    );

-- Service role can insert/update/delete OAuth installations
CREATE POLICY oauth_installations_insert_policy ON oauth_installations
    FOR INSERT WITH CHECK (auth.jwt() ->> 'role' = 'service_role');

CREATE POLICY oauth_installations_update_policy ON oauth_installations
    FOR UPDATE USING (auth.jwt() ->> 'role' = 'service_role');

CREATE POLICY oauth_installations_delete_policy ON oauth_installations
    FOR DELETE USING (auth.jwt() ->> 'role' = 'service_role');

-- Grant permissions
GRANT ALL PRIVILEGES ON TABLE agent_triggers TO authenticated, service_role;
GRANT ALL PRIVILEGES ON TABLE trigger_events TO service_role;
GRANT SELECT ON TABLE trigger_events TO authenticated;
GRANT ALL PRIVILEGES ON TABLE custom_trigger_providers TO authenticated, service_role;
GRANT ALL PRIVILEGES ON TABLE oauth_installations TO service_role;
GRANT SELECT ON TABLE oauth_installations TO authenticated;

-- Add comments for documentation
COMMENT ON TABLE agent_triggers IS 'Stores trigger configurations for agents';
COMMENT ON TABLE trigger_events IS 'Audit log of trigger events and their results';
COMMENT ON TABLE custom_trigger_providers IS 'Custom trigger provider definitions for dynamic loading';
COMMENT ON TABLE oauth_installations IS 'OAuth integration data for triggers (tokens, workspace info, etc.)';

COMMENT ON COLUMN agent_triggers.config IS 'Provider-specific configuration including credentials and settings';
COMMENT ON COLUMN trigger_events.metadata IS 'Additional event data and processing results';
COMMENT ON COLUMN custom_trigger_providers.provider_class IS 'Full Python import path for custom provider classes';
COMMENT ON COLUMN custom_trigger_providers.field_mappings IS 'Maps webhook fields to execution variables using dot notation';
COMMENT ON COLUMN oauth_installations.provider_data IS 'Provider-specific data like workspace info, bot details, etc.';

COMMIT; 
BEGIN;

-- Create separate table for agent-specific knowledge base entries
CREATE TABLE IF NOT EXISTS agent_knowledge_base_entries (
    entry_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id UUID NOT NULL REFERENCES agents(agent_id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    
    name VARCHAR(255) NOT NULL,
    description TEXT,
    
    content TEXT NOT NULL,
    content_tokens INTEGER, -- Token count for content management
    
    usage_context VARCHAR(100) DEFAULT 'always', -- 'always', 'on_request', 'contextual'
    
    is_active BOOLEAN DEFAULT TRUE,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    last_accessed_at TIMESTAMPTZ,

    CONSTRAINT agent_kb_entries_valid_usage_context CHECK (
        usage_context IN ('always', 'on_request', 'contextual')
    ),
    CONSTRAINT agent_kb_entries_content_not_empty CHECK (
        content IS NOT NULL AND LENGTH(TRIM(content)) > 0
    )
);

-- Create usage log table for agent knowledge base
CREATE TABLE IF NOT EXISTS agent_knowledge_base_usage_log (
    log_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    entry_id UUID NOT NULL REFERENCES agent_knowledge_base_entries(entry_id) ON DELETE CASCADE,
    agent_id UUID NOT NULL REFERENCES agents(agent_id) ON DELETE CASCADE,

    usage_type VARCHAR(50) NOT NULL, -- 'context_injection', 'manual_reference'
    tokens_used INTEGER, -- How many tokens were used
    
    -- Timestamps
    used_at TIMESTAMPTZ DEFAULT NOW()
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_agent_kb_entries_agent_id ON agent_knowledge_base_entries(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_kb_entries_account_id ON agent_knowledge_base_entries(account_id);
CREATE INDEX IF NOT EXISTS idx_agent_kb_entries_is_active ON agent_knowledge_base_entries(is_active);
CREATE INDEX IF NOT EXISTS idx_agent_kb_entries_usage_context ON agent_knowledge_base_entries(usage_context);
CREATE INDEX IF NOT EXISTS idx_agent_kb_entries_created_at ON agent_knowledge_base_entries(created_at);

CREATE INDEX IF NOT EXISTS idx_agent_kb_usage_entry_id ON agent_knowledge_base_usage_log(entry_id);
CREATE INDEX IF NOT EXISTS idx_agent_kb_usage_agent_id ON agent_knowledge_base_usage_log(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_kb_usage_used_at ON agent_knowledge_base_usage_log(used_at);

-- Enable RLS
ALTER TABLE agent_knowledge_base_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_knowledge_base_usage_log ENABLE ROW LEVEL SECURITY;

-- Create RLS policies for agent knowledge base entries
CREATE POLICY agent_kb_entries_user_access ON agent_knowledge_base_entries
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM agents a
            WHERE a.agent_id = agent_knowledge_base_entries.agent_id
            AND basejump.has_role_on_account(a.account_id) = true
        )
    );

-- Create RLS policies for agent knowledge base usage log
CREATE POLICY agent_kb_usage_log_user_access ON agent_knowledge_base_usage_log
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM agents a
            WHERE a.agent_id = agent_knowledge_base_usage_log.agent_id
            AND basejump.has_role_on_account(a.account_id) = true
        )
    );

-- Function to get agent knowledge base entries
CREATE OR REPLACE FUNCTION get_agent_knowledge_base(
    p_agent_id UUID,
    p_include_inactive BOOLEAN DEFAULT FALSE
)
RETURNS TABLE (
    entry_id UUID,
    name VARCHAR(255),
    description TEXT,
    content TEXT,
    usage_context VARCHAR(100),
    is_active BOOLEAN,
    content_tokens INTEGER,
    created_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
)
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        akbe.entry_id,
        akbe.name,
        akbe.description,
        akbe.content,
        akbe.usage_context,
        akbe.is_active,
        akbe.content_tokens,
        akbe.created_at,
        akbe.updated_at
    FROM agent_knowledge_base_entries akbe
    WHERE akbe.agent_id = p_agent_id
    AND (p_include_inactive OR akbe.is_active = TRUE)
    ORDER BY akbe.created_at DESC;
END;
$$;

-- Function to get agent knowledge base context for prompts
CREATE OR REPLACE FUNCTION get_agent_knowledge_base_context(
    p_agent_id UUID,
    p_max_tokens INTEGER DEFAULT 4000
)
RETURNS TEXT
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
    context_text TEXT := '';
    entry_record RECORD;
    current_tokens INTEGER := 0;
    estimated_tokens INTEGER;
    agent_name TEXT;
BEGIN
    -- Get agent name for context header
    SELECT name INTO agent_name FROM agents WHERE agent_id = p_agent_id;
    
    FOR entry_record IN
        SELECT 
            entry_id,
            name,
            description,
            content,
            content_tokens
        FROM agent_knowledge_base_entries
        WHERE agent_id = p_agent_id
        AND is_active = TRUE
        AND usage_context IN ('always', 'contextual')
        ORDER BY created_at DESC
    LOOP
        estimated_tokens := COALESCE(entry_record.content_tokens, LENGTH(entry_record.content) / 4);
        
        IF current_tokens + estimated_tokens > p_max_tokens THEN
            EXIT;
        END IF;
        
        context_text := context_text || E'\n\n## ' || entry_record.name || E'\n';
        
        IF entry_record.description IS NOT NULL AND entry_record.description != '' THEN
            context_text := context_text || entry_record.description || E'\n\n';
        END IF;
        
        context_text := context_text || entry_record.content;
        
        current_tokens := current_tokens + estimated_tokens;
        
        -- Log usage for agent knowledge base
        INSERT INTO agent_knowledge_base_usage_log (entry_id, agent_id, usage_type, tokens_used)
        VALUES (entry_record.entry_id, p_agent_id, 'context_injection', estimated_tokens);
    END LOOP;
    
    RETURN CASE 
        WHEN context_text = '' THEN NULL
        ELSE E'# AGENT KNOWLEDGE BASE\n\nThe following is your specialized knowledge base. Use this information as context when responding:' || context_text
    END;
END;
$$;

-- Function to get combined knowledge base context (agent + thread)
CREATE OR REPLACE FUNCTION get_combined_knowledge_base_context(
    p_thread_id UUID,
    p_agent_id UUID DEFAULT NULL,
    p_max_tokens INTEGER DEFAULT 4000
)
RETURNS TEXT
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
    context_text TEXT := '';
    agent_context TEXT := '';
    thread_context TEXT := '';
    total_tokens INTEGER := 0;
    agent_tokens INTEGER := 0;
    thread_tokens INTEGER := 0;
BEGIN
    -- Get agent-specific context if agent_id is provided
    IF p_agent_id IS NOT NULL THEN
        agent_context := get_agent_knowledge_base_context(p_agent_id, p_max_tokens / 2);
        IF agent_context IS NOT NULL THEN
            agent_tokens := LENGTH(agent_context) / 4;
            total_tokens := agent_tokens;
        END IF;
    END IF;
    
    -- Get thread-specific context with remaining tokens
    thread_context := get_knowledge_base_context(p_thread_id, p_max_tokens - total_tokens);
    IF thread_context IS NOT NULL THEN
        thread_tokens := LENGTH(thread_context) / 4;
        total_tokens := total_tokens + thread_tokens;
    END IF;
    
    -- Combine contexts
    IF agent_context IS NOT NULL AND thread_context IS NOT NULL THEN
        context_text := agent_context || E'\n\n' || thread_context;
    ELSIF agent_context IS NOT NULL THEN
        context_text := agent_context;
    ELSIF thread_context IS NOT NULL THEN
        context_text := thread_context;
    END IF;
    
    RETURN context_text;
END;
$$;

-- Create triggers for automatic token calculation and timestamp updates
CREATE OR REPLACE FUNCTION update_agent_kb_entry_timestamp()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    IF NEW.content != OLD.content THEN
        NEW.content_tokens = LENGTH(NEW.content) / 4;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_agent_kb_entries_updated_at
    BEFORE UPDATE ON agent_knowledge_base_entries
    FOR EACH ROW
    EXECUTE FUNCTION update_agent_kb_entry_timestamp();

CREATE OR REPLACE FUNCTION calculate_agent_kb_entry_tokens()
RETURNS TRIGGER AS $$
BEGIN
    NEW.content_tokens = LENGTH(NEW.content) / 4;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_agent_kb_entries_calculate_tokens
    BEFORE INSERT ON agent_knowledge_base_entries
    FOR EACH ROW
    EXECUTE FUNCTION calculate_agent_kb_entry_tokens();

-- Grant permissions
GRANT ALL PRIVILEGES ON TABLE agent_knowledge_base_entries TO authenticated, service_role;
GRANT ALL PRIVILEGES ON TABLE agent_knowledge_base_usage_log TO authenticated, service_role;

GRANT EXECUTE ON FUNCTION get_agent_knowledge_base TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION get_agent_knowledge_base_context TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION get_combined_knowledge_base_context TO authenticated, service_role;

-- Add comments
COMMENT ON TABLE agent_knowledge_base_entries IS 'Stores knowledge base entries specific to individual agents';
COMMENT ON TABLE agent_knowledge_base_usage_log IS 'Logs when and how agent knowledge base entries are used';

COMMENT ON FUNCTION get_agent_knowledge_base IS 'Retrieves all knowledge base entries for a specific agent';
COMMENT ON FUNCTION get_agent_knowledge_base_context IS 'Generates agent-specific knowledge base context text for prompts';
COMMENT ON FUNCTION get_combined_knowledge_base_context IS 'Generates combined agent and thread knowledge base context';

COMMIT; 
BEGIN;

-- Add source type and file metadata to agent knowledge base entries
ALTER TABLE agent_knowledge_base_entries 
ADD COLUMN source_type VARCHAR(50) DEFAULT 'manual' CHECK (source_type IN ('manual', 'file', 'git_repo', 'zip_extracted'));

ALTER TABLE agent_knowledge_base_entries 
ADD COLUMN source_metadata JSONB DEFAULT '{}';

ALTER TABLE agent_knowledge_base_entries 
ADD COLUMN file_path TEXT;

ALTER TABLE agent_knowledge_base_entries 
ADD COLUMN file_size BIGINT;

ALTER TABLE agent_knowledge_base_entries 
ADD COLUMN file_mime_type VARCHAR(255);

ALTER TABLE agent_knowledge_base_entries 
ADD COLUMN extracted_from_zip_id UUID REFERENCES agent_knowledge_base_entries(entry_id) ON DELETE CASCADE;

-- Create indexes for new columns
CREATE INDEX IF NOT EXISTS idx_agent_kb_entries_source_type ON agent_knowledge_base_entries(source_type);
CREATE INDEX IF NOT EXISTS idx_agent_kb_entries_extracted_from_zip ON agent_knowledge_base_entries(extracted_from_zip_id);

-- Create table for tracking file processing jobs
CREATE TABLE IF NOT EXISTS agent_kb_file_processing_jobs (
    job_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    agent_id UUID NOT NULL REFERENCES agents(agent_id) ON DELETE CASCADE,
    account_id UUID NOT NULL REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    
    job_type VARCHAR(50) NOT NULL CHECK (job_type IN ('file_upload', 'zip_extraction', 'git_clone')),
    status VARCHAR(50) DEFAULT 'pending' CHECK (status IN ('pending', 'processing', 'completed', 'failed')),
    
    source_info JSONB NOT NULL, -- Contains file path, git URL, etc.
    result_info JSONB DEFAULT '{}', -- Processing results, error messages, etc.
    
    entries_created INTEGER DEFAULT 0,
    total_files INTEGER DEFAULT 0,
    
    created_at TIMESTAMPTZ DEFAULT NOW(),
    started_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    
    error_message TEXT
);

-- Create indexes for file processing jobs
CREATE INDEX IF NOT EXISTS idx_agent_kb_jobs_agent_id ON agent_kb_file_processing_jobs(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_kb_jobs_status ON agent_kb_file_processing_jobs(status);
CREATE INDEX IF NOT EXISTS idx_agent_kb_jobs_created_at ON agent_kb_file_processing_jobs(created_at);

-- Enable RLS for new table
ALTER TABLE agent_kb_file_processing_jobs ENABLE ROW LEVEL SECURITY;

-- Create RLS policy for file processing jobs
CREATE POLICY agent_kb_jobs_user_access ON agent_kb_file_processing_jobs
    FOR ALL
    USING (
        EXISTS (
            SELECT 1 FROM agents a
            WHERE a.agent_id = agent_kb_file_processing_jobs.agent_id
            AND basejump.has_role_on_account(a.account_id) = true
        )
    );

-- Function to get file processing jobs for an agent
CREATE OR REPLACE FUNCTION get_agent_kb_processing_jobs(
    p_agent_id UUID,
    p_limit INTEGER DEFAULT 10
)
RETURNS TABLE (
    job_id UUID,
    job_type VARCHAR(50),
    status VARCHAR(50),
    source_info JSONB,
    result_info JSONB,
    entries_created INTEGER,
    total_files INTEGER,
    created_at TIMESTAMPTZ,
    completed_at TIMESTAMPTZ,
    error_message TEXT
)
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT 
        akj.job_id,
        akj.job_type,
        akj.status,
        akj.source_info,
        akj.result_info,
        akj.entries_created,
        akj.total_files,
        akj.created_at,
        akj.completed_at,
        akj.error_message
    FROM agent_kb_file_processing_jobs akj
    WHERE akj.agent_id = p_agent_id
    ORDER BY akj.created_at DESC
    LIMIT p_limit;
END;
$$;

-- Function to create a file processing job
CREATE OR REPLACE FUNCTION create_agent_kb_processing_job(
    p_agent_id UUID,
    p_account_id UUID,
    p_job_type VARCHAR(50),
    p_source_info JSONB
)
RETURNS UUID
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
DECLARE
    new_job_id UUID;
BEGIN
    INSERT INTO agent_kb_file_processing_jobs (
        agent_id,
        account_id,
        job_type,
        source_info
    ) VALUES (
        p_agent_id,
        p_account_id,
        p_job_type,
        p_source_info
    ) RETURNING job_id INTO new_job_id;
    
    RETURN new_job_id;
END;
$$;

-- Function to update job status
CREATE OR REPLACE FUNCTION update_agent_kb_job_status(
    p_job_id UUID,
    p_status VARCHAR(50),
    p_result_info JSONB DEFAULT NULL,
    p_entries_created INTEGER DEFAULT NULL,
    p_total_files INTEGER DEFAULT NULL,
    p_error_message TEXT DEFAULT NULL
)
RETURNS VOID
SECURITY DEFINER
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE agent_kb_file_processing_jobs 
    SET 
        status = p_status,
        result_info = COALESCE(p_result_info, result_info),
        entries_created = COALESCE(p_entries_created, entries_created),
        total_files = COALESCE(p_total_files, total_files),
        error_message = p_error_message,
        started_at = CASE WHEN p_status = 'processing' AND started_at IS NULL THEN NOW() ELSE started_at END,
        completed_at = CASE WHEN p_status IN ('completed', 'failed') THEN NOW() ELSE completed_at END
    WHERE job_id = p_job_id;
END;
$$;

-- Grant permissions
GRANT ALL PRIVILEGES ON TABLE agent_kb_file_processing_jobs TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION get_agent_kb_processing_jobs TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION create_agent_kb_processing_job TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION update_agent_kb_job_status TO authenticated, service_role;

-- Add comments
COMMENT ON TABLE agent_kb_file_processing_jobs IS 'Tracks file upload, extraction, and git cloning jobs for agent knowledge bases';
COMMENT ON FUNCTION get_agent_kb_processing_jobs IS 'Retrieves processing jobs for an agent';
COMMENT ON FUNCTION create_agent_kb_processing_job IS 'Creates a new file processing job';
COMMENT ON FUNCTION update_agent_kb_job_status IS 'Updates the status and results of a processing job';

COMMIT; 
-- Rollback script for old workflow system
DROP TABLE IF EXISTS workflow_flows CASCADE;

-- Drop workflow execution logs (depends on workflow_executions)
DROP TABLE IF EXISTS workflow_execution_logs CASCADE;

-- Drop workflow variables (depends on workflows)
DROP TABLE IF EXISTS workflow_variables CASCADE;

-- Drop webhook registrations (depends on workflows)
DROP TABLE IF EXISTS webhook_registrations CASCADE;

-- Drop scheduled jobs (depends on workflows)
DROP TABLE IF EXISTS scheduled_jobs CASCADE;

-- Drop triggers (depends on workflows)
DROP TABLE IF EXISTS triggers CASCADE;

-- Drop workflow executions (depends on workflows)
DROP TABLE IF EXISTS workflow_executions CASCADE;

-- Drop workflow templates (standalone table)
DROP TABLE IF EXISTS workflow_templates CASCADE;

-- Drop workflows table (main table)
DROP TABLE IF EXISTS workflows CASCADE;

-- Drop workflow-specific functions
DROP FUNCTION IF EXISTS cleanup_old_execution_logs(INTEGER);
DROP FUNCTION IF EXISTS get_workflow_statistics(UUID);

-- Drop enum types (in reverse order of dependencies)
DROP TYPE IF EXISTS connection_type CASCADE;
DROP TYPE IF EXISTS node_type CASCADE;
DROP TYPE IF EXISTS trigger_type CASCADE;
DROP TYPE IF EXISTS execution_status CASCADE;
DROP TYPE IF EXISTS workflow_status CASCADE;
-- Agent Workflows Migration
-- This migration creates tables for agent-specific workflows
-- Simple step-by-step task execution system

-- Enable UUID extension if not already enabled
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- Enum types for agent workflow system
DO $$ BEGIN
    CREATE TYPE agent_workflow_status AS ENUM ('draft', 'active', 'paused', 'archived');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE workflow_step_type AS ENUM ('message', 'tool_call', 'condition', 'loop', 'wait', 'input', 'output');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    CREATE TYPE workflow_execution_status AS ENUM ('pending', 'running', 'completed', 'failed', 'cancelled');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- Agent workflows table
CREATE TABLE IF NOT EXISTS agent_workflows (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    agent_id UUID NOT NULL REFERENCES agents(agent_id) ON DELETE CASCADE,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    status agent_workflow_status DEFAULT 'draft',
    trigger_phrase VARCHAR(255), -- Optional phrase to trigger this workflow
    is_default BOOLEAN DEFAULT FALSE, -- Whether this is the default workflow for the agent
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Workflow steps table
CREATE TABLE IF NOT EXISTS workflow_steps (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workflow_id UUID NOT NULL REFERENCES agent_workflows(id) ON DELETE CASCADE,
    step_order INTEGER NOT NULL,
    name VARCHAR(255) NOT NULL,
    description TEXT,
    type workflow_step_type NOT NULL,
    config JSONB NOT NULL DEFAULT '{}',
    conditions JSONB, -- Conditions for when this step should execute
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    
    -- Ensure unique order per workflow
    CONSTRAINT workflow_steps_order_unique UNIQUE (workflow_id, step_order)
);

-- Workflow executions table
CREATE TABLE IF NOT EXISTS workflow_executions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    workflow_id UUID NOT NULL REFERENCES agent_workflows(id) ON DELETE CASCADE,
    agent_id UUID NOT NULL REFERENCES agents(agent_id) ON DELETE CASCADE,
    thread_id UUID, -- Optional reference to thread if execution is part of a conversation
    triggered_by VARCHAR(255), -- What triggered this execution
    status workflow_execution_status NOT NULL DEFAULT 'pending',
    started_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    completed_at TIMESTAMP WITH TIME ZONE,
    duration_seconds FLOAT,
    input_data JSONB, -- Input data for the workflow
    output_data JSONB, -- Final output data
    error_message TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Workflow step executions table
CREATE TABLE IF NOT EXISTS workflow_step_executions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    execution_id UUID NOT NULL REFERENCES workflow_executions(id) ON DELETE CASCADE,
    step_id UUID NOT NULL REFERENCES workflow_steps(id) ON DELETE CASCADE,
    step_order INTEGER NOT NULL,
    status workflow_execution_status NOT NULL DEFAULT 'pending',
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    duration_seconds FLOAT,
    input_data JSONB,
    output_data JSONB,
    error_message TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create indexes for performance
CREATE INDEX IF NOT EXISTS idx_agent_workflows_agent_id ON agent_workflows(agent_id);
CREATE INDEX IF NOT EXISTS idx_agent_workflows_status ON agent_workflows(status);
CREATE INDEX IF NOT EXISTS idx_workflow_steps_workflow_id ON workflow_steps(workflow_id);
CREATE INDEX IF NOT EXISTS idx_workflow_steps_order ON workflow_steps(workflow_id, step_order);
CREATE INDEX IF NOT EXISTS idx_workflow_executions_workflow_id ON workflow_executions(workflow_id);
CREATE INDEX IF NOT EXISTS idx_workflow_executions_agent_id ON workflow_executions(agent_id);
CREATE INDEX IF NOT EXISTS idx_workflow_executions_status ON workflow_executions(status);
CREATE INDEX IF NOT EXISTS idx_workflow_executions_started_at ON workflow_executions(started_at DESC);
CREATE INDEX IF NOT EXISTS idx_workflow_step_executions_execution_id ON workflow_step_executions(execution_id);
CREATE INDEX IF NOT EXISTS idx_workflow_step_executions_step_id ON workflow_step_executions(step_id);

-- Row Level Security (RLS) Policies
ALTER TABLE agent_workflows ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_steps ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_executions ENABLE ROW LEVEL SECURITY;
ALTER TABLE workflow_step_executions ENABLE ROW LEVEL SECURITY;

-- Agent workflows policies
CREATE POLICY "Users can view workflows for their agents" ON agent_workflows
    FOR SELECT USING (
        agent_id IN (
            SELECT agent_id FROM agents 
            WHERE basejump.has_role_on_account(account_id)
        )
    );

CREATE POLICY "Users can create workflows for their agents" ON agent_workflows
    FOR INSERT WITH CHECK (
        agent_id IN (
            SELECT agent_id FROM agents 
            WHERE basejump.has_role_on_account(account_id)
        )
    );

CREATE POLICY "Users can update workflows for their agents" ON agent_workflows
    FOR UPDATE USING (
        agent_id IN (
            SELECT agent_id FROM agents 
            WHERE basejump.has_role_on_account(account_id)
        )
    );

CREATE POLICY "Users can delete workflows for their agents" ON agent_workflows
    FOR DELETE USING (
        agent_id IN (
            SELECT agent_id FROM agents 
            WHERE basejump.has_role_on_account(account_id)
        )
    );

-- Workflow steps policies
CREATE POLICY "Users can view steps for their workflows" ON workflow_steps
    FOR SELECT USING (
        workflow_id IN (
            SELECT id FROM agent_workflows 
            WHERE agent_id IN (
                SELECT agent_id FROM agents 
                WHERE basejump.has_role_on_account(account_id)
            )
        )
    );

CREATE POLICY "Users can manage steps for their workflows" ON workflow_steps
    FOR ALL USING (
        workflow_id IN (
            SELECT id FROM agent_workflows 
            WHERE agent_id IN (
                SELECT agent_id FROM agents 
                WHERE basejump.has_role_on_account(account_id)
            )
        )
    );

-- Workflow executions policies
CREATE POLICY "Users can view executions for their workflows" ON workflow_executions
    FOR SELECT USING (
        workflow_id IN (
            SELECT id FROM agent_workflows 
            WHERE agent_id IN (
                SELECT agent_id FROM agents 
                WHERE basejump.has_role_on_account(account_id)
            )
        )
    );

CREATE POLICY "Service role can manage executions" ON workflow_executions
    FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');

-- Workflow step executions policies
CREATE POLICY "Users can view step executions for their workflows" ON workflow_step_executions
    FOR SELECT USING (
        execution_id IN (
            SELECT id FROM workflow_executions
            WHERE workflow_id IN (
                SELECT id FROM agent_workflows 
                WHERE agent_id IN (
                    SELECT agent_id FROM agents 
                    WHERE basejump.has_role_on_account(account_id)
                )
            )
        )
    );

CREATE POLICY "Service role can manage step executions" ON workflow_step_executions
    FOR ALL USING (auth.jwt() ->> 'role' = 'service_role');

-- Create function to update updated_at timestamp if it doesn't exist
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Create triggers for updated_at
CREATE TRIGGER update_agent_workflows_updated_at 
    BEFORE UPDATE ON agent_workflows
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

CREATE TRIGGER update_workflow_steps_updated_at 
    BEFORE UPDATE ON workflow_steps
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

-- Grant permissions
GRANT ALL PRIVILEGES ON TABLE agent_workflows TO authenticated, service_role;
GRANT ALL PRIVILEGES ON TABLE workflow_steps TO authenticated, service_role;
GRANT ALL PRIVILEGES ON TABLE workflow_executions TO authenticated, service_role;
GRANT ALL PRIVILEGES ON TABLE workflow_step_executions TO authenticated, service_role;

-- Add comments for documentation
COMMENT ON TABLE agent_workflows IS 'Workflows specific to individual agents for step-by-step task execution';
COMMENT ON TABLE workflow_steps IS 'Individual steps within agent workflows';
COMMENT ON TABLE workflow_executions IS 'Records of workflow execution instances';
COMMENT ON TABLE workflow_step_executions IS 'Records of individual step executions within workflows'; 
-- Fix Agent Workflows Migration Issues
-- This migration fixes foreign key references and RLS policies

-- Drop existing foreign key constraints that reference the wrong column
ALTER TABLE agent_workflows DROP CONSTRAINT IF EXISTS agent_workflows_agent_id_fkey;
ALTER TABLE workflow_executions DROP CONSTRAINT IF EXISTS workflow_executions_agent_id_fkey;

-- Add correct foreign key constraints
ALTER TABLE agent_workflows 
ADD CONSTRAINT agent_workflows_agent_id_fkey 
FOREIGN KEY (agent_id) REFERENCES agents(agent_id) ON DELETE CASCADE;

ALTER TABLE workflow_executions 
ADD CONSTRAINT workflow_executions_agent_id_fkey 
FOREIGN KEY (agent_id) REFERENCES agents(agent_id) ON DELETE CASCADE;

-- Drop existing RLS policies
DROP POLICY IF EXISTS "Users can view workflows for their agents" ON agent_workflows;
DROP POLICY IF EXISTS "Users can create workflows for their agents" ON agent_workflows;
DROP POLICY IF EXISTS "Users can update workflows for their agents" ON agent_workflows;
DROP POLICY IF EXISTS "Users can delete workflows for their agents" ON agent_workflows;
DROP POLICY IF EXISTS "Users can view steps for their workflows" ON workflow_steps;
DROP POLICY IF EXISTS "Users can manage steps for their workflows" ON workflow_steps;
DROP POLICY IF EXISTS "Users can view executions for their workflows" ON workflow_executions;
DROP POLICY IF EXISTS "Users can view step executions for their workflows" ON workflow_step_executions;

-- Create correct RLS policies
CREATE POLICY "Users can view workflows for their agents" ON agent_workflows
    FOR SELECT USING (
        agent_id IN (
            SELECT agent_id FROM agents 
            WHERE basejump.has_role_on_account(account_id)
        )
    );

CREATE POLICY "Users can create workflows for their agents" ON agent_workflows
    FOR INSERT WITH CHECK (
        agent_id IN (
            SELECT agent_id FROM agents 
            WHERE basejump.has_role_on_account(account_id)
        )
    );

CREATE POLICY "Users can update workflows for their agents" ON agent_workflows
    FOR UPDATE USING (
        agent_id IN (
            SELECT agent_id FROM agents 
            WHERE basejump.has_role_on_account(account_id)
        )
    );

CREATE POLICY "Users can delete workflows for their agents" ON agent_workflows
    FOR DELETE USING (
        agent_id IN (
            SELECT agent_id FROM agents 
            WHERE basejump.has_role_on_account(account_id)
        )
    );

CREATE POLICY "Users can view steps for their workflows" ON workflow_steps
    FOR SELECT USING (
        workflow_id IN (
            SELECT id FROM agent_workflows 
            WHERE agent_id IN (
                SELECT agent_id FROM agents 
                WHERE basejump.has_role_on_account(account_id)
            )
        )
    );

CREATE POLICY "Users can manage steps for their workflows" ON workflow_steps
    FOR ALL USING (
        workflow_id IN (
            SELECT id FROM agent_workflows 
            WHERE agent_id IN (
                SELECT agent_id FROM agents 
                WHERE basejump.has_role_on_account(account_id)
            )
        )
    );

CREATE POLICY "Users can view executions for their workflows" ON workflow_executions
    FOR SELECT USING (
        workflow_id IN (
            SELECT id FROM agent_workflows 
            WHERE agent_id IN (
                SELECT agent_id FROM agents 
                WHERE basejump.has_role_on_account(account_id)
            )
        )
    );

CREATE POLICY "Users can view step executions for their workflows" ON workflow_step_executions
    FOR SELECT USING (
        execution_id IN (
            SELECT id FROM workflow_executions
            WHERE workflow_id IN (
                SELECT id FROM agent_workflows 
                WHERE agent_id IN (
                    SELECT agent_id FROM agents 
                    WHERE basejump.has_role_on_account(account_id)
                )
            )
        )
    );

-- Create missing function if it doesn't exist
CREATE OR REPLACE FUNCTION update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Add missing triggers if they don't exist
DROP TRIGGER IF EXISTS update_agent_workflows_updated_at ON agent_workflows;
CREATE TRIGGER update_agent_workflows_updated_at 
    BEFORE UPDATE ON agent_workflows
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

DROP TRIGGER IF EXISTS update_workflow_steps_updated_at ON workflow_steps;
CREATE TRIGGER update_workflow_steps_updated_at 
    BEFORE UPDATE ON workflow_steps
    FOR EACH ROW EXECUTE FUNCTION update_updated_at_column(); 
ALTER TYPE workflow_step_type ADD VALUE 'instruction'; 
UPDATE workflow_steps SET type = 'instruction';

ALTER TABLE workflow_steps 
ALTER COLUMN type SET DEFAULT 'instruction';

COMMENT ON COLUMN workflow_steps.type IS 'Step type - defaults to instruction. All steps are now simple instructions with optional tool configuration.';
COMMENT ON COLUMN workflow_steps.config IS 'Step configuration including optional tool_name and tool-specific settings'; 
-- Migration: Add streaming parameters to agent_runs table
-- This migration adds a metadata field to track the exact parameters 
-- used for each agent run

BEGIN;

-- Add metadata column to agent_runs table for streaming configuration
ALTER TABLE agent_runs ADD COLUMN IF NOT EXISTS metadata JSONB DEFAULT '{}'::jsonb;

-- Create index for metadata queries (useful for filtering by model, etc.)
CREATE INDEX IF NOT EXISTS idx_agent_runs_metadata ON agent_runs USING GIN (metadata);

-- Add comment to document the metadata column
COMMENT ON COLUMN agent_runs.metadata IS 'Streaming and configuration parameters for this agent run (model_name, enable_thinking, reasoning_effort, enable_context_manager, etc.)';

COMMIT; 
BEGIN;

-- Add steps column to agent_workflows table as flexible JSON
ALTER TABLE agent_workflows ADD COLUMN IF NOT EXISTS steps JSONB DEFAULT NULL;

-- Create index for steps column (GIN index for flexible JSON queries)
CREATE INDEX IF NOT EXISTS idx_agent_workflows_steps ON agent_workflows USING gin(steps);

UPDATE agent_workflows 
SET steps = (
    SELECT COALESCE(
        jsonb_agg(
            json_build_object(
                'id', ws.id,
                'name', ws.name,
                'description', ws.description,
                'type', ws.type,
                'config', ws.config,
                'conditions', ws.conditions,
                'step_order', ws.step_order
            ) ORDER BY ws.step_order
        ), 
        NULL
    )
    FROM workflow_steps ws 
    WHERE ws.workflow_id = agent_workflows.id
)
WHERE steps IS NULL;

-- Add comment to document the flexible nature
COMMENT ON COLUMN agent_workflows.steps IS 'Flexible JSON field for storing workflow steps. Structure can evolve over time without database migrations.';

COMMIT; 
BEGIN;

DROP TABLE IF EXISTS workflow_flows CASCADE;
DROP TABLE IF EXISTS workflow_execution_logs CASCADE;
DROP TABLE IF EXISTS workflow_variables CASCADE;
DROP TABLE IF EXISTS webhook_registrations CASCADE;
DROP TABLE IF EXISTS scheduled_jobs CASCADE;
DROP TABLE IF EXISTS triggers CASCADE;
DROP TABLE IF EXISTS agent_instances CASCADE;
DROP TABLE IF EXISTS oauth_installations CASCADE;
DROP TABLE IF EXISTS credential_usage_log CASCADE;
DROP TABLE IF EXISTS user_agent_library CASCADE;

DROP TABLE IF EXISTS workflow_templates CASCADE;
DROP TABLE IF EXISTS workflows CASCADE;

DROP TYPE IF EXISTS connection_type CASCADE;
DROP TYPE IF EXISTS node_type CASCADE;
DROP TYPE IF EXISTS trigger_type CASCADE;
DROP TYPE IF EXISTS execution_status CASCADE;
DROP TYPE IF EXISTS workflow_status CASCADE;

DROP TABLE IF EXISTS user_mcp_credentials CASCADE;

ALTER TABLE agents ADD COLUMN IF NOT EXISTS config JSONB DEFAULT '{}'::jsonb;

UPDATE agents 
SET config = jsonb_build_object(
    'system_prompt', COALESCE(system_prompt, ''),
    'tools', jsonb_build_object(
        'agentpress', (
            SELECT jsonb_object_agg(
                key, 
                (value->>'enabled')::boolean
            )
            FROM jsonb_each(COALESCE(agentpress_tools, '{}'::jsonb))
            WHERE value IS NOT NULL AND value != 'null'::jsonb
        ),
        'mcp', COALESCE(configured_mcps, '[]'::jsonb),
        'custom_mcp', COALESCE(custom_mcps, '[]'::jsonb)
    ),
    'metadata', jsonb_build_object(
        'avatar', avatar,
        'avatar_color', avatar_color
    )
)
WHERE config = '{}'::jsonb OR config IS NULL;

ALTER TABLE agent_versions ADD COLUMN IF NOT EXISTS config JSONB DEFAULT '{}'::jsonb;

UPDATE agent_versions 
SET config = jsonb_build_object(
    'system_prompt', COALESCE(system_prompt, ''),
    'tools', jsonb_build_object(
        'agentpress', (
            SELECT jsonb_object_agg(
                key, 
                (value->>'enabled')::boolean
            )
            FROM jsonb_each(COALESCE(agentpress_tools, '{}'::jsonb))
            WHERE value IS NOT NULL AND value != 'null'::jsonb
        ),
        'mcp', COALESCE(configured_mcps, '[]'::jsonb),
        'custom_mcp', COALESCE(custom_mcps, '[]'::jsonb)
    )
)
WHERE config = '{}'::jsonb OR config IS NULL;

ALTER TABLE agent_versions ADD COLUMN IF NOT EXISTS change_description TEXT;
ALTER TABLE agent_versions ADD COLUMN IF NOT EXISTS previous_version_id UUID REFERENCES agent_versions(version_id);

DROP TABLE IF EXISTS agent_version_history CASCADE;

ALTER TABLE agent_triggers ADD COLUMN IF NOT EXISTS execution_type VARCHAR(50) DEFAULT 'agent' CHECK (execution_type IN ('agent', 'workflow'));
ALTER TABLE agent_triggers ADD COLUMN IF NOT EXISTS workflow_id UUID REFERENCES agent_workflows(id) ON DELETE SET NULL;

ALTER TABLE trigger_events ADD COLUMN IF NOT EXISTS workflow_execution_id UUID REFERENCES workflow_executions(id) ON DELETE SET NULL;

COMMENT ON COLUMN agents.system_prompt IS 'DEPRECATED: Use config->>system_prompt instead';
COMMENT ON COLUMN agents.configured_mcps IS 'DEPRECATED: Use config->>tools->>mcp instead';
COMMENT ON COLUMN agents.agentpress_tools IS 'DEPRECATED: Use config->>tools->>agentpress instead';
COMMENT ON COLUMN agents.custom_mcps IS 'DEPRECATED: Use config->>tools->>custom_mcp instead';
COMMENT ON COLUMN agents.avatar IS 'DEPRECATED: Use config->>metadata->>avatar instead';
COMMENT ON COLUMN agents.avatar_color IS 'DEPRECATED: Use config->>metadata->>avatar_color instead';

COMMENT ON COLUMN agent_versions.system_prompt IS 'DEPRECATED: Use config->>system_prompt instead';
COMMENT ON COLUMN agent_versions.configured_mcps IS 'DEPRECATED: Use config->>tools->>mcp instead';
COMMENT ON COLUMN agent_versions.agentpress_tools IS 'DEPRECATED: Use config->>tools->>agentpress instead';
COMMENT ON COLUMN agent_versions.custom_mcps IS 'DEPRECATED: Use config->>tools->>custom_mcp instead';

CREATE OR REPLACE FUNCTION get_agent_config(p_agent_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
    v_agent RECORD;
    v_config JSONB;
BEGIN
    SELECT * INTO v_agent FROM agents WHERE agent_id = p_agent_id;
    
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    
    IF v_agent.config IS NOT NULL AND v_agent.config != '{}'::jsonb THEN
        RETURN v_agent.config;
    END IF;
    
    v_config := jsonb_build_object(
        'system_prompt', COALESCE(v_agent.system_prompt, ''),
        'tools', jsonb_build_object(
            'agentpress', (
                SELECT jsonb_object_agg(
                    key, 
                    (value->>'enabled')::boolean
                )
                FROM jsonb_each(COALESCE(v_agent.agentpress_tools, '{}'::jsonb))
                WHERE value IS NOT NULL AND value != 'null'::jsonb
            ),
            'mcp', COALESCE(v_agent.configured_mcps, '[]'::jsonb),
            'custom_mcp', COALESCE(v_agent.custom_mcps, '[]'::jsonb)
        ),
        'metadata', jsonb_build_object(
            'avatar', v_agent.avatar,
            'avatar_color', v_agent.avatar_color
        )
    );
    
    RETURN v_config;
END;
$$;

GRANT EXECUTE ON FUNCTION get_agent_config(UUID) TO authenticated, service_role;

COMMENT ON TABLE agent_workflows IS 'Agent workflows - step-by-step task execution';
COMMENT ON TABLE workflow_steps IS 'Individual steps within an agent workflow';
COMMENT ON TABLE workflow_executions IS 'Execution history of agent workflows';
COMMENT ON TABLE workflow_step_executions IS 'Detailed execution logs for each workflow step';

COMMENT ON COLUMN agents.config IS 'Unified configuration object containing all agent settings';
COMMENT ON COLUMN agent_versions.config IS 'Versioned configuration snapshot';

COMMENT ON COLUMN agents.is_default IS 'Whether this agent is the default for the account (only one allowed per account)';
COMMENT ON COLUMN agent_triggers.execution_type IS 'Whether trigger executes an agent conversation or a workflow';

COMMIT; 
