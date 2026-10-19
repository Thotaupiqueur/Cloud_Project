#!/bin/sh
set -eu

WP="wp --path=/var/www/html"

log() {
  echo "[wp-setup] $*"
}

retry() {
  attempts=$1
  delay=$2
  shift 2
  n=0
  until "$@"; do
    n=$((n + 1))
    if [ "$n" -ge "$attempts" ]; then
      return 1
    fi
    sleep "$delay"
  done
}

wordpress_files_ready() {
  [ -f /var/www/html/wp-config.php ] && [ -f /var/www/html/wp-includes/version.php ]
}

database_ready() {
  php -r 'mysqli_report(MYSQLI_REPORT_OFF); [$h, $p] = array_pad(explode(":", getenv("WORDPRESS_DB_HOST")), 2, 3306); exit(@mysqli_connect($h, getenv("WORDPRESS_DB_USER"), getenv("WORDPRESS_DB_PASSWORD"), getenv("WORDPRESS_DB_NAME"), (int) $p) ? 0 : 1);'
}

create_course() {
  title=$1
  content=$2
  if $WP post list --post_type=lp_course --post_status=any --field=post_title | grep -qxF "$title"; then
    return 0
  fi
  $WP post create \
    --post_type=lp_course \
    --post_status=publish \
    --post_author=1 \
    --post_title="$title" \
    --post_content="$content"
}

log "waiting for WordPress files"
retry 60 5 wordpress_files_ready

log "waiting for database"
retry 60 5 database_ready

if ! $WP core is-installed 2>/dev/null; then
  log "installing WordPress"
  retry 5 10 $WP core install \
    --url="$WP_URL" \
    --title="$WP_TITLE" \
    --admin_user="$WP_ADMIN_USER" \
    --admin_password="$WP_ADMIN_PASSWORD" \
    --admin_email="$WP_ADMIN_EMAIL" \
    --skip-email
fi

if ! $WP plugin is-installed learnpress 2>/dev/null; then
  log "installing LearnPress"
  retry 5 15 $WP plugin install learnpress
fi

if ! $WP plugin is-active learnpress 2>/dev/null; then
  log "activating LearnPress"
  $WP plugin activate learnpress
fi

log "creating students"
while IFS=: read -r login first last; do
  if ! $WP user get "$login" >/dev/null 2>&1; then
    $WP user create "$login" "$login@unita.local" \
      --role=subscriber \
      --user_pass="$WP_STUDENT_PASSWORD" \
      --first_name="$first" \
      --last_name="$last" \
      --display_name="$first $last"
  fi
done <<USERS
etudiant1:Alice:Martin
etudiant2:Lucas:Garcia
etudiant3:Sofia:Rossi
USERS

log "creating courses"
create_course "Introduction au Cloud Computing" "Fondamentaux du Cloud : virtualisation, conteneurs, Infrastructure as Code et orchestration avec Docker Compose."
create_course "Learning Analytics avec Grafana" "Exploiter les donnees d'apprentissage pour piloter la pedagogie : requetes SQL et tableaux de bord temps reel."

log "setup complete"
