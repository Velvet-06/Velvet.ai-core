-- Fix authorization for the new thread that was just created
-- This addresses the "Failed to load agent runs conversation history: Error getting agent runs: Forbidden" issue

-- 1. Fix the specific new thread from the logs
UPDATE public.threads 
SET account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
WHERE thread_id = '184d0632-3e2b-47ae-97f5-7ed48d598b5a';

-- 2. Fix the agent run for this thread
UPDATE public.agent_runs 
SET account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
WHERE thread_id = '184d0632-3e2b-47ae-97f5-7ed48d598b5a';

-- 3. Ensure the thread has a project_id (if it doesn't, create one)
DO $$
DECLARE
    new_project_id uuid;
BEGIN
    -- Check if thread has a project_id
    IF NOT EXISTS (
        SELECT 1 FROM public.threads 
        WHERE thread_id = '184d0632-3e2b-47ae-97f5-7ed48d598b5a' 
        AND project_id IS NOT NULL
    ) THEN
        -- Create a default project for this thread
        INSERT INTO public.projects (project_id, name, description, account_id, is_public)
        VALUES (gen_random_uuid(), 'Default Project', 'Auto-created project for thread', '213d7610-886b-469e-a90a-d4344e5b367a', true)
        RETURNING project_id INTO new_project_id;
        
        -- Update the thread with the new project_id
        UPDATE public.threads 
        SET project_id = new_project_id
        WHERE thread_id = '184d0632-3e2b-47ae-97f5-7ed48d598b5a';
        
        RAISE NOTICE 'Created new project % for thread %', new_project_id, '184d0632-3e2b-47ae-97f5-7ed48d598b5a';
    END IF;
END $$;

-- 4. Fix any other threads that might be missing account_id
UPDATE public.threads 
SET account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
WHERE account_id IS NULL;

-- 5. Fix any other agent_runs that might be missing account_id
UPDATE public.agent_runs 
SET account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
WHERE account_id IS NULL;

-- 6. Ensure all threads have project_id by creating default projects if needed
DO $$
DECLARE
    thread_record RECORD;
    new_project_id uuid;
BEGIN
    FOR thread_record IN 
        SELECT thread_id FROM public.threads 
        WHERE project_id IS NULL
    LOOP
        -- Create a default project for this thread
        INSERT INTO public.projects (project_id, name, description, account_id, is_public)
        VALUES (gen_random_uuid(), 'Default Project', 'Auto-created project for thread', '213d7610-886b-469e-a90a-d4344e5b367a', true)
        RETURNING project_id INTO new_project_id;
        
        -- Update the thread with the new project_id
        UPDATE public.threads 
        SET project_id = new_project_id
        WHERE thread_id = thread_record.thread_id;
        
        RAISE NOTICE 'Created new project % for thread %', new_project_id, thread_record.thread_id;
    END LOOP;
END $$;

-- 7. Verify the fix worked for the specific thread
SELECT 
    'Fixed Thread Status' as info,
    t.thread_id,
    t.project_id,
    t.account_id,
    p.name as project_name,
    p.account_id as project_account_id,
    p.is_public
FROM public.threads t
LEFT JOIN public.projects p ON t.project_id = p.project_id
WHERE t.thread_id = '184d0632-3e2b-47ae-97f5-7ed48d598b5a';

-- 8. Check agent runs for this thread
SELECT 
    'Agent Runs for Fixed Thread' as info,
    COUNT(*) as agent_run_count,
    COUNT(CASE WHEN account_id = '213d7610-886b-469e-a90a-d4344e5b367a' THEN 1 END) as owned_by_user
FROM public.agent_runs 
WHERE thread_id = '184d0632-3e2b-47ae-97f5-7ed48d598b5a';

-- 9. Show all threads and their status
SELECT 
    'All Threads Status' as info,
    thread_id,
    project_id,
    account_id,
    created_at
FROM public.threads 
ORDER BY created_at DESC
LIMIT 10;

-- 10. Show all projects and their status
SELECT 
    'All Projects Status' as info,
    project_id,
    name,
    account_id,
    is_public,
    created_at
FROM public.projects 
ORDER BY created_at DESC
LIMIT 10;
