#!/usr/bin/env bash
set -e

REPO_DIR="/home/qqcry/Projekte/inputplumber-legion-go-fix"
cd "$REPO_DIR"

echo "=========================================================="
echo "  Upload InputPlumber Fix to GitHub                       "
echo "=========================================================="

# 1. Check GitHub CLI login
if ! gh auth status &>/dev/null; then
  echo "[*] You are not logged in to GitHub yet."
  echo "[*] Launching web login (browser will open shortly)..."
  echo ""
  gh auth login --web -p https
fi

echo ""
echo "[+] Successfully authenticated with GitHub!"
echo ""

# 2. Check if remote exists
if git remote get-url origin &>/dev/null; then
  echo "[*] Existing remote found. Pushing changes..."
  git push -u origin main
else
  echo "[*] Creating new GitHub repository 'inputplumber-legion-go-fix'..."
  gh repo create inputplumber-legion-go-fix --public --source=. --push
fi

echo ""
echo "=========================================================="
echo "[+] Done! Repository uploaded successfully:"
gh repo view --web || true
echo "=========================================================="
