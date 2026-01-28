"""
DynamoDB storage for users and projects.

Tables:
    fiatlux-users:
        - PK: user_id (String) - Clerk user ID
        - GSI: email-index (email -> user_id)

    fiatlux-projects:
        - PK: project_id (String) - UUID
        - GSI: user-index (user_id -> projects)
        - GSI: s3-path-index (s3_path -> project)
"""
import os
from datetime import datetime
from typing import Optional

import boto3
from botocore.exceptions import ClientError

from ..models.user import User
from ..models.project import Project, ProjectStatus


class UserStore:
    """DynamoDB operations for the users table."""

    def __init__(self, table_name: str = None):
        self.table_name = table_name or os.environ.get("USERS_TABLE", "fiatlux-users")
        self._dynamodb = boto3.resource("dynamodb")
        self._table = self._dynamodb.Table(self.table_name)

    async def create(self, user: User) -> User:
        """Create a new user."""
        try:
            self._table.put_item(
                Item=user.to_dict(),
                ConditionExpression="attribute_not_exists(user_id)"
            )
            return user
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                raise ValueError(f"User already exists: {user.user_id}")
            raise

    async def get(self, user_id: str) -> Optional[User]:
        """Get a user by ID."""
        response = self._table.get_item(Key={"user_id": user_id})
        item = response.get("Item")
        if item:
            return User.from_dict(item)
        return None

    async def get_by_email(self, email: str) -> Optional[User]:
        """Get a user by email using GSI."""
        response = self._table.query(
            IndexName="email-index",
            KeyConditionExpression="email = :email",
            ExpressionAttributeValues={":email": email}
        )
        items = response.get("Items", [])
        if items:
            return User.from_dict(items[0])
        return None

    async def update(self, user: User) -> User:
        """Update an existing user."""
        user.updated_at = datetime.utcnow()
        self._table.put_item(Item=user.to_dict())
        return user

    async def delete(self, user_id: str) -> bool:
        """Delete a user."""
        self._table.delete_item(Key={"user_id": user_id})
        return True

    async def get_or_create(self, user_id: str, email: str, display_name: str = "") -> tuple[User, bool]:
        """
        Get existing user or create new one.
        Returns (user, created) tuple.
        """
        existing = await self.get(user_id)
        if existing:
            return existing, False

        user = User(
            user_id=user_id,
            email=email,
            display_name=display_name
        )
        await self.create(user)
        return user, True


class ProjectStore:
    """DynamoDB operations for the projects table."""

    def __init__(self, table_name: str = None):
        self.table_name = table_name or os.environ.get("PROJECTS_TABLE", "fiatlux-projects")
        self._dynamodb = boto3.resource("dynamodb")
        self._table = self._dynamodb.Table(self.table_name)

    async def create(self, project: Project) -> Project:
        """Create a new project."""
        try:
            self._table.put_item(
                Item=project.to_dict(),
                ConditionExpression="attribute_not_exists(project_id)"
            )
            return project
        except ClientError as e:
            if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
                raise ValueError(f"Project already exists: {project.project_id}")
            raise

    async def get(self, project_id: str) -> Optional[Project]:
        """Get a project by ID."""
        response = self._table.get_item(Key={"project_id": project_id})
        item = response.get("Item")
        if item:
            return Project.from_dict(item)
        return None

    async def get_by_s3_path(self, s3_path: str) -> Optional[Project]:
        """Get a project by S3 path using GSI."""
        response = self._table.query(
            IndexName="s3-path-index",
            KeyConditionExpression="s3_path = :path",
            ExpressionAttributeValues={":path": s3_path}
        )
        items = response.get("Items", [])
        if items:
            return Project.from_dict(items[0])
        return None

    async def list_by_user(self, user_id: str, limit: int = 100) -> list[Project]:
        """List all projects for a user using GSI."""
        response = self._table.query(
            IndexName="user-index",
            KeyConditionExpression="user_id = :uid",
            ExpressionAttributeValues={":uid": user_id},
            Limit=limit,
            ScanIndexForward=False  # Most recent first (by sort key if defined)
        )
        return [Project.from_dict(item) for item in response.get("Items", [])]

    async def update(self, project: Project) -> Project:
        """Update an existing project."""
        project.updated_at = datetime.utcnow()
        self._table.put_item(Item=project.to_dict())
        return project

    async def update_status(self, project_id: str, status: ProjectStatus) -> Optional[Project]:
        """Update just the status of a project."""
        try:
            response = self._table.update_item(
                Key={"project_id": project_id},
                UpdateExpression="SET #status = :status, updated_at = :updated",
                ExpressionAttributeNames={"#status": "status"},
                ExpressionAttributeValues={
                    ":status": status.value,
                    ":updated": datetime.utcnow().isoformat()
                },
                ReturnValues="ALL_NEW"
            )
            return Project.from_dict(response["Attributes"])
        except ClientError:
            return None

    async def delete(self, project_id: str) -> bool:
        """Delete a project."""
        self._table.delete_item(Key={"project_id": project_id})
        return True


def get_table_definitions() -> list[dict]:
    """
    Return CloudFormation/SAM table definitions.
    Use this to ensure infra matches code expectations.
    """
    return [
        {
            "TableName": "fiatlux-users",
            "KeySchema": [
                {"AttributeName": "user_id", "KeyType": "HASH"}
            ],
            "AttributeDefinitions": [
                {"AttributeName": "user_id", "AttributeType": "S"},
                {"AttributeName": "email", "AttributeType": "S"}
            ],
            "GlobalSecondaryIndexes": [
                {
                    "IndexName": "email-index",
                    "KeySchema": [
                        {"AttributeName": "email", "KeyType": "HASH"}
                    ],
                    "Projection": {"ProjectionType": "ALL"}
                }
            ],
            "BillingMode": "PAY_PER_REQUEST"
        },
        {
            "TableName": "fiatlux-projects",
            "KeySchema": [
                {"AttributeName": "project_id", "KeyType": "HASH"}
            ],
            "AttributeDefinitions": [
                {"AttributeName": "project_id", "AttributeType": "S"},
                {"AttributeName": "user_id", "AttributeType": "S"},
                {"AttributeName": "s3_path", "AttributeType": "S"}
            ],
            "GlobalSecondaryIndexes": [
                {
                    "IndexName": "user-index",
                    "KeySchema": [
                        {"AttributeName": "user_id", "KeyType": "HASH"}
                    ],
                    "Projection": {"ProjectionType": "ALL"}
                },
                {
                    "IndexName": "s3-path-index",
                    "KeySchema": [
                        {"AttributeName": "s3_path", "KeyType": "HASH"}
                    ],
                    "Projection": {"ProjectionType": "ALL"}
                }
            ],
            "BillingMode": "PAY_PER_REQUEST"
        }
    ]
