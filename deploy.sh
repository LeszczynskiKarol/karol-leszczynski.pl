#!/bin/bash
# Deploy karol-leszczynski.pl to AWS S3 + CloudFront
# Usage: ./deploy.sh
#
# Infrastructure:
#   karol-leszczynski.pl     → S3: karol-leszczynski.pl         → CF: E1WSPFUI6IC88H
#   www.karol-leszczynski.pl → S3: karolleszczynski-portfolio   → CF: E5XFF2KOROL5S
#   Region: eu-north-1

set -e

REGION="eu-north-1"
BUCKET_NAKED="karol-leszczynski.pl"
BUCKET_WWW="karolleszczynski-portfolio"
CF_NAKED="E1WSPFUI6IC88H"
CF_WWW="E5XFF2KOROL5S"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DIST_DIR="$SCRIPT_DIR/dist"

echo "============================================"
echo " Deploy: karol-leszczynski.pl"
echo " Region: $REGION"
echo "============================================"
echo ""

echo "📦 Pushing to GitHub..."
git add .
git commit -m "git push from local"
git push origin main

if [ $? -ne 0 ]; then
  echo "❌ Git push failed!"
  exit 1
fi


# ─── 1. Build ───
echo ">>> 1. Building Astro..."
cd "$SCRIPT_DIR"
npm run build
echo "    ✅ Build zakończony"
echo ""

# Verify dist exists
if [ ! -d "$DIST_DIR" ]; then
  echo "BŁĄD: Brak katalogu dist/. Build się nie powiódł."
  exit 1
fi

PAGE_COUNT=$(find "$DIST_DIR" -name "*.html" | wc -l)
echo "    Stron: $PAGE_COUNT"
echo ""

# ─── 2. Sync to S3 (naked domain bucket) ───
echo ">>> 2. Sync → s3://$BUCKET_NAKED"

# Assets — long cache
aws s3 sync "$DIST_DIR" "s3://$BUCKET_NAKED" \
  --delete \
  --region "$REGION" \
  --cache-control "public, max-age=31536000, immutable" \
  --exclude "*.html" \
  --exclude "robots.txt" \
  --exclude "*.xml"

# HTML + robots.txt — short cache, text/html
aws s3 sync "$DIST_DIR" "s3://$BUCKET_NAKED" \
  --region "$REGION" \
  --cache-control "public, max-age=0, must-revalidate" \
  --exclude "*" \
  --include "*.html" \
  --include "robots.txt" \
  --content-type "text/html"

# XML (sitemaps) — short cache, application/xml
aws s3 sync "$DIST_DIR" "s3://$BUCKET_NAKED" \
  --region "$REGION" \
  --cache-control "public, max-age=3600" \
  --exclude "*" \
  --include "*.xml" \
  --content-type "application/xml"

echo "    ✅ Naked domain bucket zsynchronizowany"
echo ""

# ─── 3. Sync to S3 (www bucket) ───
echo ">>> 3. Sync → s3://$BUCKET_WWW"

# Assets — long cache
aws s3 sync "$DIST_DIR" "s3://$BUCKET_WWW" \
  --delete \
  --region "$REGION" \
  --cache-control "public, max-age=31536000, immutable" \
  --exclude "*.html" \
  --exclude "robots.txt" \
  --exclude "*.xml"

# HTML + robots.txt
aws s3 sync "$DIST_DIR" "s3://$BUCKET_WWW" \
  --region "$REGION" \
  --cache-control "public, max-age=0, must-revalidate" \
  --exclude "*" \
  --include "*.html" \
  --include "robots.txt" \
  --content-type "text/html"

# XML (sitemaps)
aws s3 sync "$DIST_DIR" "s3://$BUCKET_WWW" \
  --region "$REGION" \
  --cache-control "public, max-age=3600" \
  --exclude "*" \
  --include "*.xml" \
  --content-type "application/xml"

echo "    ✅ WWW bucket zsynchronizowany"
echo ""

# ─── 4. CloudFront invalidation ───
echo ">>> 4. CloudFront invalidation..."

INV_NAKED=$(aws cloudfront create-invalidation \
  --distribution-id "$CF_NAKED" \
  --paths "/*" \
  --query 'Invalidation.Id' --output text)
echo "    Naked (${CF_NAKED}): $INV_NAKED"

INV_WWW=$(aws cloudfront create-invalidation \
  --distribution-id "$CF_WWW" \
  --paths "/*" \
  --query 'Invalidation.Id' --output text)
echo "    WWW   (${CF_WWW}): $INV_WWW"

echo ""
echo "============================================"
echo " ✅ Deploy zakończony!"
echo ""
echo " Strony: $PAGE_COUNT"
echo " Bucket naked:  s3://$BUCKET_NAKED"
echo " Bucket www:    s3://$BUCKET_WWW"
echo " CF naked:      $CF_NAKED → $INV_NAKED"
echo " CF www:        $CF_WWW   → $INV_WWW"
echo ""
echo " Cache invalidation trwa 1-2 minuty."
echo " https://karol-leszczynski.pl"
echo " https://www.karol-leszczynski.pl"
echo "============================================"
