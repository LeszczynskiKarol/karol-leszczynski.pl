#!/bin/bash
# Setup AWS infrastructure for karol-leszczynski.pl contact form
# Run once: ./setup-aws.sh
# Prerequisites: aws cli configured, domain verified in SES

set -e
REGION="eu-central-1"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
PREFIX="karol-leszczynski"
BUCKET="${PREFIX}-attachments"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$SCRIPT_DIR/.tmp"
mkdir -p "$TMP_DIR"

echo "============================================"
echo " Setup: karol-leszczynski.pl Contact Form"
echo " Region: $REGION"
echo " Account: $ACCOUNT_ID"
echo "============================================"
echo ""

to_win_path() {
  cygpath -w "$1" 2>/dev/null || echo "$1"
}

fileb() {
  echo "fileb://$(to_win_path "$1")"
}

make_zip() {
  local src_dir="$1"
  local zip_name="$2"
  local zip_path="$TMP_DIR/$zip_name"
  rm -f "$zip_path"
  if command -v zip &>/dev/null; then
    (cd "$src_dir" && zip -r "$zip_path" . -x "*.git*" > /dev/null 2>&1)
  else
    local win_src win_zip
    win_src=$(to_win_path "$src_dir")
    win_zip=$(to_win_path "$zip_path")
    powershell.exe -NoProfile -Command "Compress-Archive -Path '${win_src}\\*' -DestinationPath '${win_zip}' -Force"
  fi
  [ -f "$zip_path" ] || { echo "BŁĄD: Nie utworzono $zip_path"; exit 1; }
}

# ─── 1. S3 Bucket for attachments ───
echo ">>> 1. S3 Bucket: $BUCKET"
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "    Bucket już istnieje."
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" > /dev/null
  echo "    Bucket utworzony."
fi

# CORS for presigned uploads
aws s3api put-bucket-cors --bucket "$BUCKET" --cors-configuration '{
  "CORSRules": [{
    "AllowedOrigins": ["https://www.karol-leszczynski.pl","https://karol-leszczynski.pl","http://localhost:4321"],
    "AllowedMethods": ["PUT","GET"],
    "AllowedHeaders": ["*"],
    "MaxAgeSeconds": 3600
  }]
}' --region "$REGION"

# Lifecycle — delete uploads after 30 days
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" --lifecycle-configuration '{
  "Rules": [{
    "ID": "DeleteUploadsAfter30Days",
    "Filter": {"Prefix": "uploads/"},
    "Status": "Enabled",
    "Expiration": {"Days": 30}
  }]
}' --region "$REGION"
echo "    CORS + lifecycle skonfigurowane."

# ─── 2. IAM Role for Lambdas ───
ROLE_NAME="${PREFIX}-lambda-role"
echo ""
echo ">>> 2. IAM Role: $ROLE_NAME"

ROLE_ARN=$(aws iam get-role --role-name "$ROLE_NAME" --query 'Role.Arn' --output text 2>/dev/null || true)
if [ -n "$ROLE_ARN" ] && [ "$ROLE_ARN" != "None" ]; then
  echo "    Rola już istnieje: $ROLE_ARN"
else
  ROLE_ARN=$(aws iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
    }' \
    --query 'Role.Arn' --output text)
  echo "    Rola utworzona: $ROLE_ARN"
  sleep 5
fi

# Attach policies
aws iam attach-role-policy --role-name "$ROLE_NAME" \
  --policy-arn "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole" 2>/dev/null || true

# S3 + SES inline policy
aws iam put-role-policy --role-name "$ROLE_NAME" \
  --policy-name "${PREFIX}-s3-ses-access" \
  --policy-document "{
    \"Version\":\"2012-10-17\",
    \"Statement\":[
      {\"Effect\":\"Allow\",\"Action\":[\"s3:PutObject\",\"s3:GetObject\"],\"Resource\":\"arn:aws:s3:::${BUCKET}/*\"},
      {\"Effect\":\"Allow\",\"Action\":[\"ses:SendEmail\",\"ses:SendRawEmail\"],\"Resource\":\"*\"}
    ]
  }"
echo "    Polityki przypisane."

# ─── 3. Lambda: presign ───
PRESIGN_NAME="${PREFIX}-presign"
echo ""
echo ">>> 3. Lambda: $PRESIGN_NAME"
cd "$SCRIPT_DIR/aws-lambdas/presign-upload"
npm install --production --silent 2>/dev/null || npm install --production
make_zip "$SCRIPT_DIR/aws-lambdas/presign-upload" "presign-upload.zip"

if aws lambda get-function --function-name "$PRESIGN_NAME" --region "$REGION" &>/dev/null; then
  aws lambda update-function-code --function-name "$PRESIGN_NAME" \
    --zip-file "$(fileb "$TMP_DIR/presign-upload.zip")" --region "$REGION" > /dev/null
  echo "    Zaktualizowana."
else
  aws lambda create-function --function-name "$PRESIGN_NAME" \
    --runtime "nodejs20.x" --handler "index.handler" --role "$ROLE_ARN" \
    --zip-file "$(fileb "$TMP_DIR/presign-upload.zip")" \
    --timeout 15 --memory-size 128 \
    --environment "Variables={BUCKET_NAME=${BUCKET}}" \
    --region "$REGION" > /dev/null
  echo "    Utworzona."
fi

