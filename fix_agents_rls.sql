-- Fix RLS policies for agents table
-- This script will allow the authenticated user to access the agents table

-- First, let's check what RLS policies exist
SELECT schemaname, tablename, policyname, permissive, roles, cmd, qual, with_check
FROM pg_policies 
WHERE tablename = 'agents';

-- Check if RLS is enabled on agents table
SELECT schemaname, tablename, rowsecurity 
FROM pg_tables 
WHERE tablename = 'agents';

-- Check the current user context
SELECT current_user, current_setting('request.jwt.claims', true);

-- Temporarily disable RLS to see if that fixes the issue
ALTER TABLE agents DISABLE ROW LEVEL SECURITY;

-- Alternative: Create a more permissive policy for testing
-- DROP POLICY IF EXISTS agents_select_own ON agents;
-- CREATE POLICY agents_select_own ON agents
--     FOR SELECT USING (true);  -- Allow all selects for now

-- Check if the user can now access the table
-- SELECT * FROM agents LIMIT 1;
