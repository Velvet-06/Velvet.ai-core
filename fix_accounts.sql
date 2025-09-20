-- Fix the accounts table to match what the backend expects
-- The backend code sets account_id = user_id, so we need to make sure
-- the account.id matches the user_id

-- First, let's see what we have
SELECT 'Current accounts table:' as info;
SELECT * FROM public.accounts;

-- The issue: backend expects account_id to be the same as user_id
-- But our foreign key expects account_id to reference accounts.id
-- We need to fix this by updating the account record

-- Update the account to have id = user_id (this is what backend expects)
UPDATE public.accounts 
SET id = user_id 
WHERE user_id = '213d7610-886b-469e-a90a-d4344e5b367a';

-- Verify the fix
SELECT 'After fix:' as info;
SELECT * FROM public.accounts;

-- Now test if the foreign key works
-- This should work now because account_id will reference accounts.id correctly
SELECT 'Foreign key test:' as info;
SELECT 
    tc.constraint_name, 
    tc.table_name, 
    kcu.column_name, 
    ccu.table_name AS foreign_table_name, 
    ccu.column_name AS foreign_column_name 
FROM information_schema.table_constraints AS tc 
JOIN information_schema.key_column_usage AS kcu ON tc.constraint_name = kcu.constraint_name 
JOIN information_schema.constraint_column_usage AS ccu ON ccu.constraint_name = tc.constraint_name 
WHERE tc.constraint_type = 'FOREIGN KEY' 
AND tc.table_name = 'projects' 
AND kcu.column_name = 'account_id';
