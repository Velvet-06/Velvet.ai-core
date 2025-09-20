-- Fix authorization issues for user 213d7610-886b-469e-a90a-d4344e5b367a
-- This script fixes the "Forbidden" error when trying to access agent runs

-- 1. Ensure your personal account row exists in basejump.accounts
INSERT INTO basejump.accounts (id, name, slug, personal_account, created_at, updated_at, private_metadata, public_metadata, primary_owner_user_id)
VALUES ('213d7610-886b-469e-a90a-d4344e5b367a', 'Personal Account', null, true, now(), now(), '{}'::jsonb, '{}'::jsonb, '213d7610-886b-469e-a90a-d4344e5b367a')
ON CONFLICT (id) DO UPDATE SET 
    primary_owner_user_id = EXCLUDED.primary_owner_user_id,
    updated_at = now();

-- 2. Fix the projects table - use project_id instead of id
-- First, let's see what projects exist and fix their account_id
UPDATE public.projects 
SET account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
WHERE project_id IN (
    SELECT project_id FROM public.projects 
    WHERE account_id IS NULL OR account_id != '213d7610-886b-469e-a90a-d4344e5b367a'
    LIMIT 10
);

-- 3. Fix threads to belong to your account
UPDATE public.threads 
SET account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
WHERE thread_id IN (
    SELECT thread_id FROM public.threads 
    WHERE account_id IS NULL OR account_id != '213d7610-886b-469e-a90a-d4344e5b367a'
    LIMIT 10
);

-- 4. Make sure projects are public or accessible
UPDATE public.projects 
SET is_public = true 
WHERE project_id IN (
    SELECT project_id FROM public.projects 
    WHERE is_public = false
    LIMIT 10
);

-- 5. Verify the current state
SELECT 
    'Projects' as table_name,
    project_id,
    name,
    account_id,
    is_public
FROM public.projects 
WHERE account_id = '213d7610-886b-469e-a90a-d4344e5b367a';

SELECT 
    'Threads' as table_name,
    thread_id,
    project_id,
    account_id
FROM public.threads 
WHERE account_id = '213d7610-886b-469e-a90a-d4344e5b367a';

-- 6. Check if the specific thread from the logs exists and fix it
UPDATE public.threads 
SET account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
WHERE thread_id = '1f67a943-44ca-4854-9718-b3bb2915d849';

-- 7. Check if the specific project from the logs exists and fix it
UPDATE public.projects 
SET account_id = '213d7610-886b-469e-a90a-d4344e5b367a',
    is_public = true
WHERE project_id = '6fb09262-3834-4ed7-aa21-453f001abb28';

-- 8. Verify the specific thread and project are now accessible
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
