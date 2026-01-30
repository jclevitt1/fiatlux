"""
DynamoDB stores for AWS Lambda environment.

Includes:
- DynamoDBJobStore: Job status tracking (with user_id GSI)
- ProjectStore: Project metadata (user_id as partition key)
"""

import os
import uuid
import boto3
from datetime import datetime
from typing import Optional, List, Dict, Any
from decimal import Decimal

from models.job import Job, JobStatus, JobType


# =============================================================================
# Job Store
# =============================================================================

class DynamoDBJobStore:
    """
    Persistent job store using DynamoDB.

    Table schema:
        - job_id (PK): string
        - user_id: string (for GSI)
        - job_type: string
        - status: string
        - raw_file_path: string
        - additional_text: string
        - project_id: string (optional)
        - output_path: string (optional)
        - result: map (optional)
        - error: string (optional)
        - created_at: string (ISO)
        - started_at: string (ISO, optional)
        - completed_at: string (ISO, optional)
        - ttl: number (epoch seconds for auto-expiration)

    GSI: user-jobs-index (user_id HASH, created_at RANGE)
    """

    def __init__(self, table_name: Optional[str] = None, region: str = "us-west-1"):
        self.table_name = table_name or os.environ.get("JOBS_TABLE", "fiatlux-jobs")
        self.region = region or os.environ.get("AWS_DEFAULT_REGION", "us-west-1")
        self._dynamodb = boto3.resource('dynamodb', region_name=region)
        self._table = self._dynamodb.Table(self.table_name)

    def create_job(self, job: Job, user_id: str, ttl_days: int = 7) -> Job:
        """Create a new job in DynamoDB."""
        ttl = int(datetime.utcnow().timestamp()) + (ttl_days * 24 * 60 * 60)

        item = {
            'job_id': job.id,
            'user_id': user_id,
            'job_type': job.job_type.value,
            'status': job.status.value,
            'raw_file_path': job.raw_file_path,
            'additional_text': job.additional_text or '',
            'created_at': job.created_at.isoformat(),
            'ttl': ttl
        }

        if job.project_id:
            item['project_id'] = job.project_id

        if job.project_name:
            item['project_name'] = job.project_name

        self._table.put_item(Item=item)
        return job

    def get_job(self, job_id: str) -> Optional[Job]:
        """Get a job by ID."""
        response = self._table.get_item(Key={'job_id': job_id})
        item = response.get('Item')

        if not item:
            return None

        return self._item_to_job(item)

    def get_job_with_user(self, job_id: str) -> Optional[tuple]:
        """Get a job by ID along with its user_id."""
        response = self._table.get_item(Key={'job_id': job_id})
        item = response.get('Item')

        if not item:
            return None

        return self._item_to_job(item), item.get('user_id')

    def update_job(self, job: Job) -> Job:
        """Update an existing job."""
        update_expr = "SET #status = :status"
        expr_values = {':status': job.status.value}
        expr_names = {'#status': 'status'}

        if job.started_at:
            update_expr += ", started_at = :started_at"
            expr_values[':started_at'] = job.started_at.isoformat()

        if job.completed_at:
            update_expr += ", completed_at = :completed_at"
            expr_values[':completed_at'] = job.completed_at.isoformat()

        if job.output_path:
            update_expr += ", output_path = :output_path"
            expr_values[':output_path'] = job.output_path

        if job.result:
            update_expr += ", #result = :result"
            expr_values[':result'] = job.result
            expr_names['#result'] = 'result'

        if job.error:
            update_expr += ", #error = :error"
            expr_values[':error'] = job.error
            expr_names['#error'] = 'error'

        self._table.update_item(
            Key={'job_id': job.id},
            UpdateExpression=update_expr,
            ExpressionAttributeValues=expr_values,
            ExpressionAttributeNames=expr_names
        )

        return job

    def list_jobs(self, limit: int = 50) -> List[Job]:
        """List recent jobs (scan - use list_user_jobs for production)."""
        response = self._table.scan(Limit=limit)
        items = response.get('Items', [])

        jobs = [self._item_to_job(item) for item in items]
        jobs.sort(key=lambda j: j.created_at, reverse=True)

        return jobs

    def list_user_jobs(self, user_id: str, limit: int = 50) -> List[Job]:
        """List jobs for a specific user using GSI."""
        response = self._table.query(
            IndexName='user-jobs-index',
            KeyConditionExpression='user_id = :uid',
            ExpressionAttributeValues={':uid': user_id},
            Limit=limit,
            ScanIndexForward=False  # Most recent first
        )
        items = response.get('Items', [])
        return [self._item_to_job(item) for item in items]

    def _item_to_job(self, item: dict) -> Job:
        """Convert DynamoDB item to Job object."""
        return Job(
            id=item['job_id'],
            job_type=JobType(item['job_type']),
            status=JobStatus(item['status']),
            raw_file_path=item.get('raw_file_path', ''),
            additional_text=item.get('additional_text', ''),
            project_id=item.get('project_id'),
            project_name=item.get('project_name'),
            output_path=item.get('output_path'),
            result=item.get('result', {}),
            error=item.get('error'),
            created_at=datetime.fromisoformat(item['created_at']),
            started_at=datetime.fromisoformat(item['started_at']) if item.get('started_at') else None,
            completed_at=datetime.fromisoformat(item['completed_at']) if item.get('completed_at') else None
        )


# =============================================================================
# Project Store
# =============================================================================

