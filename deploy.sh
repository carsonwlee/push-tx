#!/bin/bash

# Load environment variables from .env file
export $(grep -v '^#' .env | xargs)

# Function to log messages
log() {
  local MESSAGE=$1
  echo "[INFO] $MESSAGE"
}

# Function to log errors
error() {
  local MESSAGE=$1
  echo "[ERROR] $MESSAGE" >&2
}

# Function to get existing certificate ARN
get_existing_certificate_arn() {
  EXISTING_CERTIFICATE_ARN=$(aws acm list-certificates --query "CertificateSummaryList[?DomainName=='$DOMAIN_NAME'].CertificateArn" --output text)
  echo $EXISTING_CERTIFICATE_ARN
}

# Function to get DNS validation records
get_dns_validation_records() {
  local CERT_ARN=$1
  RETRY_COUNT=0
  MAX_RETRIES=15
  SLEEP_DURATION=20

  while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    log "Retrieving DNS validation records (attempt $((RETRY_COUNT+1))/$MAX_RETRIES)..."
    VALIDATION_OPTIONS=$(aws acm describe-certificate --certificate-arn $CERT_ARN --query 'Certificate.DomainValidationOptions[0].ResourceRecord' --output json)
    
    log "Validation Options: $VALIDATION_OPTIONS"
    
    DNS_NAME=$(echo $VALIDATION_OPTIONS | jq -r '.Name')
    DNS_VALUE=$(echo $VALIDATION_OPTIONS | jq -r '.Value')
    
    if [[ -n "$DNS_NAME" && -n "$DNS_VALUE" ]]; then
      break
    fi
    
    RETRY_COUNT=$((RETRY_COUNT+1))
    log "Validation records not available yet. Retrying in $SLEEP_DURATION seconds..."
    sleep $SLEEP_DURATION
  done

  if [[ -z "$DNS_NAME" || -z "$DNS_VALUE" ]]; then
    error "Unable to retrieve DNS validation records. Please check the ACM certificate details."
    exit 1
  fi
}

# Split GitHubRepo into owner and name
GITHUB_REPO_OWNER=$(echo $GITHUB_REPO | cut -d'/' -f1)
GITHUB_REPO_NAME=$(echo $GITHUB_REPO | cut -d'/' -f2)

# Check if a certificate already exists for the domain
EXISTING_CERTIFICATE_ARN=$(get_existing_certificate_arn)

if [[ -n "$EXISTING_CERTIFICATE_ARN" ]]; then
  log "Existing certificate found for domain $DOMAIN_NAME. Certificate ARN: $EXISTING_CERTIFICATE_ARN"
  CERTIFICATE_ARN=$EXISTING_CERTIFICATE_ARN
else
  log "No existing certificate found for domain $DOMAIN_NAME. Requesting a new ACM certificate..."
  CERTIFICATE_ARN=$(aws acm request-certificate --domain-name $DOMAIN_NAME --validation-method DNS --key-algorithm RSA_2048 --query CertificateArn --output text)
  
  if [[ -z "$CERTIFICATE_ARN" ]]; then
    error "Failed to request ACM certificate."
    exit 1
  fi
  
  log "New certificate ARN: $CERTIFICATE_ARN"
fi

# Retrieve DNS validation records
get_dns_validation_records $CERTIFICATE_ARN

# Print the DNS validation details
log "Please add the following DNS record to your domain to validate the ACM certificate:"
log "Name: $DNS_NAME"
log "Value: $DNS_VALUE"

# Wait for the user to add the DNS record
read -p "Press [Enter] key once DNS record has been added..."

# Wait for ACM certificate to be validated
log "Waiting for certificate to be issued..."
aws acm wait certificate-validated --certificate-arn $CERTIFICATE_ARN

if [[ $? -ne 0 ]]; then
  error "Certificate validation failed."
  exit 1
fi

# Get AWS region
AWS_REGION=$(aws configure get region)

# Create S3 bucket
log "Creating S3 bucket..."
BUCKET_NAME="push-tx-static-site-$(openssl rand -hex 4)"
aws s3 mb s3://$BUCKET_NAME --region $AWS_REGION

# Check if CloudFormation stack exists
STACK_STATUS=$(aws cloudformation describe-stacks --stack-name push-tx --query "Stacks[0].StackStatus" --output text 2>&1)

if [[ "$STACK_STATUS" == *"does not exist"* ]]; then
  # Deploy CloudFormation stack
  log "Deploying CloudFormation stack..."
  aws cloudformation create-stack --stack-name push-tx \
    --template-body file://cloudformation-template.yaml \
    --parameters ParameterKey=DomainName,ParameterValue=$DOMAIN_NAME \
                 ParameterKey=CertificateArn,ParameterValue=$CERTIFICATE_ARN \
    --capabilities CAPABILITY_IAM

  if [[ $? -ne 0 ]]; then
    error "Failed to create CloudFormation stack."
    exit 1
  fi

  # Wait for the stack to be created
  aws cloudformation wait stack-create-complete --stack-name push-tx
else
  # Update CloudFormation stack
  log "Updating CloudFormation stack..."
  aws cloudformation update-stack --stack-name push-tx \
    --template-body file://cloudformation-template.yaml \
    --parameters ParameterKey=DomainName,ParameterValue=$DOMAIN_NAME \
                 ParameterKey=CertificateArn,ParameterValue=$CERTIFICATE_ARN \
    --capabilities CAPABILITY_IAM

  if [[ $? -ne 0 ]]; then
    error "Failed to update CloudFormation stack."
    exit 1
  fi

  # Wait for the stack to be updated
  aws cloudformation wait stack-update-complete --stack-name push-tx
fi

# Get CloudFront Distribution Domain Name from Stack Outputs
DISTRIBUTION_DOMAIN=$(aws cloudformation describe-stacks --stack-name push-tx --query "Stacks[0].Outputs[?OutputKey=='CloudFrontDistributionDomainName'].OutputValue" --output text)

if [[ -z "$DISTRIBUTION_DOMAIN" ]]; then
  error "Failed to retrieve CloudFront distribution domain name."
  exit 1
fi

# Print the CloudFront Distribution Domain Name
log "CloudFront Distribution Domain Name: $DISTRIBUTION_DOMAIN"
