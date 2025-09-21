# Worker Service Deployment Guide

## Problem
Your Velvet.ai application is showing "System Under Maintenance" because the worker service is not running. The worker service is responsible for processing background agent executions.

## Solution
Deploy a Redis-based worker service to Render. We've simplified the setup by removing the dependency on RabbitMQ and using Redis for both caching and message queuing.

## Files Created/Modified

### New Files:
1. `backend/run_agent_background_redis.py` - Redis-based worker implementation
2. `backend/worker_health_redis.py` - Health check for Redis-based worker
3. `backend/Dockerfile.worker` - Docker configuration for worker service
4. `render.yaml` - Render deployment configuration

### Modified Files:
1. `backend/agent/api.py` - Updated to use Redis-based worker
2. `backend/agent/workflows.py` - Updated to use Redis-based worker  
3. `backend/triggers/integration.py` - Updated to use Redis-based worker

## Deployment Steps

### Option 1: Deploy via Render Dashboard (Recommended)

1. **Go to your Render Dashboard**
   - Navigate to your Velvet project
   - Click "New +" → "Background Worker"

2. **Configure the Worker Service:**
   - **Name**: `velvet-worker`
   - **Environment**: `Docker`
   - **Dockerfile Path**: `./backend/Dockerfile.worker`
   - **Docker Context**: `./backend`
   - **Plan**: `Free`
   - **Region**: `Oregon` (same as your other services)

3. **Set Environment Variables:**
   - `ENV_MODE` = `production`
   - `REDIS_HOST` = (from your existing Redis service)
   - `REDIS_PORT` = (from your existing Redis service)
   - `REDIS_PASSWORD` = (from your existing Redis service)
   - Copy all other environment variables from your main API service

4. **Deploy the Worker**
   - Click "Create Background Worker"
   - Wait for deployment to complete

### Option 2: Deploy via Blueprint (Alternative)

1. **Connect your GitHub repository to Render**
2. **Create a new Blueprint**
3. **Use the provided `render.yaml` file**
4. **Deploy the Blueprint**

## Verification

After deployment:

1. **Check Worker Status:**
   - Go to your Render dashboard
   - Verify the `velvet-worker` service is running
   - Check the logs for any errors

2. **Test the Application:**
   - Visit your website
   - The "System Under Maintenance" message should be gone
   - Try creating a new agent execution

3. **Monitor Logs:**
   - Check both API and Worker logs
   - Look for successful agent executions

## Troubleshooting

### Common Issues:

1. **Worker not starting:**
   - Check environment variables are correctly set
   - Verify Redis connection details
   - Check Docker build logs

2. **Agent executions still not working:**
   - Verify worker service is running
   - Check Redis connectivity
   - Review worker logs for errors

3. **Environment variable issues:**
   - Ensure all required environment variables are set
   - Copy variables from your working API service
   - Check for typos in variable names

### Logs to Check:
- Worker service logs in Render dashboard
- API service logs for any enqueue errors
- Redis service logs for connectivity issues

## Architecture

```
Frontend (Vercel) → API Service (Render) → Redis → Worker Service (Render)
                                      ↓
                              Agent Executions
```

The worker service now uses Redis for both:
- Message queuing (instead of RabbitMQ)
- Caching and state management

This simplifies the deployment and reduces the number of services needed.
