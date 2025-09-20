-- Make thread deletion work for MVP
BEGIN;

-- 1) Ensure ON DELETE CASCADE from agent_runs -> threads
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.table_constraints
    WHERE constraint_name = 'agent_runs_thread_id_fkey'
      AND table_name = 'agent_runs'
  ) THEN
    ALTER TABLE public.agent_runs DROP CONSTRAINT agent_runs_thread_id_fkey;
  END IF;
  ALTER TABLE public.agent_runs
    ADD CONSTRAINT agent_runs_thread_id_fkey
    FOREIGN KEY (thread_id) REFERENCES public.threads(thread_id) ON DELETE CASCADE;
END $$;

-- 2) Ensure ON DELETE CASCADE from messages -> threads (if messages table exists)
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM information_schema.tables
    WHERE table_schema='public' AND table_name='messages'
  ) THEN
    IF EXISTS (
      SELECT 1 FROM information_schema.table_constraints
      WHERE constraint_name = 'messages_thread_id_fkey'
        AND table_name = 'messages'
    ) THEN
      ALTER TABLE public.messages DROP CONSTRAINT messages_thread_id_fkey;
    END IF;
    ALTER TABLE public.messages
      ADD CONSTRAINT messages_thread_id_fkey
      FOREIGN KEY (thread_id) REFERENCES public.threads(thread_id) ON DELETE CASCADE;
  END IF;
END $$;

-- 3) Permissive delete policies for MVP
ALTER TABLE public.threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agent_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS thread_delete_policy ON public.threads;
DROP POLICY IF EXISTS agent_run_delete_policy ON public.agent_runs;
DROP POLICY IF EXISTS message_delete_policy ON public.messages;

CREATE POLICY thread_delete_policy ON public.threads
  FOR DELETE TO authenticated USING (true);

CREATE POLICY agent_run_delete_policy ON public.agent_runs
  FOR DELETE TO authenticated USING (true);

CREATE POLICY message_delete_policy ON public.messages
  FOR DELETE TO authenticated USING (true);

COMMIT;
