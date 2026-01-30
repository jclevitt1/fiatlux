"""
AWS Lambda handler for FiatLux API endpoints.

Handles:
- POST /upload - Upload PDF to S3 raw/
- GET /jobs/{job_id} - Get job status
- GET /jobs - List user's jobs
- POST /jobs - Submit a new job (triggers processor)
- GET /projects - List user's projects
- GET /projects/{project_id} - Get project details
- POST /projects - Create a new project
- PUT /projects/{project_id} - Update a project
- DELETE /projects/{project_id} - Delete a project
- GET /projects/{project_id}/files - List project files
- GET /health - Health check

All endpoints except /health require authentication via Clerk JWT.
"""

import os
import sys
import json
import uuid
import base64
from datetime import datetime
from typing import Optional, Tuple

# Add parent directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import boto3
import jwt
from jwt import PyJWKClient

from models.job import Job, JobStatus, JobType
from storage.dynamodb import DynamoDBJobStore, ProjectStore
from storage.s3 import S3Storage

# Environment variables
S3_BUCKET = os.environ.get("S3_BUCKET", "fiatlux-storage")
JOBS_TABLE = os.environ.get("JOBS_TABLE", "fiatlux-jobs")
PROJECTS_TABLE = os.environ.get("PROJECTS_TABLE", "fiatlux-projects")
# Lambda sets AWS_DEFAULT_REGION automatically (not AWS_REGION which is reserved)
AWS_REGION = os.environ.get("AWS_DEFAULT_REGION", os.environ.get("AWS_REGION", "us-west-1"))
CLERK_SECRET_KEY = os.environ.get("CLERK_SECRET_KEY", "")
CLERK_PUBLISHABLE_KEY = os.environ.get("CLERK_PUBLISHABLE_KEY", "")

# Extract Clerk frontend API from publishable key for JWKS URL
def get_clerk_jwks_url() -> str:
    """Extract JWKS URL from Clerk publishable key."""
    if CLERK_PUBLISHABLE_KEY.startswith("pk_test_") or CLERK_PUBLISHABLE_KEY.startswith("pk_live_"):
        # Decode the base64 part after pk_test_ or pk_live_
        encoded = CLERK_PUBLISHABLE_KEY.split("_", 2)[2]
        try:
            # Add padding if needed
            padding = 4 - len(encoded) % 4
            if padding != 4:
                encoded += "=" * padding
            decoded = base64.b64decode(encoded).decode('utf-8')
            # decoded is like "quick-tortoise-33.clerk.accounts.dev$"
            frontend_api = decoded.rstrip('$')
            return f"https://{frontend_api}/.well-known/jwks.json"
        except Exception as e:
            print(f"Failed to decode publishable key: {e}")
    return ""

CLERK_JWKS_URL = get_clerk_jwks_url()

# Log configuration on cold start
print(f"[Init] CLERK_PUBLISHABLE_KEY set: {bool(CLERK_PUBLISHABLE_KEY)}")
print(f"[Init] CLERK_JWKS_URL: {CLERK_JWKS_URL}")

# Initialize JWKS client for JWT verification (lazy loaded)
_jwks_client: Optional[PyJWKClient] = None

def get_jwks_client() -> Optional[PyJWKClient]:
    """Get or create JWKS client."""
    global _jwks_client
    if _jwks_client is None and CLERK_JWKS_URL:
        _jwks_client = PyJWKClient(CLERK_JWKS_URL)
    return _jwks_client

# Initialize services
job_store = DynamoDBJobStore(table_name=JOBS_TABLE, region=AWS_REGION)
project_store = ProjectStore(table_name=PROJECTS_TABLE, region=AWS_REGION)
storage = S3Storage(bucket_name=S3_BUCKET)


# =============================================================================
# Authentication
# =============================================================================

