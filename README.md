Plateforme éducative : LMS, wiki collaboratif et tableau de bord d'analyse. Aucune configuration manuelle n'est nécessaire.

| Service     | Rôle                       | Technologie            | Port    |
| ----------- | -------------------------- | ---------------------- | ------- |
| `lms`       | Écosystème éducatif        | WordPress + LearnPress | 9081    |
| `wiki`      | Intelligence collective    | DokuWiki               | 9082    |
| `analytics` | Learning Analytics         | Grafana                | 9083    |
| `db`        | Base de données mutualisée | MariaDB 10.11          | interne |

## Répartition du travail

**Mon travail**

- Analyse du sujet et choix de l'architecture.
- Déploiement de la stack initiale (Moodle, Apache Hop) et diagnostic des saturations mémoire sur ma VM Proxmox (2 Go de RAM).
- Décision de pivoter vers WordPress/LearnPress, DokuWiki et Grafana.
- Rédaction du cahier des charges : services, images, ports, variables de proxy, liste `no_proxy`, limites `mem_limit`, comportement attendu des scripts d'initialisation.
- Premières versions du `docker-compose.yaml` (proxy, limites de ressources).
- Tests sur la VM, lecture des logs et remontée des erreurs pour correction.

**Travail réalisé avec une IA**

- Script `wp-setup.sh` (WP-CLI) : installation de WordPress, activation de LearnPress, création de 3 étudiants et de 2 cours.
- Script `wiki-seed.sh` : injection des pages du wiki.
- Fichiers de provisioning Grafana (source de données, tableau de bord) et script `grafana-setup.sh`.
- Corrections successives des erreurs que j'ai remontées (voir section 4).

Je comprends et je peux expliquer chaque ligne du livrable. Les sections 3 et 4 détaillent ces choix.

## Objectifs de la plateforme

La plateforme fournit trois usages.

**Enseignants.** Un tableau de bord Grafana lit directement la base du LMS. Il affiche le nombre d'utilisateurs inscrits, le nombre de cours publiés, les inscriptions par jour et la liste des derniers inscrits. Les données se rafraîchissent toutes les 30 secondes.

**Étudiants.** WordPress avec LearnPress fournit un espace de cours : catalogue, leçons, inscription. Trois comptes étudiants (rôle abonné) et deux cours de démonstration sont créés au démarrage.

**Groupes de projet.** DokuWiki fournit un wiki collaboratif avec historique des modifications et gestion des droits. Il stocke ses pages dans des fichiers texte, sans base de données. Une page d'accueil et une page d'architecture sont déjà présentes à l'ouverture.

Limite actuelle : les données de test contiennent des utilisateurs et des cours, sans inscriptions ni progression. Le tableau de bord mesure donc l'activité de création de comptes, pas encore le suivi pédagogique. Les tables de LearnPress permettent d'étendre les requêtes.

## Choix de l'architecture

### Constat

Notre sujet initial voulait utiliser Moodle, MediaWiki et Apache Hop. J'ai déployé cette stack sur ma VM Proxmox (2 Go de RAM). Elle saturait la mémoire :

- le noyau déclenchait l'OOM Killer ;
- des services étaient tués en cascade ;
- la machine devenait instable, jusqu'à des Kernel Panics.

Apache Hop tourne sur une JVM qui réserve de la mémoire dès le démarrage. Moodle et MediaWiki s'ajoutent à cette charge.

### Décision

Je conserve le besoin fonctionnel de chaque brique et je change les outils :

|Besoin|Sujet|Retenu|Raison|
|---|---|---|---|
|LMS|Moodle|WordPress + LearnPress|Empreinte mémoire plus faible, démarrage rapide|
|Wiki|MediaWiki|DokuWiki|Pas de base de données, pages en fichiers plats|
|BI|Apache Hop|Grafana|Pas de JVM, requêtes SQL directes, tableaux de bord temps réel|
|Données|Une base par outil|MariaDB mutualisée|Une seule instance, une source de données pour le LMS et la BI|

### Compromis

LearnPress couvre moins de fonctions que Moodle (évaluations avancées, SCORM étendu). Grafana ne remplace pas un outil d'ETL comme Apache Hop pour des transformations complexes. Ces deux limites sont acceptables dans mon contexte : la stack tient dans la mémoire disponible et répond aux trois usages du cahier des charges.

## Analyse de l'infrastructure (Docker Compose)

Les conteneurs sortent sur Internet à travers `cache.univ-pau.fr:3128`. J'ai factorisé la configuration dans une ancre YAML, réutilisée par fusion (`<<: *proxy-env`) dans chaque service :

