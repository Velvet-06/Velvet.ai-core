import asyncio
import os
import sys

# Add backend to path
sys.path.append('backend')

async def check_accounts():
    try:
        from services.supabase import get_supabase_client
        
        client = await get_supabase_client()
        
        # Check accounts table
        result = await client.table('accounts').select('*').execute()
        print("Accounts table contents:")
        print(result.data)
        
        # Check if our user ID exists
        user_id = "213d7610-886b-469e-a90a-d4344e5b367a"
        result = await client.table('accounts').select('*').eq('user_id', user_id).execute()
        print(f"\nAccount for user {user_id}:")
        print(result.data)
        
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    asyncio.run(check_accounts())
