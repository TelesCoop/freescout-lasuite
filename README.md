# TelesCoop/docker-freescout

Image [FreeScout](https://freescout.net/) qui s'exécute entièrement sans root, pour les clusters Kubernetes qui interdisent les conteneurs root (Pod Security `restricted`).

## Fonctionnement

- Le code de FreeScout, dépendances Composer comprises, est repris de l'image [nfrastack/container-freescout](https://github.com/nfrastack/container-freescout) (argument `FREESCOUT_IMAGE` du `Dockerfile`).
- Il tourne sur un runtime Alpine minimal : nginx sur le port **8080**, php-fpm 8.4, le worker de queue et le scheduler, orchestrés par supervisord.
- Tous les processus tournent sous l'UID/GID **1000**. Les fichiers de configuration appartiennent à root et ne sont pas modifiables par l'application.
- Si un service plante en boucle, le conteneur s'arrête pour que l'orchestrateur le redémarre.
- Les données persistantes sont dans **`/data`** :
  - `.env`, qui contient l'`APP_KEY` ;
  - `storage/` : pièces jointes, sessions, logs ;
  - `modules/`.

## Images

La CI publie l'image sur GHCR après chaque push sur `main`, une fois les tests passés :

```text
ghcr.io/telescoop/docker-freescout:sha-<commit>   # immuable, à utiliser en production
ghcr.io/telescoop/docker-freescout:latest
```

Le package est privé : il faut un token GitHub avec le scope `read:packages` pour le tirer.

## Configuration

| Variable | Requise | Description |
|---|---|---|
| `APP_URL` | oui | URL publique, par exemple `https://freescout.example.org`. Un `https://` active les cookies sécurisés et la redirection HTTPS. |
| `DB_TYPE` | non | `mysql` (par défaut), `mariadb` ou `pgsql`. |
| `DB_HOST`, `DB_NAME`, `DB_USER`, `DB_PASS` | oui | Connexion à la base de données. |
| `DB_PORT` | non | 3306 par défaut, 5432 pour `pgsql`. |
| `ADMIN_EMAIL`, `ADMIN_PASS` | au premier démarrage | Compte admin créé uniquement si la base ne contient aucun utilisateur. |
| `ADMIN_FIRST_NAME`, `ADMIN_LAST_NAME` | non | `Admin` / `User` par défaut. |
| `TIMEZONE` | non | `UTC` par défaut. |
| `APP_KEY` | non | Sans elle, une clé est générée au premier démarrage et conservée dans `/data/.env`. **Ne pas la perdre** : elle chiffre les mots de passe des boîtes mail. |
| `FREESCOUT_<CLÉ>` | non | Écrit `<CLÉ>` dans le `.env` de FreeScout, par exemple `FREESCOUT_MAIL_DRIVER=smtp`. Les valeurs vide, `unset` ou `null` suppriment la clé. |
| `<VARIABLE>_FILE` | non | Lit la valeur de `<VARIABLE>` dans un fichier (secrets Docker/Kubernetes). Le conteneur échoue si le fichier n'existe pas. |

Derrière un reverse proxy, ajouter `FREESCOUT_APP_TRUSTED_PROXIES` (par exemple `*`) pour que FreeScout voie l'IP réelle des clients. Le HTTPS est déjà détecté via `X-Forwarded-Proto`.

Une configuration manquante ou invalide arrête le conteneur avec un message `[entrypoint] ERROR`. Il n'y a pas de valeur de repli silencieuse.

## Démarrage local

```sh
docker compose up --build
```

FreeScout est alors disponible sur http://localhost:8080 (`admin@example.com` / `freescout`).

## Déploiement Kubernetes

Il faut une base MySQL, MariaDB ou PostgreSQL accessible depuis le cluster.

1. Créer le secret qui permet de tirer l'image privée :

   ```sh
   kubectl create secret docker-registry ghcr-telescoop \
       --docker-server=ghcr.io \
       --docker-username=<utilisateur GitHub> \
       --docker-password=<token read:packages>
   ```

2. Créer la configuration et les secrets :

   ```sh
   kubectl create configmap freescout-config \
       --from-literal=APP_URL=https://freescout.example.org \
       --from-literal=DB_TYPE=mariadb \
       --from-literal=DB_HOST=<hôte> \
       --from-literal=DB_NAME=freescout \
       --from-literal=DB_USER=freescout \
       --from-literal=ADMIN_EMAIL=<email admin> \
       --from-literal=FREESCOUT_APP_TRUSTED_PROXIES='*'
   kubectl create secret generic freescout-secrets \
       --from-literal=DB_PASS=<mot de passe> \
       --from-literal=ADMIN_PASS=<mot de passe admin>
   ```

3. Appliquer le manifeste, puis exposer le Service `freescout` (port 80) avec l'Ingress du cluster :

   ```sh
   kubectl apply -f deploy/kubernetes/freescout.yaml
   ```

Ce que fait [`deploy/kubernetes/freescout.yaml`](deploy/kubernetes/freescout.yaml) :

- Son `securityContext` respecte la Pod Security `restricted`.
- `fsGroup: 1000` rend le volume persistant inscriptible.
- Il lance **un seul** replica en stratégie `Recreate`, car le volume est en `ReadWriteOnce` et les migrations tournent au démarrage.
- Les probes envoient `Host: localhost`, parce que FreeScout rejette les hôtes absents de `APP_URL` et `APP_TRUSTED_HOSTS`.

**Mettre à jour :** remplacer le tag `sha-…` dans le manifeste par le nouveau tag publié, puis réappliquer. Les migrations s'exécutent au démarrage.

## Modules FreeScout

Déposer le dossier d'un module (celui qui contient `module.json`) dans `modules/`. Le module est intégré à l'image et enregistré au démarrage avec `freescout:module-install <alias>`.

Les modules intégrés à l'image remplacent leur copie dans `/data/modules` à chaque nouveau conteneur : c'est l'image qui fait foi. Les modules installés depuis l'interface sont conservés.

## Mettre à jour FreeScout

Changer le tag de l'image nfrastack dans l'argument `FREESCOUT_IMAGE` du `Dockerfile`, puis pousser sur `main`. La CI teste l'image et la publie.

## Tests

Le workflow `.github/workflows/build-test.yml` exécute ces tests et ne publie que s'ils passent :

- `tests/e2e.sh <image>` lance l'image avec Docker et MariaDB, en `--cap-drop ALL`. Il vérifie :
  - la connexion admin ;
  - qu'aucun processus ne tourne en root ;
  - qu'après recréation du conteneur, l'`APP_KEY` est conservée et l'admin n'est pas recréé.
- `tests/k8s.sh <image>` déploie le manifeste sans modification dans un cluster [kind](https://kind.sigs.k8s.io/), dans un namespace en Pod Security `restricted`, et attend que le déploiement soit prêt.

## Fichiers hérités

`Containerfile`, `rootfs/`, `build-assets/`, `examples/` et `CHANGELOG.md` viennent du dépôt nfrastack. Ils ne servent pas à construire cette image.

## Licence

MIT. Dérivé de [nfrastack/container-freescout](https://github.com/nfrastack/container-freescout) (voir [LICENSE](LICENSE)).
