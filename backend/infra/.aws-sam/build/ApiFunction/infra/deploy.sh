#!/bin/bash
#
# FiatLux Backend Deployment Script
#
# Usage:
#   ./deploy.sh [dev|prod]
#
# Prerequisites:
#   - AWS CLI configured (aws configure)
#   - SAM CLI installed (brew install aws-sam-cli)
#   - Docker running
#   - .env file in backend/ with required keys (or env vars exported)
#

set -e

STAGE=${1:-dev}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_DIR="$(dirname "$SCRIPT_DIR")"

echo "================================================"
echo "FiatLux Backend Deployment"
echo "Stage: $STAGE"
echo "Region: us-west-1"
echo "================================================"

# Load .env file from backend directory if it exists
ENV_FILE="$BACKEND_DIR/.env"
if [ -f "$ENV_FILE" ]; then
    echo "Loading environment from $ENV_FILE"
    set -a  # automatically export all variables
    source "$ENV_FILE"
    set +a
else
    echo "No .env file found at $ENV_FILE, using existing environment variables"
fi

# Check prerequisites
if ! command -v aws &> /dev/null; then
    echo "ERROR: AWS CLI not found. Install with: brew install awscli"
    exit 1
fi

if ! command -v sam &> /dev/null; then
    echo "ERROR: SAM CLI not found. Install with: brew install aws-sam-cli"
    exit 1
fi

if ! docker info &> /dev/null; then
    echo "ERROR: Docker is not running. Please start Docker Desktop."
    exit 1
fi

if [ -z "$ANTHROPIC_API_KEY" ]; then
    echo "ERROR: ANTHROPIC_API_KEY environment variable not set."
    echo "Set it with: export ANTHROPIC_API_KEY=sk-ant-..."
    exit 1
fi

# Support both CLERK_PUBLISHABLE_KEY and NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY (Clerk convention)
if [ -z "$CLERK_PUBLISHABLE_KEY" ]; then
    if [ -n "$NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY" ]; then
        CLERK_PUBLISHABLE_KEY="$NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY"
    else
        echo "ERROR: NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY (or CLERK_PUBLISHABLE_KEY) not set."
        echo "Set it with: export NEXT_PUBLIC_CLERK_PUBLISHABLE_KEY=pk_test_..."
        exit 1
    fi
fi

if [ -z "$CLERK_SECRET_KEY" ]; then
    echo "ERROR: CLERK_SECRET_KEY environment variable not set."
    echo "Set it with: export CLERK_SECRET_KEY=sk_test_..."
    exit 1
fi

# Get AWS account ID
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "AWS Account: $AWS_ACCOUNT_ID"

# Create ECR repository if it doesn't exist
ECR_REPO="fiatlux-processor"
echo ""
echo "Checking ECR repository..."
if ! aws ecr describe-repositories --repository-names $ECR_REPO --region us-west-1 &> /dev/null; then
    echo "Creating ECR repository: $ECR_REPO"
    aws ecr create-repository --repository-name $ECR_REPO --region us-west-1
fi

# Login to ECR
echo ""
echo "Logging into ECR..."
aws ecr get-login-password --region us-west-1 | docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.us-west-1.amazonaws.com

# Build and push processor Docker image
echo ""
echo "Building processor Docker image..."
cd "$BACKEND_DIR"
docker build -t $ECR_REPO:latest -f infra/Dockerfile.processor .

echo "Tagging and pushing to ECR..."
docker tag $ECR_REPO:latest $AWS_ACCOUNT_ID.dkr.ecr.us-west-1.amazonaws.com/$ECR_REPO:latest
docker push $AWS_ACCOUNT_ID.dkr.ecr.us-west-1.amazonaws.com/$ECR_REPO:latest

# Build SAM application
echo ""
echo "Building SAM application..."
cd "$SCRIPT_DIR"
sam build --template-file template.yaml --use-container

# Deploy
echo ""
echo "Deploying to AWS..."
sam deploy \
    --template-file .aws-sam/build/template.yaml \
    --stack-name fiatlux-backend-$STAGE \
    --region us-west-1 \
    --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND \
    --parameter-overrides Stage=$STAGE AnthropicApiKey=$ANTHROPIC_API_KEY ClerkPublishableKey=$CLERK_PUBLISHABLE_KEY ClerkSecretKey=$CLERK_SECRET_KEY \
    --resolve-s3 \
    --resolve-image-repos \
    --no-confirm-changeset \
    --no-fail-on-empty-changeset

# Get outputs
echo ""
echo "================================================"
echo "Deployment Complete!"
echo "================================================"
echo ""

API_URL=$(aws cloudformation describe-stacks \
    --stack-name fiatlux-backend-$STAGE \
    --region us-west-1 \
    --query 'Stacks[0].Outputs[?OutputKey==`ApiUrl`].OutputValue' \
    --output text)

BUCKET=$(aws cloudformation describe-stacks \
    --stack-name fiatlux-backend-$STAGE \
    --region us-west-1 \
    --query 'Stacks[0].Outputs[?OutputKey==`StorageBucketName`].OutputValue' \
    --output text)

echo "API URL: $API_URL"
echo "S3 Bucket: $BUCKET"
echo ""
echo "Test the API:"
echo "  curl $API_URL/health"
echo ""
echo "Update BackendService.swift with:"
echo "  Environment.dev: \"$API_URL\""
