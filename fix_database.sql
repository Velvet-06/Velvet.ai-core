-- Fix missing is_llm_message column in messages table
-- Run this in your database to resolve the schema mismatch

-- Add the missing column
ALTER TABLE messages ADD COLUMN IF NOT EXISTS is_llm_message BOOLEAN DEFAULT FALSE;

-- Update existing records to have a default value
UPDATE messages SET is_llm_message = FALSE WHERE is_llm_message IS NULL;

-- Make the column NOT NULL after setting default values
ALTER TABLE messages ALTER COLUMN is_llm_message SET NOT NULL;

-- Verify the column was added
SELECT column_name, data_type, is_nullable 
FROM information_schema.columns 
WHERE table_name = 'messages' AND column_name = 'is_llm_message';
