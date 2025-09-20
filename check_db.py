#!/usr/bin/env python3
"""
Simple script to check what tables exist in the Supabase database
"""
import os
import asyncio
from supabase import create_client

async def check_database():
    # Get environment variables
    supabase_url = os.getenv('SUPABASE_URL')
    supabase_key = os.getenv('SUPABASE_SERVICE_ROLE_KEY')
    
    if not supabase_url or not supabase_key:
        print("❌ Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY")
        return
    
    print(f"🔗 Connecting to: {supabase_url}")
    
    try:
        # Create client
        client = create_client(supabase_url, supabase_key)
        
        # Check if we can connect
        print("✅ Connected to Supabase")
        
        # Try to list tables in basejump schema
        try:
            result = await client.table('basejump.accounts').select('*').limit(1).execute()
            print("✅ basejump.accounts table exists")
        except Exception as e:
            print(f"❌ basejump.accounts table error: {e}")
        
        # Try to list tables in public schema
        try:
            result = await client.table('public.agents').select('*').limit(1).execute()
            print("✅ public.agents table exists")
        except Exception as e:
            print(f"❌ public.agents table error: {e}")
        
        # Try to list tables in public schema
        try:
            result = await client.table('public.threads').select('*').limit(1).execute()
            print("✅ public.threads table exists")
        except Exception as e:
            print(f"❌ public.threads table error: {e}")
            
    except Exception as e:
        print(f"❌ Connection error: {e}")

if __name__ == "__main__":
    asyncio.run(check_database())
