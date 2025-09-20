-- Comprehensive fix for Velvet.ai authorization issues
-- Run this in your Supabase SQL Editor to fix the "Forbidden" error

BEGIN;

-- 1. Ensure basejump schema exists
CREATE SCHEMA IF NOT EXISTS basejump;

-- 2. Create or update the accounts table if it doesn't exist
CREATE TABLE IF NOT EXISTS basejump.accounts (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    primary_owner_user_id uuid REFERENCES auth.users(id) NOT NULL,
    name text,
    slug text UNIQUE,
    personal_account boolean DEFAULT false NOT NULL,
    updated_at timestamp with time zone DEFAULT now(),
    created_at timestamp with time zone DEFAULT now(),
    created_by uuid REFERENCES auth.users(id),
    updated_by uuid REFERENCES auth.users(id),
    private_metadata jsonb DEFAULT '{}'::jsonb,
    public_metadata jsonb DEFAULT '{}'::jsonb
);

-- 3. Ensure your personal account exists
INSERT INTO basejump.accounts (id, name, slug, personal_account, created_at, updated_at, private_metadata, public_metadata, primary_owner_user_id)
VALUES ('213d7610-886b-469e-a90a-d4344e5b367a', 'Personal Account', null, true, now(), now(), '{}'::jsonb, '{}'::jsonb, '213d7610-886b-469e-a90a-d4344e5b367a')
ON CONFLICT (id) DO UPDATE SET 
    primary_owner_user_id = EXCLUDED.primary_owner_user_id,
    updated_at = now();

-- 4. Create projects table if it doesn't exist
CREATE TABLE IF NOT EXISTS public.projects (
    project_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name text NOT NULL,
    description text,
    account_id uuid NOT NULL REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    sandbox jsonb DEFAULT '{}'::jsonb,
    is_public boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);

-- 5. Create threads table if it doesn't exist
CREATE TABLE IF NOT EXISTS public.threads (
    thread_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    project_id uuid REFERENCES public.projects(project_id) ON DELETE CASCADE,
    is_public boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);

-- 6. Create agent_runs table if it doesn't exist
CREATE TABLE IF NOT EXISTS public.agent_runs (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id uuid NOT NULL REFERENCES public.threads(thread_id) ON DELETE CASCADE,
    account_id uuid REFERENCES basejump.accounts(id) ON DELETE CASCADE,
    status text NOT NULL DEFAULT 'running',
    started_at timestamp with time zone DEFAULT now(),
    completed_at timestamp with time zone,
    responses jsonb NOT NULL DEFAULT '[]'::jsonb,
    error text,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);

-- 7. Add account_id column to agent_runs if it doesn't exist
DO $$ 
BEGIN
    IF NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_name = 'agent_runs' AND column_name = 'account_id') THEN
        ALTER TABLE public.agent_runs ADD COLUMN account_id uuid REFERENCES basejump.accounts(id) ON DELETE CASCADE;
    END IF;
END $$;

-- 8. Fix existing data - assign all projects to your account
UPDATE public.projects 
SET account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
WHERE account_id IS NULL OR account_id != '213d7610-886b-469e-a90a-d4344e5b367a';

-- 9. Fix existing threads - assign to your account
UPDATE public.threads 
SET account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
WHERE account_id IS NULL OR account_id != '213d7610-886b-469e-a90a-d4344e5b367a';

-- 10. Fix existing agent_runs - assign to your account
UPDATE public.agent_runs 
SET account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
WHERE account_id IS NULL OR account_id != '213d7610-886b-469e-a90a-d4344e5b367a';

-- 11. Make all projects public for now (for testing)
UPDATE public.projects 
SET is_public = true;

-- 12. Create indexes for better performance
CREATE INDEX IF NOT EXISTS idx_projects_account_id ON public.projects(account_id);
CREATE INDEX IF NOT EXISTS idx_threads_account_id ON public.threads(account_id);
CREATE INDEX IF NOT EXISTS idx_threads_project_id ON public.threads(project_id);
CREATE INDEX IF NOT EXISTS idx_agent_runs_thread_id ON public.agent_runs(thread_id);
CREATE INDEX IF NOT EXISTS idx_agent_runs_account_id ON public.agent_runs(account_id);

-- 13. Enable RLS
ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_runs ENABLE ROW LEVEL SECURITY;