# ─── 4. Lambda: contact ───
CONTACT_NAME="${PREFIX}-contact"
echo ""
echo ">>> 4. Lambda: $CONTACT_NAME"
cd "$SCRIPT_DIR/aws-lambdas/contact-form"
npm install --production --silent 2>/dev/null || npm install --production
make_zip "$SCRIPT_DIR/aws-lambdas/contact-form" "contact-form.zip"

if aws lambda get-function --function-name "$CONTACT_NAME" --region "$REGION" &>/dev/null; then
  aws lambda update-function-code --function-name "$CONTACT_NAME" \
    --zip-file "$(fileb "$TMP_DIR/contact-form.zip")" --region "$REGION" > /dev/null
  echo "    Zaktualizowana."
else
  aws lambda create-function --function-name "$CONTACT_NAME" \
    --runtime "nodejs20.x" --handler "index.handler" --role "$ROLE_ARN" \
    --zip-file "$(fileb "$TMP_DIR/contact-form.zip")" \
    --timeout 30 --memory-size 256 \
    --environment "Variables={BUCKET_NAME=${BUCKET}}" \
    --region "$REGION" > /dev/null
  echo "    Utworzona."
fi

# ─── 5. API Gateway (HTTP API) ───
API_NAME="${PREFIX}-api"
echo ""
echo ">>> 5. API Gateway: $API_NAME"

API_ID=$(aws apigatewayv2 get-apis --region "$REGION" \
  --query "Items[?Name=='${API_NAME}'].ApiId | [0]" --output text 2>/dev/null || echo "None")

if [ "$API_ID" != "None" ] && [ -n "$API_ID" ]; then
  echo "    API już istnieje: $API_ID"
else
  API_ID=$(aws apigatewayv2 create-api --name "$API_NAME" \
    --protocol-type HTTP \
    --cors-configuration '{
      "AllowOrigins":["https://www.karol-leszczynski.pl","https://karol-leszczynski.pl","http://localhost:4321"],
      "AllowMethods":["POST","OPTIONS"],
      "AllowHeaders":["Content-Type"],
      "MaxAge":3600
    }' \
    --region "$REGION" --query 'ApiId' --output text)
  echo "    API utworzone: $API_ID"
fi

# Integrations
for FUNC in presign contact; do
  FUNC_NAME="${PREFIX}-${FUNC}"
  FUNC_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNC_NAME}"
  ROUTE_PATH="/${FUNC}"

  INTEGRATION_ID=$(aws apigatewayv2 get-integrations --api-id "$API_ID" --region "$REGION" \
    --query "Items[?contains(IntegrationUri,'${FUNC_NAME}')].IntegrationId | [0]" --output text 2>/dev/null || echo "None")

  if [ "$INTEGRATION_ID" = "None" ] || [ -z "$INTEGRATION_ID" ]; then
    INTEGRATION_ID=$(aws apigatewayv2 create-integration --api-id "$API_ID" \
      --integration-type AWS_PROXY \
      --integration-uri "$FUNC_ARN" \
      --payload-format-version "2.0" \
      --region "$REGION" --query 'IntegrationId' --output text)
  fi

  ROUTE_EXISTS=$(aws apigatewayv2 get-routes --api-id "$API_ID" --region "$REGION" \
    --query "Items[?RouteKey=='POST ${ROUTE_PATH}'].RouteId | [0]" --output text 2>/dev/null || echo "None")

  if [ "$ROUTE_EXISTS" = "None" ] || [ -z "$ROUTE_EXISTS" ]; then
    aws apigatewayv2 create-route --api-id "$API_ID" \
      --route-key "POST ${ROUTE_PATH}" \
      --target "integrations/${INTEGRATION_ID}" \
      --region "$REGION" > /dev/null
  fi

  # Lambda permission
  aws lambda add-permission --function-name "$FUNC_NAME" \
    --statement-id "apigateway-${FUNC}-invoke" \
    --action "lambda:InvokeFunction" \
    --principal "apigateway.amazonaws.com" \
    --source-arn "arn:aws:execute-api:${REGION}:${ACCOUNT_ID}:${API_ID}/*" \
    --region "$REGION" 2>/dev/null || true

  echo "    Route: POST ${ROUTE_PATH} → ${FUNC_NAME}"
done

# Auto-deploy stage
STAGE_EXISTS=$(aws apigatewayv2 get-stages --api-id "$API_ID" --region "$REGION" \
  --query "Items[?StageName=='\$default'].StageName | [0]" --output text 2>/dev/null || echo "None")

if [ "$STAGE_EXISTS" = "None" ] || [ -z "$STAGE_EXISTS" ]; then
  aws apigatewayv2 create-stage --api-id "$API_ID" --stage-name '$default' \
    --auto-deploy --region "$REGION" > /dev/null
fi

API_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com"
echo ""
echo "============================================"
echo " ✅ Setup zakończony!"
echo ""
echo " API URL: $API_URL"
echo " Endpoints:"
echo "   POST ${API_URL}/presign"
echo "   POST ${API_URL}/contact"
echo ""
echo " ⚠️  Wstaw API_URL do kontakt.astro:"
echo "   const API_URL = '${API_URL}';"
echo ""
echo " ⚠️  Upewnij się, że domena karol-leszczynski.pl"
echo "     jest zweryfikowana w SES (region: ${REGION})"
echo "     i że formularz@karol-leszczynski.pl może wysyłać"
echo "============================================"

rm -rf "$TMP_DIR"
