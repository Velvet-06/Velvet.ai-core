-- Create a default agent for the user
-- This will allow the backend to find an agent and proceed

-- First, let's check if the user has an account
SELECT * FROM public.accounts WHERE id = '213d7610-886b-469e-a90a-d4344e5b367a';

-- Create a default agent for the user
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
