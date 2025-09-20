-- Debug RLS policy conflicts that might be causing the Forbidden error
-- This script helps identify why the frontend can't access agent runs

-- 1. Check if the current user has the right JWT claims
SELECT 
    'Current User JWT' as info,
    auth.jwt() as jwt_claims;

-- 2. Test the basejump.has_role_on_account function
SELECT 
    'Basejump Function Test' as info,
    basejump.has_role_on_account('213d7610-886b-469e-a90a-d4344e5b367a') as has_role;

-- 3. Test if we can manually query the tables (bypassing RLS)
-- This will show if the data exists but RLS is blocking access
SELECT 
    'Manual Query Test - Projects' as info,
    COUNT(*) as total_projects,
    COUNT(CASE WHEN account_id = '213d7610-886b-469e-a90a-d4344e5b367a' THEN 1 END) as user_projects
FROM public.projects;

SELECT 
    'Manual Query Test - Threads' as info,
    COUNT(*) as total_threads,
    COUNT(CASE WHEN account_id = '213d7610-886b-469e-a90a-d4344e5b367a' THEN 1 END) as user_threads
FROM public.threads;

SELECT 
    'Manual Query Test - Agent Runs' as info,
    COUNT(*) as total_agent_runs,
    COUNT(CASE WHEN account_id = '213d7610-886b-469e-a90a-d4344e5b367a' THEN 1 END) as user_agent_runs
FROM public.agent_runs;

-- 4. Test the specific thread that's failing
SELECT 
    'Specific Thread Test' as info,
    t.thread_id,
    t.project_id,
    t.account_id,
    p.name as project_name,
    p.account_id as project_account_id,
    p.is_public
FROM public.threads t
LEFT JOIN public.projects p ON t.project_id = p.project_id
WHERE t.thread_id = '184d0632-3e2b-47ae-97f5-7ed48d598b5a';

-- 5. Test if the RLS policies are working correctly
-- Try to simulate what the frontend is doing
SELECT 
    'RLS Policy Test - Projects' as info,
    COUNT(*) as accessible_projects
FROM public.projects
WHERE is_public = TRUE OR account_id = '213d7610-886b-469e-a90a-d4344e5b367a';

SELECT 
    'RLS Policy Test - Threads' as info,
    COUNT(*) as accessible_threads
FROM public.threads
WHERE account_id = '213d7610-886b-469e-a90a-d4344e5b367a' 
   OR project_id IN (
       SELECT project_id FROM public.projects 
       WHERE account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
   );

SELECT 
    'RLS Policy Test - Agent Runs' as info,
    COUNT(*) as accessible_agent_runs
FROM public.agent_runs
WHERE account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
   OR thread_id IN (
       SELECT thread_id FROM public.threads 
       WHERE account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
   );

-- 6. Check if there are any conflicting policies
SELECT 
    'Conflicting Policies Check' as info,
    schemaname,
    tablename,
    policyname,
    cmd,
    permissive,
    qual
FROM pg_policies 
WHERE tablename IN ('projects', 'threads', 'agent_runs')
  AND (qual LIKE '%basejump.has_role_on_account%' OR qual LIKE '%@kortix.ai%')
ORDER BY tablename, policyname;

-- 7. Test the exact query that the frontend might be using
-- This simulates the agent runs query that's failing
SELECT 
    'Frontend Query Simulation' as info,
    ar.id as agent_run_id,
    ar.thread_id,
    ar.status,
    ar.account_id,
    t.account_id as thread_account_id,
    p.account_id as project_account_id
FROM public.agent_runs ar
JOIN public.threads t ON ar.thread_id = t.thread_id
JOIN public.projects p ON t.project_id = p.project_id
WHERE t.thread_id = '184d0632-3e2b-47ae-97f5-7ed48d598b5a'
LIMIT 5;

-- 8. Check if there are any missing foreign key relationships
SELECT 
    'Foreign Key Check' as info,
    'agent_runs -> threads' as relationship,
    COUNT(*) as orphaned_agent_runs
FROM public.agent_runs ar
LEFT JOIN public.threads t ON ar.thread_id = t.thread_id
WHERE t.thread_id IS NULL;

SELECT 
    'Foreign Key Check' as info,
    'threads -> projects' as relationship,
    COUNT(*) as orphaned_threads
FROM public.threads t
LEFT JOIN public.projects p ON t.project_id = p.project_id
WHERE p.project_id IS NULL;

-- 9. Show the current state of all tables
SELECT 
    'Current Database State' as info,
    'projects' as table_name,
    COUNT(*) as record_count,
    COUNT(CASE WHEN account_id = '213d7610-886b-469e-a90a-d4344e5b367a' THEN 1 END) as user_records
FROM public.projects
UNION ALL
SELECT 
    'Current Database State' as info,
    'threads' as table_name,
    COUNT(*) as record_count,
    COUNT(CASE WHEN account_id = '213d7610-886b-469e-a90a-d4344e5b367a' THEN 1 END) as user_records
FROM public.threads
UNION ALL
SELECT 
    'Current Database State' as info,
    'agent_runs' as table_name,
    COUNT(*) as record_count,
    COUNT(CASE WHEN account_id = '213d7610-886b-469e-a90a-d4344e5b367a' THEN 1 END) as user_records
FROM public.agent_runs;