def verify_jwt(token: str) -> Tuple[bool, Optional[dict], Optional[str]]:
    """
    Verify a Clerk JWT token.

    Returns:
        Tuple of (is_valid, claims_dict, error_message)
    """
    if not token:
        print("[Auth] No token provided")
        return False, None, "No token provided"

    # Remove "Bearer " prefix if present
    if token.startswith("Bearer "):
        token = token[7:]

    jwks_client = get_jwks_client()
    if not jwks_client:
        # If no JWKS URL configured, allow requests in development
        if not CLERK_PUBLISHABLE_KEY:
            print("[Auth] Warning: No Clerk keys configured, skipping auth")
            return True, {"sub": "dev-user"}, None
        print(f"[Auth] JWKS client not configured. CLERK_PUBLISHABLE_KEY set: {bool(CLERK_PUBLISHABLE_KEY)}, JWKS_URL: {CLERK_JWKS_URL}")
        return False, None, "JWKS client not configured"

    try:
        # Get the signing key from JWKS
        signing_key = jwks_client.get_signing_key_from_jwt(token)

        # Verify and decode the token
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            options={"verify_aud": False}  # Clerk doesn't always set audience
        )

        print(f"[Auth] JWT verified successfully for user: {claims.get('sub')}")
        return True, claims, None

    except jwt.ExpiredSignatureError:
        print("[Auth] Token expired")
        return False, None, "Token expired"
    except jwt.InvalidTokenError as e:
        print(f"[Auth] Invalid token: {str(e)}")
        return False, None, f"Invalid token: {str(e)}"
    except Exception as e:
        print(f"[Auth] Token verification failed: {str(e)}")
        return False, None, f"Token verification failed: {str(e)}"


def get_user_id_from_event(event: dict) -> Tuple[Optional[str], Optional[dict]]:
    """
    Extract and verify user ID from request headers.

    Returns:
        Tuple of (user_id, error_response)
        If authentication fails, user_id is None and error_response contains the error.
    """
    # Get Authorization header
    headers = event.get('headers', {}) or {}

    # Headers might be lowercase in API Gateway v2
    auth_header = headers.get('authorization') or headers.get('Authorization', '')

    if not auth_header:
        print("[Auth] Missing Authorization header")
        return None, response(401, {'error': 'Missing Authorization header'})

    is_valid, claims, error = verify_jwt(auth_header)

    if not is_valid:
        print(f"[Auth] Authentication failed: {error}")
        return None, response(401, {'error': error or 'Authentication failed'})

    # Extract user ID from claims
    # Clerk uses 'sub' for user ID
    user_id = claims.get('sub')
    if not user_id:
        print("[Auth] No user ID in token claims")
        return None, response(401, {'error': 'No user ID in token'})

    return user_id, None


