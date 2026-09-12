#!/usr/bin/env bash
set -e

REPO_DIR="/home/qqcry/Projekte/inputplumber-legion-go-fix"
cd "$REPO_DIR"

echo "=========================================================="
echo "  InputPlumber Fix auf GitHub hochladen                   "
echo "=========================================================="

# 1. GitHub CLI Login prüfen
if ! gh auth status &>/dev/null; then
  echo "[*] Du bist noch nicht bei GitHub angemeldet."
  echo "[*] Starte Web-Login (Dein Browser öffnet sich gleich)..."
  echo ""
  gh auth login --web -p https
fi

echo ""
echo "[+] Erfolgreich bei GitHub angemeldet!"
echo ""

# 2. Prüfen, ob Remote bereits existiert
if git remote get-url origin &>/dev/null; then
  echo "[*] Bestehendes Remote gefunden. Pushe Änderungen..."
  git push -u origin main
else
  echo "[*] Erstelle neues GitHub-Repository 'inputplumber-legion-go-fix'..."
  gh repo create inputplumber-legion-go-fix --public --source=. --push
fi

echo ""
echo "=========================================================="
echo "[+] Fertig! Das Repository wurde erfolgreich hochgeladen:"
gh repo view --web || true
echo "=========================================================="
