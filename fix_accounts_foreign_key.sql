-- Fix the foreign key constraint issue between agents and accounts tables

-- 1. First, let's see what the foreign key constraint is actually pointing to
SELECT 
    tc.constraint_name,
    tc.table_name,
    kcu.column_name,
    ccu.table_name AS foreign_table_name,
    ccu.column_name AS foreign_column_name
FROM information_schema.table_constraints AS tc
JOIN information_schema.key_column_usage AS kcu
    ON tc.constraint_name = kcu.constraint_name
JOIN information_schema.constraint_column_usage AS ccu
    ON ccu.constraint_name = tc.constraint_name
WHERE tc.constraint_type = 'FOREIGN KEY' 
    AND tc.table_name = 'agents'
    AND kcu.column_name = 'account_id';

-- 2. Check what accounts tables exist in different schemas
SELECT schemaname, tablename 
FROM pg_tables 
WHERE tablename = 'accounts'
ORDER BY schemaname;

-- 3. Check if your user exists in basejump.accounts
SELECT * FROM basejump.accounts WHERE id = '213d7610-886b-469e-a90a-d4344e5b367a';

-- 4. If your user doesn't exist in basejump.accounts, create them there
INSERT INTO basejump.accounts (
    id,
    name,
    slug,
    created_at,
    updated_at
) VALUES (
    '213d7610-886b-469e-a90a-d4344e5b367a', -- your user ID
    'Your Account',
    'your-account',
    NOW(),
    NOW()
) ON CONFLICT (id) DO NOTHING;

-- 5. Verify the account was created
SELECT * FROM basejump.accounts WHERE id = '213d7610-886b-469e-a90a-d4344e5b367a';

-- 6. Now try to create the agent again
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
    gen_random_uuid(),
    '213d7610-886b-469e-a90a-d4344e5b367a',
    'Default Assistant',
    'Your default AI assistant',
    'You are a helpful AI assistant. Help the user with their requests.',
    true,
    false,
    NOW(),
    NOW()
);

-- 7. Verify the agent was created
SELECT * FROM public.agents WHERE account_id = '213d7610-886b-469e-a90a-d4344e5b367a';

-- 8. Check the total count
SELECT COUNT(*) FROM public.agents;
