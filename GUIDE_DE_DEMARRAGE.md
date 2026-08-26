# 📖 GUIDE DE DÉPLOIEMENT ET D'INITIALISATION - BACK OFFICE (`MonarcAppBO`)

> **Application Hôte :** `MonarcAppBO` (Port HTTP `5002`)  
> **Racine de l'application :** `./MonarcAppBO`  
> **Structure des dépôts :** Dépôts frères à la racine de `v_current` (`../zm-core`, `../zm-backoffice`, `../ng-anr`, `../ng-backoffice`)  

---

## 📌 Table des Matières
- [🏗️ 1. Architecture & Dépendances du BackOffice](#️-1-architecture--dépendances-du-backoffice)
- [🛠️ 2. Configuration & Points d'Intégration Clés](#️-2-configuration--points-dintégration-clés)
  - [A. Configuration Environnement (`.env`)](#a-configuration-environnement-env)
  - [B. Montage des Dépôts Locaux (`docker-compose.dev.yml`)](#b-montage-des-dépôts-locaux-docker-composedevyml)
  - [C. Liens Symboliques Dynamiques (`docker-entrypoint.sh`)](#c-liens-symboliques-dynamiques-docker-entrypointsh)
- [🚀 3. Procédure Automatisée de Démarrage (PowerShell)](#-3-procédure-automatisée-de-démarrage-powershell)
- [🌐 4. Accès & Identifiants Administrateur](#-4-accès--identifiants-administrateur)
- [⚠️ 5. Guide de Dépannage & Correctifs Historiques](#-5-guide-de-dépannage--correctifs-historiques)
  - [Bug 1 : Fins de ligne Windows (`/bin/sh^M: bad interpreter` sur `10-dev-grants.sh`)](#bug-1--fins-de-ligne-windows-binshm-bad-interpreter-sur-10-dev-grantssh)
  - [Bug 2 : Erreur SQL lors du drop de clé étrangère dans `zm-backoffice`](#bug-2--erreur-sql-lors-du-drop-de-clé-étrangère-dans-zm-backoffice)
  - [Bug 3 : Erreur d'unicité `1062 Duplicate entry` au reset](#bug-3--erreur-dunicité-1062-duplicate-entry-au-reset)

---

## 🏗️ 1. Architecture & Dépendances du BackOffice

L'application `MonarcAppBO` gère la base de connaissances commune (actifs, menaces, vulnérabilités) et s'appuie sur 4 modules situés dans le répertoire parent :
- **`../zm-core`** ➔ Core Backend PHP (`module/Monarc/Core`)
- **`../zm-backoffice`** ➔ BackOffice Backend PHP (`module/Monarc/BackOffice`)
- **`../ng-anr`** ➔ Frontend Angular ANR (`node_modules/ng_anr`)
- **`../ng-backoffice`** ➔ Frontend Angular BackOffice (`node_modules/ng_backoffice`)

Bases de données associées :
- **`monarc_master`** : Données d'administration du BackOffice (gestion des clients, utilisateurs maîtres, abonnements).
- **`monarc_common`** : Référentiels communs partagés.

---

## 🛠️ 2. Configuration & Points d'Intégration Clés

### A. Configuration Environnement (`.env`)
Dans `MonarcAppBO/.env` :
```ini
DBPASSWORD_ADMIN=root
DBNAME_COMMON=monarc_common
DBNAME_MASTER=monarc_master
DBUSER_MONARC=sqlmonarcuser
DBPASSWORD_MONARC=sqlmonarcuser
BODB_HOST_PORT=3308
MONARC_NETWORK_NAME=monarc-network
```

### B. Montage des Dépôts Locaux (`docker-compose.dev.yml`)
```yaml
    volumes:
      - ./:/var/www/html/monarc
      - type: bind
        source: ../zm-core
        target: /var/www/html/zm-core
      - type: bind
        source: ../zm-backoffice
        target: /var/www/html/zm-backoffice
      - type: bind
        source: ../ng-anr
        target: /var/www/html/ng-anr
      - type: bind
        source: ../ng-backoffice
        target: /var/www/html/ng-backoffice
      - vendor_data:/var/www/html/monarc/vendor
      - node_modules_data:/var/www/html/monarc/node_modules
```

### C. Liens Symboliques Dynamiques (`docker-entrypoint.sh`)
```bash
    mkdir -p module/Monarc
    cd module/Monarc
    ln -sfn /var/www/html/zm-core Core
    ln -sfn /var/www/html/zm-backoffice BackOffice
    cd /var/www/html/monarc
```

---

## 🚀 3. Procédure Automatisée de Démarrage (PowerShell)

Exécutez ce script pour initialiser et lancer le BackOffice de manière 100% propre :

```powershell
# 1. Se positionner dans le dossier MonarcAppBO
cd d:\QSIN\Monarc\Draft\v_current\MonarcAppBO

# 2. Copier le fichier d'environnement .env s'il n'existe pas
if (-not (Test-Path ".env")) { Copy-Item ".env.dev" ".env" }

# 3. Assurer la conversion des scripts .sh au format UNIX (LF)
Get-ChildItem -Path "." -Recurse -Filter "*.sh" | Where-Object { $_.FullName -notmatch '\\(node_modules|vendor|\.git)\\' } | ForEach-Object {
    $content = [System.IO.File]::ReadAllText($_.FullName) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($_.FullName, $content, (New-Object System.Text.UTF8Encoding($false)))
}

# 4. Pré-créer les répertoires de données requis
New-Item -ItemType Directory -Path "data\cache", "data\logs", "data\import\files", "data\LazyServices\Proxy", "data\DoctrineORMModule\Proxy" -Force | Out-Null

# 5. Réinitialiser et purger les anciens volumes (si réinitialisation souhaitée)
docker compose -f docker-compose.dev.yml down -v
Remove-Item -Recurse -Force .\docker\db_data\* -ErrorAction SilentlyContinue
Remove-Item -Force ".\.docker-initialized" -ErrorAction SilentlyContinue

# 6. Construire et démarrer le conteneur
docker compose -f docker-compose.dev.yml up -d --build
```

---

## 🌐 4. Accès & Identifiants Administrateur

- **URL BackOffice :** [http://localhost:5002](http://localhost:5002)
- **Identifiant / Email :** `admin@admin.localhost`
- **Mot de passe :** `admin`

---

## ⚠️ 5. Guide de Dépannage & Correctifs Historiques

### Bug 1 : Fins de ligne Windows (`/bin/sh^M: bad interpreter` sur `10-dev-grants.sh`)
* **Cause :** L'image MariaDB exécute les scripts montés dans `/docker-entrypoint-initdb.d/`. Si `10-dev-grants.sh` est au format CRLF, le conteneur `bodb` crashe dès le démarrage.
* **Correction :** Conversion des scripts `.sh` en format UNIX (`LF`).

### Bug 2 : Erreur SQL lors du drop de clé étrangère dans `zm-backoffice`
* **Cause :** La migration `20230901112005` exécutait `ALTER TABLE clients DROP COLUMN model_id, DROP FOREIGN KEY clients_ibfk_2;`, qui plantait si la clé n'existait pas sous ce nom exact.
* **Correction :** Sécurisation avec bloc `try/catch` et vérification préalable `hasColumn('model_id')`.

### Bug 3 : Erreur d'unicité `1062 Duplicate entry` au reset
* **Solution :** Supprimer le fichier marqueur `.docker-initialized` et purger `docker/db_data/` avant de relancer.
