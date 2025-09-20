-- Test script to verify authorization is working
-- Run this after applying the fixes to check if everything is working

-- 1. Test if you can access your own projects
SELECT 
    'Can access own projects' as test,
    COUNT(*) as project_count
FROM public.projects 
WHERE account_id = '213d7610-886b-469e-a90a-d4344e5b367a';

-- 2. Test if you can access threads in your projects
SELECT 
    'Can access threads in own projects' as test,
    COUNT(*) as thread_count
FROM public.threads 
WHERE account_id = '213d7610-886b-469e-a90a-d4344e5b367a';

-- 3. Test if you can access agent runs in your threads
SELECT 
    'Can access agent runs in own threads' as test,
    COUNT(*) as agent_run_count
FROM public.agent_runs 
WHERE account_id = '213d7610-886b-469e-a90a-d4344e5b367a';

-- 4. Test the specific thread from the logs
SELECT 
    'Specific thread access' as test,
    t.thread_id,
    t.project_id,
    t.account_id,
    p.name as project_name,
    p.account_id as project_account_id
FROM public.threads t
JOIN public.projects p ON t.project_id = p.project_id
WHERE t.thread_id = '1f67a943-44ca-4854-9718-b3bb2915d849';

-- 5. Test if you can see agent runs for that specific thread
SELECT 
    'Agent runs for specific thread' as test,
    COUNT(*) as agent_run_count
FROM public.agent_runs 
WHERE thread_id = '1f67a943-44ca-4854-9718-b3bb2915d849'
AND account_id = '213d7610-886b-469e-a90a-d4344e5b367a';

-- 6. Check RLS policies are working
SELECT 
    'RLS Policies Status' as info,
    schemaname,
    tablename,
    policyname,
    cmd,
    permissive
FROM pg_policies 
WHERE tablename IN ('projects', 'threads', 'agent_runs')
ORDER BY tablename, policyname;

-- 7. Test a simple query that should work
SELECT 
    'Simple query test' as test,
    ar.id as agent_run_id,
    ar.thread_id,
    ar.status,
    t.account_id as thread_account_id,
    p.account_id as project_account_id
FROM public.agent_runs ar
JOIN public.threads t ON ar.thread_id = t.thread_id
JOIN public.projects p ON t.project_id = p.project_id
WHERE ar.account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
LIMIT 3;