def lambda_handler(event, context):
    """Main Lambda handler - routes requests to appropriate functions."""
    # Log event without sensitive data
    safe_event = {k: v for k, v in event.items() if k != 'body'}
    safe_event['body'] = '[REDACTED]' if event.get('body') else None
    print(f"Event: {json.dumps(safe_event)}")

    # Handle API Gateway v2 (HTTP API) format
    if 'routeKey' in event:
        route_key = event['routeKey']
        path_params = event.get('pathParameters', {}) or {}
        query_params = event.get('queryStringParameters', {}) or {}
        body = event.get('body', '')

        if body and event.get('isBase64Encoded'):
            body = base64.b64decode(body).decode('utf-8')

        try:
            body_json = json.loads(body) if body else {}
        except json.JSONDecodeError:
            body_json = {}

        # Public routes (no auth required)
        if route_key == 'GET /health':
            return handle_health()
        elif route_key == 'POST /auth/signin':
            return handle_signin(body_json)
        elif route_key == 'POST /auth/refresh':
            return handle_refresh(body_json)

        # Protected routes - require authentication
        user_id, auth_error = get_user_id_from_event(event)
        if auth_error:
            return auth_error

        # Route to handlers with user_id
        if route_key == 'POST /upload':
            return handle_upload(body_json, user_id)
        elif route_key == 'POST /jobs':
            return handle_submit_job(body_json, user_id)
        elif route_key == 'GET /jobs/{job_id}':
            return handle_get_job(path_params.get('job_id'), user_id)
        elif route_key == 'GET /jobs':
            return handle_list_jobs(user_id)
        elif route_key == 'POST /execute':
            return handle_execute(body_json, user_id)
        # Project routes
        elif route_key == 'GET /projects':
            return handle_list_projects(query_params.get('search'), user_id)
        elif route_key == 'GET /projects/{project_id}':
            return handle_get_project(path_params.get('project_id'), user_id)
        elif route_key == 'POST /projects':
            return handle_create_project(body_json, user_id)
        elif route_key == 'PUT /projects/{project_id}':
            return handle_update_project(path_params.get('project_id'), body_json, user_id)
        elif route_key == 'DELETE /projects/{project_id}':
            return handle_delete_project(path_params.get('project_id'), user_id)
        elif route_key == 'GET /projects/{project_id}/files':
            return handle_project_files(path_params.get('project_id'), user_id)
        else:
            return response(404, {'error': f'Route not found: {route_key}'})

    # Handle API Gateway v1 (REST API) format
    http_method = event.get('httpMethod', '')
    path = event.get('path', '')
    path_params = event.get('pathParameters', {}) or {}
    query_params = event.get('queryStringParameters', {}) or {}
    body = event.get('body', '')

    if body and event.get('isBase64Encoded'):
        body = base64.b64decode(body).decode('utf-8')

    try:
        body_json = json.loads(body) if body else {}
    except json.JSONDecodeError:
        body_json = {}

    # Public routes (no auth required)
    if path == '/health' and http_method == 'GET':
        return handle_health()
    elif path == '/auth/signin' and http_method == 'POST':
        return handle_signin(body_json)
    elif path == '/auth/refresh' and http_method == 'POST':
        return handle_refresh(body_json)

    # Protected routes - require authentication
    user_id, auth_error = get_user_id_from_event(event)
    if auth_error:
        return auth_error

    # Route to handlers with user_id
    if path == '/upload' and http_method == 'POST':
        return handle_upload(body_json, user_id)
    elif path == '/jobs' and http_method == 'POST':
        return handle_submit_job(body_json, user_id)
    elif path.startswith('/jobs/') and http_method == 'GET':
        job_id = path.split('/')[-1]
        return handle_get_job(job_id, user_id)
    elif path == '/jobs' and http_method == 'GET':
        return handle_list_jobs(user_id)
    elif path == '/execute' and http_method == 'POST':
        return handle_execute(body_json, user_id)
    elif path == '/projects' and http_method == 'GET':
        return handle_list_projects(query_params.get('search'), user_id)
    elif path == '/projects' and http_method == 'POST':
        return handle_create_project(body_json, user_id)
    elif '/projects/' in path and '/files' in path and http_method == 'GET':
        project_id = path.split('/projects/')[1].split('/files')[0]
        return handle_project_files(project_id, user_id)
    elif path.startswith('/projects/') and http_method == 'GET':
        project_id = path.split('/')[-1]
        return handle_get_project(project_id, user_id)
    elif path.startswith('/projects/') and http_method == 'PUT':
        project_id = path.split('/')[-1]
        return handle_update_project(project_id, body_json, user_id)
    elif path.startswith('/projects/') and http_method == 'DELETE':
        project_id = path.split('/')[-1]
        return handle_delete_project(project_id, user_id)
    else:
        return response(404, {'error': f'Route not found: {http_method} {path}'})


def response(status_code: int, body: dict, headers: dict = None):
    """Build API Gateway response."""
    default_headers = {
        'Content-Type': 'application/json',
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Content-Type,X-Api-Key,Authorization',
        'Access-Control-Allow-Methods': 'GET,POST,PUT,DELETE,OPTIONS'
    }
    if headers:
        default_headers.update(headers)

    return {
        'statusCode': status_code,
        'headers': default_headers,
        'body': json.dumps(body)
    }


def handle_health():
    """Health check endpoint."""
    return response(200, {
        'status': 'healthy',
        'storage': 's3',
        'bucket': S3_BUCKET,
        'region': AWS_REGION
    })


