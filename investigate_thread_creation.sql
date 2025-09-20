-- Investigate why new threads are being created without proper authorization
-- This will help us understand the root cause

-- 1. Check the current state of the newest thread
SELECT 
    'Newest Thread Investigation' as info,
    t.thread_id,
    t.project_id,
    t.account_id,
    t.created_at,
    p.name as project_name,
    p.account_id as project_account_id,
    p.is_public
FROM public.threads t
LEFT JOIN public.projects p ON t.project_id = p.project_id
WHERE t.thread_id = '79565a67-cb98-4a35-885a-95c3ac75a844';

-- 2. Check if there are any triggers or functions that might be setting account_id
SELECT 
    'Triggers on threads table' as info,
    trigger_name,
    event_manipulation,
    action_statement
FROM information_schema.triggers 
WHERE event_object_table = 'threads';

-- 3. Check if there are any default values or constraints
SELECT 
    'Column defaults and constraints' as info,
    column_name,
    column_default,
    is_nullable,
    data_type
FROM information_schema.columns 
WHERE table_name = 'threads' 
  AND table_schema = 'public'
ORDER BY ordinal_position;

-- 4. Check if there are any functions that might be called during INSERT
SELECT 
    'Functions that might affect threads' as info,
    routine_name,
    routine_type,
    routine_definition
FROM information_schema.routines 
WHERE routine_definition LIKE '%threads%'
  AND routine_schema = 'public';

-- 5. Check the current RLS policies to see if they're blocking INSERT
SELECT 
    'Current RLS Policies - threads' as info,
    policyname,
    cmd,
    permissive,
    qual,
    with_check
FROM pg_policies 
WHERE tablename = 'threads'
ORDER BY policyname;

-- 6. Check if there are any foreign key constraints that might be failing
SELECT 
    'Foreign Key Constraints' as info,
    tc.constraint_name,
    tc.table_name,
    kcu.column_name,
    ccu.table_name AS foreign_table_name,
    ccu.column_name AS foreign_column_name
FROM information_schema.table_constraints AS tc 
JOIN information_schema.key_column_usage AS kcu
  ON tc.constraint_name = kcu.constraint_name
  AND tc.table_schema = kcu.table_schema
JOIN information_schema.constraint_column_usage AS ccu
  ON ccu.constraint_name = tc.constraint_name
  AND ccu.table_schema = tc.table_schema
WHERE tc.constraint_type = 'FOREIGN KEY' 
  AND tc.table_name = 'threads';

-- 7. Check if there are any sequences or auto-increment fields
SELECT 
    'Sequences and defaults' as info,
    sequence_name,
    data_type,
    start_value,
    increment
FROM information_schema.sequences 
WHERE sequence_schema = 'public'
  AND sequence_name LIKE '%thread%';

-- 8. Check the actual INSERT statements that might be happening
-- This will show us what the backend is actually doing
SELECT 
    'Recent thread creation pattern' as info,
    thread_id,
    project_id,
    account_id,
    created_at,
    CASE 
        WHEN account_id IS NULL THEN 'MISSING account_id'
        WHEN project_id IS NULL THEN 'MISSING project_id'
        ELSE 'COMPLETE'
    END as status
FROM public.threads 
WHERE created_at > NOW() - INTERVAL '2 hours'
ORDER BY created_at DESC;

-- 9. Check if there are any views that might be interfering
SELECT 
    'Views that might affect threads' as info,
    table_name,
    view_definition
FROM information_schema.views 
WHERE table_schema = 'public'
  AND (view_definition LIKE '%threads%' OR table_name LIKE '%thread%');

-- 10. Check if the basejump schema has any functions that might be called
SELECT 
    'Basejump functions' as info,
    routine_name,
    routine_type
FROM information_schema.routines 
WHERE routine_schema = 'basejump'
  AND routine_name LIKE '%account%'
ORDER BY routine_name;