```yaml
x-proxy-env: &proxy-env
  http_proxy: http://cache.univ-pau.fr:3128
  https_proxy: http://cache.univ-pau.fr:3128
  HTTP_PROXY: http://cache.univ-pau.fr:3128
  HTTPS_PROXY: http://cache.univ-pau.fr:3128
  no_proxy: localhost,127.0.0.1,10.3.16.151,db,lms,wiki,analytics
  NO_PROXY: localhost,127.0.0.1,10.3.16.151,db,lms,wiki,analytics
```

- Je définis les variables en minuscules et en majuscules. Les outils ne lisent pas la même casse (curl, Go, PHP, BusyBox).
- `no_proxy` exclut les noms de services et l'IP de la VM. Sans cette liste, le trafic entre conteneurs passerait par le proxy et échouerait.
- WordPress ne lit pas les variables d'environnement pour ses propres appels HTTP. Je déclare donc le proxy dans `wp-config.php` avec `WORDPRESS_CONFIG_EXTRA` : `WP_PROXY_HOST`, `WP_PROXY_PORT` et `WP_PROXY_BYPASS_HOSTS`. WP-CLI en a besoin pour télécharger LearnPress.
- Incident : le healthcheck de Grafana utilisait `wget` de BusyBox. Cet outil applique `http_proxy` mais ignore `no_proxy`. Le test sur `127.0.0.1` partait vers le proxy et échouait. Le healthcheck exécute désormais `unset` sur les variables de proxy avant l'appel.

### Limitation de la mémoire

Chaque service a un `mem_limit`. Si un conteneur dépasse sa limite, le noyau le tue lui seul, au lieu de déclencher l'OOM Killer sur toute la VM.

|Conteneur|`mem_limit`|Remarque|
|---|---|---|
|`db`|320 Mo|`innodb-buffer-pool-size=64M`, `max-connections=40`, `performance-schema=OFF`|
|`lms`|320 Mo|Apache limité à 8 processus (`MaxRequestWorkers 8`)|
|`wiki`|160 Mo||
|`analytics`|256 Mo||
|`wp-setup`|192 Mo|Éphémère|
|`wiki-seed`, `analytics-setup`|16 Mo|Éphémères|

Les services permanents totalisent 1 056 Mo de plafond, ce qui laisse de la marge sur 2 Go. Une limite de conteneur ne suffit pas si l'application ignore cette limite. J'ai donc aussi réduit les paramètres internes : le buffer InnoDB de MariaDB et le nombre de processus Apache, dont la valeur par défaut est de 150.

Relevé réel : `[à compléter avec la capture de docker stats]`

### Réseau, ports et volumes

- Tous les services sont sur un réseau dédié `unita-net` et se joignent par leur nom (`db`, `lms`, `wiki`, `analytics`).
- Seuls les ports 9081, 9082 et 9083 sont publiés. La base de données n'est pas exposée.
- Quatre volumes nommés (`db-data`, `wp-data`, `wiki-config`, `grafana-data`) conservent les données lors de la recréation des conteneurs.
- Les services permanents ont `restart: unless-stopped`. Les conteneurs d'initialisation ont `restart: "no"` : ils s'exécutent une fois et s'arrêtent.

### Dépendances et healthchecks

L'ordre de démarrage repose sur des conditions de santé, pas sur un simple ordre de lancement :

```
db (healthy) ──► lms (healthy) ──► wp-setup
db (healthy) ──► analytics (healthy) ──► analytics-setup
wiki (started) ──► wiki-seed
```

- `db` : `healthcheck.sh --connect --innodb_initialized`, fourni par l'image MariaDB.
- `lms` : test d'ouverture du port 80 avec PHP. L'image WordPress ne fournit pas toujours `curl`.
- `analytics` : appel à `/api/health`, sans proxy.
- `wiki` : l'image n'a pas de healthcheck. Le script `wiki-seed.sh` attend lui-même la fin de l'initialisation de DokuWiki.

## Automatisation du provisioning (aide IA)

Le correcteur lance une seule commande. Quatre conteneurs éphémères (ou scripts) préparent les données et les configurations. Cette partie a été générée avec une IA à partir de mon cahier des charges, puis corrigée selon nos tests.

### `wp-setup` : installation de WordPress avec WP-CLI

Le conteneur `wordpress:cli` partage le volume `wp-data` avec `lms`. Le script s'exécute dans cet ordre :