def handle_signin(body: dict):
    """
    Sign in with email/password via Clerk Backend API.
    This bypasses the dev_browser_unauthenticated issue for native apps.
    """
    import urllib.request
    import urllib.error
    import urllib.parse

    email = body.get('email')
    password = body.get('password')

    if not email or not password:
        return response(400, {'error': 'email and password required'})

    if not CLERK_SECRET_KEY:
        return response(500, {'error': 'Clerk not configured'})

    print(f"[Auth] Signing in user: {email}")

    try:
        # Step 1: Find or create the user by email
        # First, search for existing user
        encoded_email = urllib.parse.quote(email, safe='')
        search_url = f"https://api.clerk.com/v1/users?email_address={encoded_email}"
        search_req = urllib.request.Request(search_url)
        search_req.add_header("Authorization", f"Bearer {CLERK_SECRET_KEY}")
        search_req.add_header("Content-Type", "application/json")
        search_req.add_header("User-Agent", "FiatLux/1.0")

        try:
            with urllib.request.urlopen(search_req) as resp:
                users = json.loads(resp.read().decode())
                print(f"[Auth] Found {len(users)} users matching email")
        except urllib.error.HTTPError as e:
            error_body = e.read().decode() if e.fp else str(e)
            print(f"[Auth] User search failed: {e.code} - {error_body}")
            return response(401, {'error': 'Invalid credentials'})

        if not users:
            return response(401, {'error': 'User not found'})

        user = users[0]
        user_id = user.get('id')

        # Step 2: Verify password using Clerk's verify_password endpoint
        verify_url = f"https://api.clerk.com/v1/users/{user_id}/verify_password"
        verify_data = json.dumps({"password": password}).encode('utf-8')
        verify_req = urllib.request.Request(verify_url, data=verify_data, method='POST')
        verify_req.add_header("Authorization", f"Bearer {CLERK_SECRET_KEY}")
        verify_req.add_header("Content-Type", "application/json")
        verify_req.add_header("User-Agent", "FiatLux/1.0")

        try:
            with urllib.request.urlopen(verify_req) as resp:
                verify_result = json.loads(resp.read().decode())
                print(f"[Auth] Password verification result: {verify_result}")
                if not verify_result.get('verified'):
                    return response(401, {'error': 'Invalid password'})
        except urllib.error.HTTPError as e:
            error_body = e.read().decode() if e.fp else str(e)
            print(f"[Auth] Password verification failed: {e.code} - {error_body}")
            return response(401, {'error': 'Invalid credentials'})

        # Step 3: Create a session token for the user
        # Use Clerk's create session endpoint
        session_url = "https://api.clerk.com/v1/sessions"
        session_data = json.dumps({"user_id": user_id}).encode('utf-8')
        session_req = urllib.request.Request(session_url, data=session_data, method='POST')
        session_req.add_header("Authorization", f"Bearer {CLERK_SECRET_KEY}")
        session_req.add_header("Content-Type", "application/json")
        session_req.add_header("User-Agent", "FiatLux/1.0")

        try:
            with urllib.request.urlopen(session_req) as resp:
                session = json.loads(resp.read().decode())
                print(f"[Auth] Session created: {session.get('id')}")
        except urllib.error.HTTPError as e:
            error_body = e.read().decode() if e.fp else str(e)
            print(f"[Auth] Session creation failed: {e.code} - {error_body}")
            return response(500, {'error': 'Failed to create session'})

        # Step 4: Get a JWT token for the session
        session_id = session.get('id')
        token_url = f"https://api.clerk.com/v1/sessions/{session_id}/tokens"
        token_req = urllib.request.Request(token_url, method='POST')
        token_req.add_header("Authorization", f"Bearer {CLERK_SECRET_KEY}")
        token_req.add_header("Content-Type", "application/json")
        token_req.add_header("User-Agent", "FiatLux/1.0")

        try:
            with urllib.request.urlopen(token_req) as resp:
                token_result = json.loads(resp.read().decode())
                jwt = token_result.get('jwt')
                print(f"[Auth] JWT token created")
        except urllib.error.HTTPError as e:
            error_body = e.read().decode() if e.fp else str(e)
            print(f"[Auth] Token creation failed: {e.code} - {error_body}")
            return response(500, {'error': 'Failed to create token'})

        # Return user info, token, and session_id for refresh
        return response(200, {
            'user': {
                'id': user_id,
                'email': email,
                'first_name': user.get('first_name'),
                'last_name': user.get('last_name'),
                'image_url': user.get('image_url')
            },
            'token': jwt,
            'session_id': session_id
        })

    except Exception as e:
        print(f"[Auth] Unexpected error: {e}")
        return response(500, {'error': str(e)})


