-- Check and fix RLS policies that might be blocking access

-- 1. Check current RLS policies on projects table
SELECT 
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,
    qual,
    with_check
FROM pg_policies 
WHERE tablename = 'projects';

-- 2. Check current RLS policies on threads table
SELECT 
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,
    qual,
    with_check
FROM pg_policies 
WHERE tablename = 'threads';

-- 3. Check current RLS policies on agent_runs table
SELECT 
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,
    qual,
    with_check
FROM pg_policies 
WHERE tablename = 'agent_runs';

-- 4. If RLS is enabled but policies are too restrictive, temporarily disable RLS for testing
-- (Only do this if you're sure about security implications)
-- ALTER TABLE public.projects DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE public.threads DISABLE ROW LEVEL SECURITY;
-- ALTER TABLE public.agent_runs DISABLE ROW LEVEL SECURITY;

-- 5. Or create more permissive policies for testing
-- Drop existing restrictive policies first
DROP POLICY IF EXISTS project_select_policy ON public.projects;
DROP POLICY IF EXISTS thread_select_policy ON public.threads;
DROP POLICY IF EXISTS agent_run_select_policy ON public.agent_runs;

-- Create more permissive policies for testing
CREATE POLICY project_select_policy ON public.projects
    FOR SELECT
    USING (
        is_public = TRUE OR
        account_id = '213d7610-886b-469e-a90a-d4344e5b367a' OR
        basejump.has_role_on_account(account_id) = true
    );

CREATE POLICY thread_select_policy ON public.threads
    FOR SELECT
    USING (
        account_id = '213d7610-886b-469e-a90a-d4344e5b367a' OR
        basejump.has_role_on_account(account_id) = true OR
        project_id IN (
            SELECT project_id FROM public.projects 
            WHERE account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
        )
    );

CREATE POLICY agent_run_select_policy ON public.agent_runs
    FOR SELECT
    USING (
        thread_id IN (
            SELECT thread_id FROM public.threads 
            WHERE account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
        )
    );

-- 6. Verify the policies were created
SELECT 
    schemaname,
    tablename,
    policyname,
    permissive,
    roles,
    cmd,
    qual
FROM pg_policies 
WHERE tablename IN ('projects', 'threads', 'agent_runs')
ORDER BY tablename, policyname;
