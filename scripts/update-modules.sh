#!/usr/bin/env bash
# Pins the MONARC modules to the current head of their master-asin branch:
# PHP modules in composer.lock, ng modules in ng-modules.lock. Nothing is committed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

BRANCH=master-asin
NG_LOCK=ng-modules.lock

php_modules=$(grep -oE '"monarc/[a-z-]+": *"dev-' composer.json | cut -d'"' -f2 | tr '\n' ' ')
echo "Modules PHP : ${php_modules}"
# Composer runs in a container: nothing to install on the workstation.
# One run uses about 45 anonymous GitHub API requests (limit: 60 per hour); COMPOSER_AUTH is passed through
# to run it more often.
MSYS_NO_PATHCONV=1 docker run --rm --user "$(id -u):$(id -g)" -e HOME=/tmp -e COMPOSER_HOME=/tmp/composer -e COMPOSER_AUTH \
  -v "$(pwd -W 2>/dev/null || pwd):/app" -w /app composer:2 \
  composer update ${php_modules} --no-install --no-scripts --no-plugins --ignore-platform-req='ext-*' --no-interaction \
  || { echo "Échec de Composer (cause ci-dessus). Si « Could not authenticate » : quota GitHub anonyme épuisé, réessayer dans une heure ou définir COMPOSER_AUTH." >&2; exit 1; }

content=$(tr -d '\r' < "$NG_LOCK" | grep '^#')
for module in $(tr -d '\r' < "$NG_LOCK" | grep -oE '^ng_[a-z]+'); do
  repo=${module//_/-}
  commit=$(git ls-remote "https://github.com/ASINBenin/${repo}.git" "refs/heads/${BRANCH}" | cut -f1)
  [[ $commit =~ ^[0-9a-f]{40}$ ]] || { echo "Commit de ${repo} (${BRANCH}) introuvable." >&2; exit 1; }
  echo "Module ng : ${repo} ${commit:0:7}"
  content+=$'\n'"${module}=${commit}"
done
printf '%s\n' "$content" > "$NG_LOCK"

echo
echo "Changements à vérifier (rien n'est commité) :"
git --no-pager diff --stat -- composer.lock "$NG_LOCK"
echo "Après test : git add composer.lock ${NG_LOCK} && git commit"