def handle_refresh(body: dict):
    """
    Refresh a JWT token using an existing Clerk session.
    """
    import urllib.request
    import urllib.error

    session_id = body.get('session_id')
    if not session_id:
        return response(400, {'error': 'session_id required'})

    if not CLERK_SECRET_KEY:
        return response(500, {'error': 'Clerk not configured'})

    print(f"[Auth] Refreshing token for session: {session_id}")

    try:
        # Get a new JWT token for the session
        token_url = f"https://api.clerk.com/v1/sessions/{session_id}/tokens"
        token_req = urllib.request.Request(token_url, method='POST')
        token_req.add_header("Authorization", f"Bearer {CLERK_SECRET_KEY}")
        token_req.add_header("Content-Type", "application/json")
        token_req.add_header("User-Agent", "FiatLux/1.0")

        with urllib.request.urlopen(token_req) as resp:
            token_result = json.loads(resp.read().decode())
            jwt_token = token_result.get('jwt')
            print(f"[Auth] Token refreshed successfully")

        return response(200, {
            'token': jwt_token,
            'session_id': session_id
        })

    except urllib.error.HTTPError as e:
        error_body = e.read().decode() if e.fp else str(e)
        print(f"[Auth] Token refresh failed: {e.code} - {error_body}")
        # Session may have been revoked or expired
        if e.code == 404:
            return response(401, {'error': 'Session expired, please sign in again'})
        return response(401, {'error': 'Token refresh failed'})

    except Exception as e:
        print(f"[Auth] Refresh error: {e}")
        return response(500, {'error': str(e)})


def handle_upload(body: dict, user_id: str):
    """Upload a PDF to project_notes/ folder in S3, scoped to user."""
    filename = body.get('filename') or body.get('path', '').split('/')[-1]  # Support both
    content_base64 = body.get('content_base64')
    mime_type = body.get('mime_type', 'application/pdf')

    if not filename:
        return response(400, {'detail': 'filename is required'})
    if not content_base64:
        return response(400, {'detail': 'content_base64 is required'})
    if not filename.lower().endswith('.pdf'):
        return response(400, {'detail': 'Only PDF files are allowed'})

    # Sanitize filename (replace spaces with underscores)
    safe_filename = filename.replace(' ', '_')

    try:
        content = base64.b64decode(content_base64)
    except Exception as e:
        return response(400, {'detail': f'Invalid base64 content: {e}'})

    # New structure: {user_id}/project_notes/{filename}.pdf
    full_path = f"{user_id}/project_notes/{safe_filename}"

    try:
        import asyncio
        loop = asyncio.new_event_loop()
        result = loop.run_until_complete(storage.write_file(full_path, content, mime_type))
        loop.close()

        return response(200, {
            'success': True,
            'file_id': result.id if hasattr(result, 'id') else full_path,
            'path': full_path,
            'size': len(content),
            'user_id': user_id
        })
    except Exception as e:
        return response(500, {'detail': f'Upload failed: {e}'})


def handle_submit_job(body: dict, user_id: str):
    """Submit a new processing job for a user."""
    job_type_str = body.get('job_type')
    file_path = body.get('raw_file_path') or body.get('file_path')
    additional_text = body.get('additional_text', '')
    project_id = body.get('project_id')

    # Validate job type
    try:
        job_type = JobType(job_type_str)
    except (ValueError, TypeError):
        return response(400, {
            'detail': f'Invalid job_type. Must be one of: {[t.value for t in JobType]}'
        })

    # Validate file_path
    if not file_path:
        return response(400, {'detail': 'file_path (or raw_file_path) is required'})

    # Normalize path to new structure
    if file_path.startswith('raw/'):
        # Legacy path - convert to new structure
        parts = file_path.split('/')
        if len(parts) >= 3:
            filename = parts[-1]
            file_path = f"{user_id}/project_notes/{filename}"
    elif not '/' in file_path:
        # Just a filename
        file_path = f"{user_id}/project_notes/{file_path}"
    elif not file_path.startswith(f"{user_id}/"):
        # Add user scope if missing
        file_path = f"{user_id}/project_notes/{file_path}"

    # Validate project_id for existing_project
    if job_type == JobType.EXISTING_PROJECT and not project_id:
        return response(400, {'detail': 'project_id is required for existing_project jobs'})

    # Create job
    job = Job(
        id=str(uuid.uuid4()),
        job_type=job_type,
        status=JobStatus.PENDING,
        raw_file_path=file_path,  # Now uses new path structure
        additional_text=additional_text,
        project_id=project_id
    )

    # Save to DynamoDB with user_id
    job_store.create_job(job, user_id=user_id)

    return response(200, {
        'job_id': job.id,
        'status': job.status.value,
        'message': 'Job submitted successfully',
        'user_id': user_id
    })


