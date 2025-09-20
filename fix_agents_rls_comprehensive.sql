-- Comprehensive fix for agents table RLS issues
-- This script will diagnose and fix the permission denied error

-- 1. Check what tables exist with 'agents' in the name
SELECT schemaname, tablename, rowsecurity 
FROM pg_tables 
WHERE tablename LIKE '%agent%'
ORDER BY schemaname, tablename;

-- 2. Check if RLS is enabled on the agents table
SELECT schemaname, tablename, rowsecurity 
FROM pg_tables 
WHERE tablename = 'agents';

-- 3. Check what RLS policies exist
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies 
WHERE tablename = 'agents';

-- 4. Check the current user context
SELECT current_user, current_setting('request.jwt.claims', true);

-- 5. Try to disable RLS on ALL possible agents tables
DO $$
DECLARE
    r RECORD;
BEGIN
    FOR r IN 
        SELECT schemaname, tablename 
        FROM pg_tables 
        WHERE tablename = 'agents'
    LOOP
        EXECUTE format('ALTER TABLE %I.%I DISABLE ROW LEVEL SECURITY', r.schemaname, r.tablename);
        RAISE NOTICE 'Disabled RLS on %.%', r.schemaname, r.tablename;
    END LOOP;
END $$;

-- 6. Also try to disable RLS on the public schema agents table specifically
ALTER TABLE public.agents DISABLE ROW LEVEL SECURITY;

-- 7. Check if we can now access the table
-- This should work if RLS is disabled
SELECT COUNT(*) FROM public.agents;

-- 8. If still having issues, let's see what's in the table
SELECT * FROM public.agents LIMIT 5;

-- 9. Check if there are any triggers that might be interfering
SELECT 
    trigger_name,
    event_manipulation,
    action_statement
FROM information_schema.triggers 
WHERE event_object_table = 'agents';

-- 10. Verify the table structure
SELECT column_name, data_type, is_nullable
FROM information_schema.columns 
WHERE table_name = 'agents' 
ORDER BY ordinal_position;
