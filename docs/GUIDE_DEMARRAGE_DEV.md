# Démarrage en développement — Back-Office

Environnement de **développement** du Back-Office sur un poste Windows avec Docker Desktop. Le code des modules est monté dans le conteneur : une modification est visible au rafraîchissement du navigateur.

Pour faire tourner le Front-Office avec ce Back-Office (mode `USE_BO_COMMON=1`, comme en production), suivre ensuite `MonarcAppFO/docs/GUIDE_DEMARRAGE_DEV.md`, mode B. Pour le test et la production, voir le dépôt `monarc-deploy`.

---

## 1. Prérequis

- Docker Desktop (moteur Linux) et Git Bash.
- Les dépôts clonés côte à côte dans le même dossier (ici `v_current/`) : `MonarcAppBO`, `zm-core`, `zm-backoffice`, `ng-backoffice`, `ng-anr`. Le compose de dev les monte depuis `../`.
- Scripts `.sh` en fins de ligne **LF** (imposé par `.gitattributes`).

---

## 2. Préparation (une seule fois)

```bash
docker network create monarc-network        # ignorer l'erreur s'il existe déjà
cd /d/QSIN/Monarc/Draft/v_current/MonarcAppBO
[ -f .env ] || cp .env.dev .env
```

Le compose de dev ne transmet pas les variables SMTP au conteneur. Pour tester l'envoi de courriels, les déclarer dans un `docker-compose.override.yml` local (non versionné), par exemple vers le MailCatcher du FO s'il tourne :

```yaml
services:
  monarcboapp:
    environment:
      SMTP_HOST: mailcatcher
      SMTP_PORT: 1025
      EMAIL_FROM: monarc@localhost
```

et démarrer avec `docker compose -f docker-compose.dev.yml -f docker-compose.override.yml up -d`.

---

## 3. Démarrer

```bash
cd /d/QSIN/Monarc/Draft/v_current/MonarcAppBO
docker compose -f docker-compose.dev.yml up -d --build
docker logs -f monarc-bo-app
```

(Ajouter `-f docker-compose.override.yml` si tu as créé ce fichier.)

Au premier démarrage, l'entrypoint (mode `APP_ENV=development`) :

1. attend MariaDB ;
2. installe les dépendances (`composer install`) et relie les modules montés ;
3. crée `monarc_master` et `monarc_common` **avec le compte `monarc`** (jamais root) : en dev, ce compte reçoit ses droits du script `docker/db-init/10-dev-grants.sh` à la création de la base ;
4. remplit `monarc_common` si elle est vide ;
5. génère `config/autoload/local.php` ;
6. lance `scripts/update-all.sh` (migrations, ressources front) et crée le compte administrateur.

Attendre `Initialization complete!`, puis ouvrir **http://localhost:5002** et se connecter avec `admin@admin.localhost` / `admin`.

> Une base de dev créée **avant** l'ajout de `DBUSER_MONARC` au conteneur MariaDB n'a pas reçu ces droits. Si le BO s'arrête sur `Database ... does not exist and monarc is not allowed to create it`, repartir de zéro : `docker compose -f docker-compose.dev.yml down -v` puis `up -d`.

---

## 4. Ce qui se passe quand on crée un client

Dans le Back-Office (**Gestion des clients**), la création, la modification ou la suppression d'un client dépose une demande JSON dans `data/json/create`, `update` ou `delete`. Un serveur doit d'abord exister dans **Gestion des serveurs** avec un FQDN non vide, sinon aucune demande n'est déposée.

En développement, **personne ne traite ces demandes** : c'est normal. Sur les serveurs de test et de production, le service de déploiement des entités de `monarc-deploy` les lit et déploie l'entité correspondante.

---

## 5. Au quotidien et arrêt

- Code dans `zm-core`, `zm-backoffice`, `ng-backoffice`, `ng-anr` : monté dans le conteneur, rafraîchir le navigateur.
- Redémarrer : `docker restart monarc-bo-app`. Entrer : `docker exec -it monarc-bo-app bash`.
- Arrêter en gardant les bases : `docker compose -f docker-compose.dev.yml down`. Repartir de zéro : ajouter `-v`.
- MariaDB du BO depuis le poste : `localhost:3306` (`BODB_HOST_PORT` dans `.env`).

**Publier** : un push sur `master-asin` du dépôt MonarcAppBO construit l'image de test `ghcr.io/asinbenin/monarcappbo:master-asin` (la branche `master-asin` doit exister dans ce dépôt). Un tag `v2.14.1-rN` publie l'image de production.