def handle_execute(body: dict, user_id: str):
    """
    Execute AI processing on a note.

    Simplified endpoint - AI decides what to do based on note content.
    Creates a job with JobType.EXECUTE.
    """
    file_path = body.get('file_path')
    project_name = body.get('project_name')

    if not file_path:
        return response(400, {'detail': 'file_path is required'})
    if not project_name:
        return response(400, {'detail': 'project_name is required'})

    # Sanitize project name (replace spaces with underscores)
    safe_project_name = project_name.replace(' ', '_')

    # Normalize file_path to new structure: {user_id}/project_notes/{filename}
    # Handle legacy 'raw/' paths and new paths
    if file_path.startswith('raw/'):
        # Legacy path: raw/{user_id}/... -> {user_id}/project_notes/...
        parts = file_path.split('/')
        if len(parts) >= 3:
            filename = parts[-1]
            file_path = f"{user_id}/project_notes/{filename}"
    elif not file_path.startswith(f"{user_id}/"):
        # Just a filename - add full path
        file_path = f"{user_id}/project_notes/{file_path}"

    # Create job with EXECUTE type
    job = Job(
        id=str(uuid.uuid4()),
        job_type=JobType.EXECUTE,
        status=JobStatus.PENDING,
        raw_file_path=file_path,
        project_name=safe_project_name
    )

    # Save to DynamoDB with user_id
    job_store.create_job(job, user_id=user_id)

    print(f"[Execute] Created job {job.id} for user {user_id}, project: {safe_project_name}, file: {file_path}")

    return response(200, {
        'job_id': job.id,
        'status': job.status.value,
        'project_name': safe_project_name
    })


def handle_get_job(job_id: str, user_id: str):
    """Get job status by ID for a user."""
    print(f"[GetJob] job_id={job_id}, user_id={user_id}")

    if not job_id:
        return response(400, {'detail': 'job_id is required'})

    result = job_store.get_job_with_user(job_id)
    if not result:
        print(f"[GetJob] Job not found: {job_id}")
        return response(404, {'detail': 'Job not found'})

    job, job_user_id = result
    print(f"[GetJob] Found job, owner={job_user_id}, status={job.status.value}")

    # Verify job belongs to user
    if job_user_id != user_id:
        print(f"[GetJob] Access denied: job owner {job_user_id} != request user {user_id}")
        return response(403, {'detail': 'Access denied'})

    return response(200, {
        'job_id': job.id,
        'job_type': job.job_type.value,
        'status': job.status.value,
        'raw_file_path': job.raw_file_path,
        'output_path': job.output_path,
        'result': job.result,
        'error': job.error,
        'created_at': job.created_at.isoformat(),
        'completed_at': job.completed_at.isoformat() if job.completed_at else None
    })


def handle_list_jobs(user_id: str):
    """List jobs for a user."""
    jobs = job_store.list_user_jobs(user_id)

    return response(200, [
        {
            'job_id': j.id,
            'job_type': j.job_type.value,
            'status': j.status.value,
            'created_at': j.created_at.isoformat()
        }
        for j in jobs
    ])


# =============================================================================
# Project Handlers
# =============================================================================

def handle_list_projects(search: Optional[str], user_id: str):
    """List projects for a user from DynamoDB."""
    try:
        if search:
            projects = project_store.search_projects(user_id, search)
        else:
            projects = project_store.list_user_projects(user_id)

        return response(200, {
            'projects': [
                {
                    'project_id': p['project_id'],
                    'name': p.get('name', ''),
                    'description': p.get('description', ''),
                    'language': p.get('language', ''),
                    'framework': p.get('framework', ''),
                    'file_count': p.get('file_count', 0),
                    'total_size_bytes': p.get('total_size_bytes', 0),
                    's3_uri': p.get('s3_uri', ''),
                    'created_at': p.get('created_at'),
                    'updated_at': p.get('updated_at')
                }
                for p in projects
            ]
        })
    except Exception as e:
        return response(500, {'detail': f'Failed to list projects: {e}'})


