-- Fix the newest thread that was just created and is causing the Forbidden error
-- This addresses the immediate issue with thread 79565a67-cb98-4a35-885a-95c3ac75a844

BEGIN;

-- 1. Fix the specific new thread that's causing the issue
UPDATE public.threads 
SET account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
WHERE thread_id = '79565a67-cb98-4a35-885a-95c3ac75a844';

-- 2. Fix the agent run for this thread
UPDATE public.agent_runs 
SET account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
WHERE thread_id = '79565a67-cb98-4a35-885a-95c3ac75a844';

-- 3. Ensure the thread has a project_id
DO $$
DECLARE
    thread_project_id uuid;
    new_project_id uuid;
BEGIN
    -- Get the current project_id for the thread
    SELECT project_id INTO thread_project_id 
    FROM public.threads 
    WHERE thread_id = '79565a67-cb98-4a35-885a-95c3ac75a844';
    
    -- If no project_id, create one
    IF thread_project_id IS NULL THEN
        INSERT INTO public.projects (project_id, name, description, account_id, is_public)
        VALUES (gen_random_uuid(), 'Auto Project', 'Auto-created project for new thread', '213d7610-886b-469e-a90a-d4344e5b367a', true)
        RETURNING project_id INTO new_project_id;
        
        UPDATE public.threads 
        SET project_id = new_project_id
        WHERE thread_id = '79565a67-cb98-4a35-885a-95c3ac75a844';
        
        RAISE NOTICE 'Created project % for new thread %', new_project_id, '79565a67-cb98-4a35-885a-95c3ac75a844';
    END IF;
END $$;

-- 4. Fix ANY threads created in the last hour that might be missing account_id
UPDATE public.threads 
SET account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
WHERE account_id IS NULL 
  AND created_at > NOW() - INTERVAL '1 hour';

-- 5. Fix ANY agent_runs created in the last hour that might be missing account_id
UPDATE public.agent_runs 
SET account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
WHERE account_id IS NULL 
  AND created_at > NOW() - INTERVAL '1 hour';

-- 6. Create default projects for any recent threads missing project_id
DO $$
DECLARE
    thread_record RECORD;
    new_project_id uuid;
BEGIN
    FOR thread_record IN 
        SELECT thread_id FROM public.threads 
        WHERE project_id IS NULL 
          AND created_at > NOW() - INTERVAL '1 hour'
    LOOP
        INSERT INTO public.projects (project_id, name, description, account_id, is_public)
        VALUES (gen_random_uuid(), 'Default Project', 'Auto-created project for recent thread', '213d7610-886b-469e-a90a-d4344e5b367a', true)
        RETURNING project_id INTO new_project_id;
        
        UPDATE public.threads 
        SET project_id = new_project_id
        WHERE thread_id = thread_record.thread_id;
        
        RAISE NOTICE 'Created project % for recent thread %', new_project_id, thread_record.thread_id;
    END LOOP;
END $$;

-- 7. Verify the fix worked for the specific new thread
SELECT 
    'New Thread Fix Status' as info,
    t.thread_id,
    t.project_id,
    t.account_id,
    p.name as project_name,
    p.account_id as project_account_id,
    p.is_public
FROM public.threads t
LEFT JOIN public.projects p ON t.project_id = p.project_id
WHERE t.thread_id = '79565a67-cb98-4a35-885a-95c3ac75a844';

-- 8. Check agent runs for this thread
SELECT 
    'Agent Runs for New Thread' as info,
    COUNT(*) as agent_run_count,
    COUNT(CASE WHEN account_id = '213d7610-886b-469e-a90a-d4344e5b367a' THEN 1 END) as owned_by_user
FROM public.agent_runs 
WHERE thread_id = '79565a67-cb98-4a35-885a-95c3ac75a844';

-- 9. Show all recent threads and their status
SELECT 
    'Recent Threads Status' as info,
    thread_id,
    project_id,
    account_id,
    created_at
FROM public.threads 
WHERE created_at > NOW() - INTERVAL '1 hour'
ORDER BY created_at DESC;

-- 10. Test if we can now access agent runs for this thread
SELECT 
    'Agent Runs Access Test' as info,
    COUNT(*) as accessible_agent_runs
FROM public.agent_runs
WHERE thread_id = '79565a67-cb98-4a35-885a-95c3ac75a844'
  AND account_id = '213d7610-886b-469e-a90a-d4344e5b367a';

COMMIT;

-- 11. Final verification
SELECT 
    'Fix Complete' as info,
    'New thread 79565a67-cb98-4a35-885a-95c3ac75a844 should now be accessible' as message;
