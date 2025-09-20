-- Add missing columns that might be causing authorization issues

-- 1. Check if agent_runs table has account_id column
DO $$ 
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns 
        WHERE table_name = 'agent_runs' 
        AND column_name = 'account_id'
    ) THEN
        -- Add account_id column to agent_runs
        ALTER TABLE public.agent_runs ADD COLUMN account_id uuid;
        
        -- Add foreign key constraint
        ALTER TABLE public.agent_runs 
        ADD CONSTRAINT fk_agent_runs_account 
        FOREIGN KEY (account_id) REFERENCES basejump.accounts(id) ON DELETE CASCADE;
        
        RAISE NOTICE 'Added account_id column to agent_runs table';
    ELSE
        RAISE NOTICE 'account_id column already exists in agent_runs table';
    END IF;
END $$;

-- 2. Update existing agent_runs to have account_id based on their thread's project
UPDATE public.agent_runs 
SET account_id = (
    SELECT p.account_id 
    FROM public.threads t 
    JOIN public.projects p ON t.project_id = p.project_id 
    WHERE t.thread_id = public.agent_runs.thread_id
)
WHERE account_id IS NULL;

-- 3. Set account_id for any remaining agent_runs to your user ID
UPDATE public.agent_runs 
SET account_id = '213d7610-886b-469e-a90a-d4344e5b367a'
WHERE account_id IS NULL;

-- 4. Make account_id NOT NULL after populating it
ALTER TABLE public.agent_runs ALTER COLUMN account_id SET NOT NULL;

-- 5. Create index on account_id for better performance
CREATE INDEX IF NOT EXISTS idx_agent_runs_account_id ON public.agent_runs(account_id);

-- 6. Verify the changes
SELECT 
    'Agent Runs with account_id' as status,
    COUNT(*) as total_count,
    COUNT(CASE WHEN account_id IS NOT NULL THEN 1 END) as with_account_id,
    COUNT(CASE WHEN account_id = '213d7610-886b-469e-a90a-d4344e5b367a' THEN 1 END) as owned_by_user
FROM public.agent_runs;

-- 7. Show sample of updated agent_runs
SELECT 
    id,
    thread_id,
    account_id,
    status,
    created_at
FROM public.agent_runs 
LIMIT 5;
