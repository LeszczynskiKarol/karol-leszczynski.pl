#!/bin/bash
# Szybka aktualizacja kodu Lambda po zmianach
# Użycie: ./update-lambdas.sh [presign|contact|all]

set -e
REGION="eu-central-1"
PREFIX="karol-leszczynski"
TARGET=${1:-all}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_DIR="$SCRIPT_DIR/.tmp"
mkdir -p "$TMP_DIR"

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

update_presign() {
  echo ">>> Aktualizacja: ${PREFIX}-presign"
  cd "$SCRIPT_DIR/aws-lambdas/presign-upload"
  npm install --production --silent 2>/dev/null || npm install --production
  make_zip "$SCRIPT_DIR/aws-lambdas/presign-upload" "presign-upload.zip"
  aws lambda update-function-code \
    --function-name "${PREFIX}-presign" \
    --zip-file "$(fileb "$TMP_DIR/presign-upload.zip")" \
    --region "$REGION" > /dev/null
  echo "    ✅ Gotowe"
}

update_contact() {
  echo ">>> Aktualizacja: ${PREFIX}-contact"
  cd "$SCRIPT_DIR/aws-lambdas/contact-form"
  npm install --production --silent 2>/dev/null || npm install --production
  make_zip "$SCRIPT_DIR/aws-lambdas/contact-form" "contact-form.zip"
  aws lambda update-function-code \
    --function-name "${PREFIX}-contact" \
    --zip-file "$(fileb "$TMP_DIR/contact-form.zip")" \
    --region "$REGION" > /dev/null
  echo "    ✅ Gotowe"
}

case "$TARGET" in
  presign) update_presign ;;
  contact) update_contact ;;
  all)     update_presign; update_contact ;;
  *)       echo "Użycie: $0 [presign|contact|all]"; exit 1 ;;
esac

rm -rf "$TMP_DIR"
echo ""
echo "Gotowe! Lambdy zaktualizowane."