def handle_get_project(project_id: str, user_id: str):
    """Get a project by ID."""
    if not project_id:
        return response(400, {'detail': 'project_id is required'})

    try:
        # First try with user_id (direct key lookup)
        project = project_store.get_project(user_id, project_id)

        if not project:
            # Try GSI lookup
            project = project_store.get_project_by_id(project_id)
            if project and project.get('user_id') != user_id:
                return response(403, {'detail': 'Access denied'})

        if not project:
            return response(404, {'detail': 'Project not found'})

        # Touch to update last_accessed_at
        project_store.touch_project(user_id, project_id)

        return response(200, {
            'project_id': project['project_id'],
            'name': project.get('name', ''),
            'description': project.get('description', ''),
            'language': project.get('language', ''),
            'framework': project.get('framework', ''),
            'file_count': project.get('file_count', 0),
            'total_size_bytes': project.get('total_size_bytes', 0),
            's3_uri': project.get('s3_uri', ''),
            's3_prefix': project.get('s3_prefix', ''),
            'source_job_id': project.get('source_job_id'),
            'created_at': project.get('created_at'),
            'updated_at': project.get('updated_at'),
            'last_accessed_at': project.get('last_accessed_at'),
            'metadata': project.get('metadata', {})
        })
    except Exception as e:
        return response(500, {'detail': f'Failed to get project: {e}'})


def handle_create_project(body: dict, user_id: str):
    """Create a new project."""
    name = body.get('name')
    if not name:
        return response(400, {'detail': 'name is required'})

    try:
        project = project_store.create_project(
            user_id=user_id,
            name=name,
            description=body.get('description', ''),
            language=body.get('language', ''),
            framework=body.get('framework', ''),
            source_job_id=body.get('source_job_id'),
            metadata=body.get('metadata')
        )

        return response(201, {
            'project_id': project['project_id'],
            'name': project['name'],
            's3_uri': project['s3_uri'],
            's3_prefix': project['s3_prefix'],
            'created_at': project['created_at']
        })
    except Exception as e:
        return response(500, {'detail': f'Failed to create project: {e}'})


def handle_update_project(project_id: str, body: dict, user_id: str):
    """Update a project."""
    if not project_id:
        return response(400, {'detail': 'project_id is required'})

    # Verify ownership
    existing = project_store.get_project(user_id, project_id)
    if not existing:
        return response(404, {'detail': 'Project not found'})

    # Only allow updating certain fields
    allowed_fields = {'name', 'description', 'language', 'framework', 'metadata'}
    updates = {k: v for k, v in body.items() if k in allowed_fields}

    if not updates:
        return response(400, {'detail': 'No valid fields to update'})

    try:
        updated = project_store.update_project(user_id, project_id, updates)
        return response(200, {
            'project_id': updated['project_id'],
            'name': updated.get('name', ''),
            'description': updated.get('description', ''),
            'updated_at': updated.get('updated_at')
        })
    except Exception as e:
        return response(500, {'detail': f'Failed to update project: {e}'})


def handle_delete_project(project_id: str, user_id: str):
    """Delete a project."""
    if not project_id:
        return response(400, {'detail': 'project_id is required'})

    # Verify ownership
    existing = project_store.get_project(user_id, project_id)
    if not existing:
        return response(404, {'detail': 'Project not found'})

    try:
        # Delete from DynamoDB
        project_store.delete_project(user_id, project_id)

        # Optionally delete S3 files (commented out for safety)
        # s3_prefix = existing.get('s3_prefix')
        # if s3_prefix:
        #     storage.delete_prefix(s3_prefix)

        return response(200, {
            'deleted': True,
            'project_id': project_id
        })
    except Exception as e:
        return response(500, {'detail': f'Failed to delete project: {e}'})


def handle_project_files(project_id: str, user_id: str):
    """List files in a specific project for a user."""
    if not project_id:
        return response(400, {'detail': 'project_id is required'})

    # Verify ownership
    project = project_store.get_project(user_id, project_id)
    if not project:
        return response(404, {'detail': 'Project not found'})

    try:
        import asyncio
        loop = asyncio.new_event_loop()
        # Use the s3_prefix from the project record
        s3_prefix = project.get('s3_prefix', f'projects/{user_id}/{project_id}/')
        files = loop.run_until_complete(storage.list_files(s3_prefix))
        loop.close()

        # Update project stats
        total_size = sum(f.size or 0 for f in files)
        project_store.update_project_stats(user_id, project_id, len(files), total_size)

        return response(200, {
            'project_id': project_id,
            'files': [
                {
                    'id': f.id,
                    'name': f.name,
                    'path': f.path,
                    'mime_type': f.mime_type,
                    'size': f.size
                }
                for f in files
            ]
        })
    except Exception as e:
        return response(500, {'detail': f'Failed to list project files: {e}'})
