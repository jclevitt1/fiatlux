# FiatLux AWS Infrastructure

Serverless backend infrastructure for FiatLux using AWS Lambda, S3, DynamoDB, and API Gateway.

## Architecture

```
Swift App → API Gateway → Lambda (API) → S3 (raw/)
                                            ↓ S3 Event
                                      Lambda (Processor) → Claude API
                                            ↓
                                      S3 (projects/) + DynamoDB (job status)
```

## Components

| Component | AWS Service | Purpose |
|-----------|-------------|---------|
| API | API Gateway HTTP API + Lambda | /upload, /jobs, /projects, /health |
| Processor | Lambda (Docker) | S3-triggered PDF processing with Claude |
| Storage | S3 | raw/, notes/, projects/ folders |
| Job State | DynamoDB | Job status tracking with TTL |

## Prerequisites

1. **AWS CLI** configured with credentials
   ```bash
   brew install awscli
   aws configure
   ```

2. **SAM CLI** installed
   ```bash
   brew install aws-sam-cli
   ```

3. **Docker** running (for processor Lambda build)

4. **Anthropic API key** set as environment variable
   ```bash
   export ANTHROPIC_API_KEY=sk-ant-...
   ```

## Deployment

### Quick Deploy

```bash
cd backend/infra
./deploy.sh dev
```

### Manual Deploy

```bash
# 1. Create ECR repository (first time only)
aws ecr create-repository --repository-name fiatlux-processor --region us-west-1

# 2. Login to ECR
aws ecr get-login-password --region us-west-1 | docker login --username AWS --password-stdin YOUR_ACCOUNT_ID.dkr.ecr.us-west-1.amazonaws.com

# 3. Build and push Docker image
cd backend
docker build -t fiatlux-processor:latest -f infra/Dockerfile.processor .
docker tag fiatlux-processor:latest YOUR_ACCOUNT_ID.dkr.ecr.us-west-1.amazonaws.com/fiatlux-processor:latest
docker push YOUR_ACCOUNT_ID.dkr.ecr.us-west-1.amazonaws.com/fiatlux-processor:latest

# 4. Build and deploy SAM
cd infra
sam build --template-file template.yaml --use-container
sam deploy --parameter-overrides Stage=dev AnthropicApiKey=$ANTHROPIC_API_KEY
```

## After Deployment

### Get API URL

```bash
aws cloudformation describe-stacks \
  --stack-name fiatlux-backend-dev \
  --region us-west-1 \
  --query 'Stacks[0].Outputs[?OutputKey==`ApiUrl`].OutputValue' \
  --output text
```

### Update Swift App

In `BackendService.swift`, update the `BackendEnvironment.dev` URL:

```swift
case .dev:
    return "https://YOUR_API_ID.execute-api.us-west-1.amazonaws.com/dev"
```

### Test the API

```bash
# Health check
curl https://YOUR_API_ID.execute-api.us-west-1.amazonaws.com/dev/health

# Upload a PDF
curl -X POST https://YOUR_API_ID.execute-api.us-west-1.amazonaws.com/dev/upload \
  -H "Content-Type: application/json" \
  -d '{"path": "Notes/test.pdf", "content_base64": "BASE64_PDF_DATA"}'
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| ANTHROPIC_API_KEY | Claude API key | (required) |
| S3_BUCKET | Storage bucket name | fiatlux-storage-{stage}-{account} |
| JOBS_TABLE | DynamoDB jobs table | fiatlux-jobs-{stage} |
| AWS_REGION | AWS region | us-west-1 |

## Costs

With default settings (on-demand pricing):
- **Lambda**: ~$0.20 per 1M requests + compute time
- **S3**: ~$0.023/GB storage + $0.005/1K requests
- **DynamoDB**: ~$0.25/GB + $1.25/M write, $0.25/M read
- **API Gateway**: ~$1.00/M requests

Estimated monthly cost for light usage: **$1-5/month**

## Cleanup

To delete all resources:

```bash
aws cloudformation delete-stack --stack-name fiatlux-backend-dev --region us-west-1
aws ecr delete-repository --repository-name fiatlux-processor --region us-west-1 --force
```
