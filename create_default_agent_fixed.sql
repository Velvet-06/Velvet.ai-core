-- Create a default agent for the user (FIXED VERSION)
-- This will allow the backend to find an agent and proceed

-- First, let's check what schemas and tables exist
SELECT schemaname, tablename 
FROM pg_tables 
WHERE tablename IN ('accounts', 'agents')
ORDER BY schemaname, tablename;

-- Check if the user exists in basejump.accounts
SELECT * FROM basejump.accounts WHERE id = '213d7610-886b-469e-a90a-d4344e5b367a';

-- If the user doesn't exist in basejump.accounts, we need to create them there first
-- But let's try to create the agent directly first

-- Create a default agent for the user (using the user ID directly as account_id)
INSERT INTO public.agents (
    agent_id,
    account_id,
    name,
    description,
    system_prompt,
    is_default,
    is_public,
    created_at,
    updated_at
) VALUES (
    gen_random_uuid(), -- agent_id
    '213d7610-886b-469e-a90a-d4344e5b367a', -- account_id (your user ID)
    'Default Assistant',
    'Your default AI assistant',
    'You are a helpful AI assistant. Help the user with their requests.',
    true, -- is_default
    false, -- is_public
    NOW(), -- created_at
    NOW()  -- updated_at
);

-- Verify the agent was created
SELECT * FROM public.agents WHERE account_id = '213d7610-886b-469e-a90a-d4344e5b367a';

-- Check the current count of agents
SELECT COUNT(*) FROM public.agents;

-- Also check if we need to create an agent_version record
SELECT * FROM public.agent_versions LIMIT 5;

-- If agent_versions table exists and needs a record, create one
INSERT INTO public.agent_versions (
    version_id,
    agent_id,
    version_number,
    system_prompt,
    configured_mcps,
    created_at,
    updated_at
) 
SELECT 
    gen_random_uuid(),
    a.agent_id,
    1,
    a.system_prompt,
    a.configured_mcps,
    NOW(),
    NOW()
FROM public.agents a 
WHERE a.account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
AND NOT EXISTS (
    SELECT 1 FROM public.agent_versions av WHERE av.agent_id = a.agent_id
);

-- Final verification - this should now show your agent
SELECT 
    agent_id,
    account_id,
    name,
    is_default,
    created_at
FROM public.agents 
WHERE account_id = '213d7610-886b-469e-a90a-d4344e5b367a';