1. Attente des fichiers WordPress et de `wp-config.php`, puis de la base de données (60 essais, 5 secondes d'intervalle).
2. `wp core install` en mode silencieux, avec l'URL `http://10.3.16.151:9081`.
3. Installation et activation du plugin LearnPress, avec 5 essais en cas d'échec réseau.
4. Création de 3 utilisateurs au rôle abonné (`etudiant1` à `etudiant3`).
5. Création de 2 cours avec le type de contenu `lp_course`.

Le script est idempotent : chaque étape vérifie l'existence de la ressource avant de la créer. Un second `docker compose up -d` ne crée aucun doublon.

Le conteneur tourne avec `user: "33:33"`. Les fichiers du volume appartiennent à `www-data` (UID 33), et l'utilisateur par défaut de l'image CLI n'a pas le droit d'y écrire.

Incident : la première version échouait avec « Error establishing a database connection » sur l'hôte `mysql`. Le `wp-config.php` de l'image WordPress lit `WORDPRESS_DB_HOST` à chaque exécution. Le conteneur `wp-setup` ne recevait pas cette variable et utilisait la valeur par défaut. J'ai ajouté les quatre variables `WORDPRESS_DB_*` à ce service.

### `wiki-seed` : injection des pages DokuWiki

Un conteneur `busybox` monte le volume `wiki-config`. Il attend que DokuWiki ait créé son dossier `data/pages`, puis copie `start.txt` et `architecture_unita.txt`. Le script ne remplace pas une page existante.

Je n'ai pas monté les fichiers directement dans le volume du wiki. Docker aurait créé les dossiers avec les droits root avant l'initialisation de l'image `linuxserver/dokuwiki`, ce qui perturbe sa première configuration.

Le nom de fichier est en minuscules : DokuWiki convertit les identifiants de pages en minuscules, et un fichier `Architecture_UNITA.txt` ne serait pas retrouvé.

### Provisioning Grafana

Arborescence :

```
grafana-provisioning/
├── datasources/mariadb.yaml
└── dashboards/
    ├── dashboards.yaml
    └── json/unita-analytics.json
```

- **Source de données** : `mariadb.yaml` déclare la connexion à `db:3306`, base `edudata`. Le mot de passe est lu depuis la variable d'environnement `EDU_DB_PASSWORD`, pour ne pas l'écrire dans le fichier.
- **Fournisseur de tableaux de bord** : `dashboards.yaml` indique à Grafana de charger les fichiers JSON du dossier `json/` et de les relire toutes les 30 secondes.
- **Tableau de bord** : `unita-analytics.json` contient 4 panneaux : nombre d'utilisateurs (`SELECT COUNT(ID) FROM wp_users`), nombre de cours publiés, inscriptions par jour, 10 derniers inscrits.
- **Accès** : l'accès anonyme en lecture seule est activé, pour que le correcteur voie le tableau de bord sans se connecter.

Incident : j'ai d'abord défini la page d'accueil avec `GF_DASHBOARDS_DEFAULT_HOME_DASHBOARD_PATH`. Grafana répondait « Failed to load home dashboard ». Ce réglage est fragile selon les versions. Je l'ai remplacé par le conteneur `analytics-setup`. Il attend que le tableau de bord provisionné existe, puis appelle l'API `PUT /api/org/preferences` avec son identifiant (`homeDashboardUID`).

### Résultat

```bash
docker compose up -d
```

Au bout de 3 à 5 minutes (le téléchargement de LearnPress via le proxy est l'étape la plus longue) :

- `http://10.3.16.151:9081` : WordPress avec LearnPress, 3 étudiants, 2 cours ;
- `http://10.3.16.151:9082` : wiki avec ses deux pages ;
- `http://10.3.16.151:9083` : tableau de bord Grafana affiché par défaut.

Les trois conteneurs d'initialisation (`wp-setup`, `wiki-seed`, `analytics-setup`) se terminent avec le code `0`.

### Limites et améliorations

- Les mots de passe sont en clair dans le compose. En production, je les placerais dans un fichier `.env` ou dans des secrets Docker.
- Grafana utilise le compte `edu_user`, qui a tous les droits sur la base. Un compte en lecture seule serait plus sûr.
- L'accès est en HTTP, sans reverse proxy ni TLS.
- Il n'y a aucune sauvegarde automatique des volumes.
- Le démon Docker doit pouvoir accéder au proxy pour télécharger les images au premier lancement. Les variables des conteneurs ne s'appliquent pas à `docker pull`.