-- 14. Drop existing policies if they exist
DROP POLICY IF EXISTS project_select_policy ON public.projects;
DROP POLICY IF EXISTS project_insert_policy ON public.projects;
DROP POLICY IF EXISTS project_update_policy ON public.projects;
DROP POLICY IF EXISTS project_delete_policy ON public.projects;

DROP POLICY IF EXISTS thread_select_policy ON public.threads;
DROP POLICY IF EXISTS thread_insert_policy ON public.threads;
DROP POLICY IF EXISTS thread_update_policy ON public.threads;
DROP POLICY IF EXISTS thread_delete_policy ON public.threads;

DROP POLICY IF EXISTS agent_run_select_policy ON public.agent_runs;
DROP POLICY IF EXISTS agent_run_insert_policy ON public.agent_runs;
DROP POLICY IF EXISTS agent_run_update_policy ON public.agent_runs;
DROP POLICY IF EXISTS agent_run_delete_policy ON public.agent_runs;

-- 15. Create permissive policies for testing
CREATE POLICY project_select_policy ON public.projects
    FOR SELECT
    USING (
        is_public = TRUE OR
        account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
    );

CREATE POLICY project_insert_policy ON public.projects
    FOR INSERT
    WITH CHECK (account_id = '213d7610-886b-469e-a90a-d4344e5b367a');

CREATE POLICY project_update_policy ON public.projects
    FOR UPDATE
    USING (account_id = '213d7610-886b-469e-a90a-d4344e5b367a');

CREATE POLICY project_delete_policy ON public.projects
    FOR DELETE
    USING (account_id = '213d7610-886b-469e-a90a-d4344e5b367a');

CREATE POLICY thread_select_policy ON public.threads
    FOR SELECT
    USING (
        account_id = '213d7610-886b-469e-a90a-d4344e5b367a' OR
        project_id IN (
            SELECT project_id FROM public.projects 
            WHERE account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
        )
    );

CREATE POLICY thread_insert_policy ON public.threads
    FOR INSERT
    WITH CHECK (account_id = '213d7610-886b-469e-a90a-d4344e5b367a');

CREATE POLICY thread_update_policy ON public.threads
    FOR UPDATE
    USING (account_id = '213d7610-886b-469e-a90a-d4344e5b367a');

CREATE POLICY thread_delete_policy ON public.threads
    FOR DELETE
    USING (account_id = '213d7610-886b-469e-a90a-d4344e5b367a');

CREATE POLICY agent_run_select_policy ON public.agent_runs
    FOR SELECT
    USING (
        account_id = '213d7610-886b-469e-a90a-d4344e5b367a' OR
        thread_id IN (
            SELECT thread_id FROM public.threads 
            WHERE account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
        )
    );

CREATE POLICY agent_run_insert_policy ON public.agent_runs
    FOR INSERT
    WITH CHECK (account_id = '213d7610-886b-469e-a90a-d4344e5b367a');

CREATE POLICY agent_run_update_policy ON public.agent_runs
    FOR UPDATE
    USING (account_id = '213d7610-886b-469e-a90a-d4344e5b367a');

CREATE POLICY agent_run_delete_policy ON public.agent_runs
    FOR DELETE
    USING (account_id = '213d7610-886b-469e-a90a-d4344e5b367a');

-- 16. Verify the fix worked
SELECT 
    'Projects' as table_name,
    COUNT(*) as count,
    COUNT(CASE WHEN account_id = '213d7610-886b-469e-a90a-d4344e5b367a' THEN 1 END) as owned_by_user
FROM public.projects;

SELECT 
    'Threads' as table_name,
    COUNT(*) as count,
    COUNT(CASE WHEN account_id = '213d7610-886b-469e-a90a-d4344e5b367a' THEN 1 END) as owned_by_user
FROM public.threads;

SELECT 
    'Agent Runs' as table_name,
    COUNT(*) as count,
    COUNT(CASE WHEN account_id = '213d7610-886b-469e-a90a-d4344e5b367a' THEN 1 END) as owned_by_user
FROM public.agent_runs;

-- 17. Check specific thread and project from logs
SELECT 
    'Specific Thread' as info,
    thread_id,
    project_id,
    account_id
FROM public.threads 
WHERE thread_id = '1f67a943-44ca-4854-9718-b3bb2915d849';

SELECT 
    'Specific Project' as info,
    project_id,
    name,
    account_id,
    is_public
FROM public.projects 
WHERE project_id = '6fb09262-3834-4ed7-aa21-453f001abb28';

COMMIT;
