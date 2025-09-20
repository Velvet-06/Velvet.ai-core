-- Minimal migration for Velvet.ai - just the essential tables
-- Run this in Supabase SQL Editor if the full migration didn't work

-- Create basejump schema if it doesn't exist
CREATE SCHEMA IF NOT EXISTS basejump;

-- Create accounts table
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

-- Create projects table
CREATE TABLE IF NOT EXISTS public.projects (
    project_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid REFERENCES basejump.accounts(id) NOT NULL,
    name text NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);

-- Create agents table
CREATE TABLE IF NOT EXISTS public.agents (
    agent_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id uuid REFERENCES basejump.accounts(id) NOT NULL,
    name text NOT NULL,
    description text,
    is_default boolean DEFAULT false,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);

-- Create threads table
CREATE TABLE IF NOT EXISTS public.threads (
    thread_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid REFERENCES public.projects(project_id) NOT NULL,
    created_at timestamp with time zone DEFAULT now(),
    updated_at timestamp with time zone DEFAULT now()
);

-- Create messages table
CREATE TABLE IF NOT EXISTS public.messages (
    message_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    thread_id uuid REFERENCES public.threads(thread_id) NOT NULL,
    content text NOT NULL,
    role text NOT NULL,
    created_at timestamp with time zone DEFAULT now()
);

-- Grant permissions
GRANT USAGE ON SCHEMA basejump TO authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA basejump TO authenticated, service_role;
GRANT ALL ON ALL TABLES IN SCHEMA public TO authenticated, service_role;

-- Enable RLS
ALTER TABLE basejump.accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.agents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.threads ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.messages ENABLE ROW LEVEL SECURITY;

-- Create a personal account for the current user (replace with your user ID)
-- You'll need to get your user ID from Supabase → Authentication → Users
-- Then uncomment and update this line:
-- INSERT INTO basejump.accounts (id, primary_owner_user_id, name, slug, personal_account) 
-- VALUES (gen_random_uuid(), 'YOUR_USER_ID_HERE', 'Personal', 'personal', true);