class ProjectStore:
    """
    DynamoDB store for project metadata.

    Table schema (composite key):
        - user_id (PK): string (Clerk user ID - partition key)
        - project_id (SK): string (sort key)
        - name: string
        - description: string
        - s3_uri: string (full S3 path: s3://bucket/projects/{user_id}/{project_id}/)
        - source_job_id: string (optional - job that created this project)
        - file_count: number
        - total_size_bytes: number
        - language: string (primary language: python, java, swift, etc.)
        - framework: string (optional: fastapi, spring, swiftui, etc.)
        - created_at: string (ISO)
        - updated_at: string (ISO)
        - last_accessed_at: string (ISO)
        - metadata: map (additional project info)

    GSIs:
        - project-lookup-index: project_id HASH (for direct project lookup)
        - user-recent-index: user_id HASH, updated_at RANGE (for recent projects)
    """

    def __init__(self, table_name: Optional[str] = None, region: str = "us-west-1"):
        self.table_name = table_name or os.environ.get("PROJECTS_TABLE", "fiatlux-projects")
        self.region = region or os.environ.get("AWS_DEFAULT_REGION", "us-west-1")
        self.bucket = os.environ.get("S3_BUCKET", "fiatlux-storage")
        self._dynamodb = boto3.resource('dynamodb', region_name=region)
        self._table = self._dynamodb.Table(self.table_name)

    def create_project(
        self,
        user_id: str,
        name: str,
        description: str = "",
        language: str = "",
        framework: str = "",
        source_job_id: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None
    ) -> Dict[str, Any]:
        """Create a new project for a user."""
        project_id = str(uuid.uuid4())
        now = datetime.utcnow().isoformat()

        # S3 path: {user_id}/project_files/{project_id}/
        s3_uri = f"s3://{self.bucket}/{user_id}/project_files/{project_id}/"

        item = {
            'user_id': user_id,
            'project_id': project_id,
            'name': name,
            'description': description,
            's3_uri': s3_uri,
            's3_prefix': f"{user_id}/project_files/{project_id}/",
            'language': language,
            'framework': framework,
            'file_count': 0,
            'total_size_bytes': 0,
            'created_at': now,
            'updated_at': now,
            'last_accessed_at': now,
            'metadata': metadata or {}
        }

        if source_job_id:
            item['source_job_id'] = source_job_id

        self._table.put_item(Item=item)
        return item

    def get_project(self, user_id: str, project_id: str) -> Optional[Dict[str, Any]]:
        """Get a project by user_id and project_id (composite key)."""
        response = self._table.get_item(
            Key={
                'user_id': user_id,
                'project_id': project_id
            }
        )
        return response.get('Item')

    def get_project_by_id(self, project_id: str) -> Optional[Dict[str, Any]]:
        """Get a project by project_id only (uses GSI)."""
        response = self._table.query(
            IndexName='project-lookup-index',
            KeyConditionExpression='project_id = :pid',
            ExpressionAttributeValues={':pid': project_id}
        )
        items = response.get('Items', [])
        return items[0] if items else None

    def list_user_projects(self, user_id: str, limit: int = 50) -> List[Dict[str, Any]]:
        """List all projects for a user, most recently updated first."""
        response = self._table.query(
            IndexName='user-recent-index',
            KeyConditionExpression='user_id = :uid',
            ExpressionAttributeValues={':uid': user_id},
            Limit=limit,
            ScanIndexForward=False  # Most recent first
        )
        return response.get('Items', [])

    def update_project(
        self,
        user_id: str,
        project_id: str,
        updates: Dict[str, Any]
    ) -> Optional[Dict[str, Any]]:
        """Update project fields."""
        # Always update updated_at
        updates['updated_at'] = datetime.utcnow().isoformat()

        # Build update expression
        update_parts = []
        expr_names = {}
        expr_values = {}

        for key, value in updates.items():
            safe_key = key.replace('-', '_')
            update_parts.append(f"#{safe_key} = :{safe_key}")
            expr_names[f"#{safe_key}"] = key
            expr_values[f":{safe_key}"] = value

        update_expr = "SET " + ", ".join(update_parts)

        response = self._table.update_item(
            Key={
                'user_id': user_id,
                'project_id': project_id
            },
            UpdateExpression=update_expr,
            ExpressionAttributeNames=expr_names,
            ExpressionAttributeValues=expr_values,
            ReturnValues='ALL_NEW'
        )
        return response.get('Attributes')

    def update_project_stats(
        self,
        user_id: str,
        project_id: str,
        file_count: int,
        total_size_bytes: int
    ) -> Optional[Dict[str, Any]]:
        """Update project file statistics."""
        return self.update_project(user_id, project_id, {
            'file_count': file_count,
            'total_size_bytes': total_size_bytes
        })

    def touch_project(self, user_id: str, project_id: str) -> Optional[Dict[str, Any]]:
        """Update last_accessed_at timestamp."""
        now = datetime.utcnow().isoformat()
        return self.update_project(user_id, project_id, {
            'last_accessed_at': now
        })

    def delete_project(self, user_id: str, project_id: str) -> bool:
        """Delete a project (metadata only - S3 files handled separately)."""
        self._table.delete_item(
            Key={
                'user_id': user_id,
                'project_id': project_id
            }
        )
        return True

    def search_projects(
        self,
        user_id: str,
        query: str,
        limit: int = 20
    ) -> List[Dict[str, Any]]:
        """Search projects by name (simple contains search)."""
        # Get all user projects and filter client-side
        # For production, consider using OpenSearch or DynamoDB Streams + search
        projects = self.list_user_projects(user_id, limit=100)
        query_lower = query.lower()

        matching = [
            p for p in projects
            if query_lower in p.get('name', '').lower()
            or query_lower in p.get('description', '').lower()
        ]

        return matching[:limit]
