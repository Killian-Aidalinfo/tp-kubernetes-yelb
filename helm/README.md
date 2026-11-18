# TP 3 : packager Yelb avec Helm

Les manifestes des TP 1 et 2 (à la racine du dépôt) deviennent un chart Helm, `helm/yelb`. **Ce chart est déjà prêt** : pour l'installer, passez directement à la [section 5](#5-vérifier-le-chart-avant-dinstaller). Le même chart sert à installer deux environnements, **dev** et **prod**, qui ne diffèrent que par leurs valeurs.

## Sommaire

1. [Prérequis](#1-prérequis)
   - [Sur k3s : donner à Helm l'accès au cluster](#sur-k3s--donner-à-helm-laccès-au-cluster)
2. [Créer le chart](#2-créer-le-chart)
3. [Structure du chart](#3-structure-du-chart)
4. [Paramètres (values.yaml)](#4-paramètres-valuesyaml)
5. [Vérifier le chart avant d'installer](#5-vérifier-le-chart-avant-dinstaller)
6. [Installer une release dev et une release prod](#6-installer-une-release-dev-et-une-release-prod)
7. [Inspecter une release](#7-inspecter-une-release)
8. [Upgrade](#8-upgrade)
9. [Rollback](#9-rollback)
10. [Bonus : helm test](#10-bonus--helm-test)
11. [Dépannage](#11-dépannage)
12. [Tout supprimer](#12-tout-supprimer)

---

## 1. Prérequis

- Tout ce qu'il fallait pour le TP 2 : Traefik, cert-manager, les ClusterIssuers `letsencrypt-staging` et `letsencrypt-prod` (voir le [README principal](../README.md), sections 1 à 4).
- **Helm 3 ou 4** :

  ```bash
  helm version
  # Installation : https://helm.sh/docs/intro/install/
  # macOS : brew install helm
  ```

- **Deux noms DNS** qui pointent vers Traefik, un par environnement. Par défaut :
  - dev : `dev.killian-stein-3.lab-cesi.fr`
  - prod : `demo.killian-stein-3.lab-cesi.fr`

- **Helm doit pouvoir joindre le cluster.** Sur k3s, ce n'est pas le cas par défaut : voir juste en dessous.

- **Supprimer le déploiement du TP 2** s'il tourne encore : deux Ingress avec le même nom d'hôte entreraient en conflit chez Traefik.

  ```bash
  kubectl delete namespace yelb --ignore-not-found
  ```

### Sur k3s : donner à Helm l'accès au cluster

**Symptôme :** `sudo kubectl` fonctionne, mais Helm ne trouve pas le cluster.

```
$ sudo kubectl get ns
NAME              STATUS   AGE
cert-manager      Active   109m
...
$ helm list --all-namespaces
Error: kubernetes cluster unreachable: Get "http://localhost:8080/version": dial tcp 127.0.0.1:8080: connect: connection refused
```

**Pourquoi :**

- k3s écrit le fichier de connexion au cluster, le *kubeconfig*, dans `/etc/rancher/k3s/k3s.yaml`. Ce fichier contient l'accès administrateur au cluster, il n'est donc lisible que par root.
- Sur k3s, `kubectl` est un lien vers le binaire `k3s`, qui lit ce fichier par défaut. Il marche donc avec `sudo`.
- Helm, comme le `kubectl` standard, ne connaît pas ce chemin. Il cherche la variable `KUBECONFIG`, puis `~/.kube/config`. Il ne trouve rien et se rabat sur sa valeur par défaut, `http://localhost:8080`, où rien n'écoute : d'où le `connection refused`.
- `sudo helm` ne règle rien : root n'a pas de `~/.kube/config` non plus.

**Solution (recommandée) :** copier le kubeconfig dans son dossier personnel, à son nom, et le désigner avec `KUBECONFIG`.

```bash
mkdir -p ~/.kube
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown "$(id -u):$(id -g)" ~/.kube/config
chmod 600 ~/.kube/config

# Indiquer ce fichier à kubectl et Helm, pour cette session et les suivantes
echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.bashrc
source ~/.bashrc

# Vérifier, sans sudo
kubectl get nodes
helm list -A
```

`kubectl` marche alors aussi sans `sudo`. L'`export KUBECONFIG` est nécessaire : sans lui, le `kubectl` de k3s essaie toujours de lire `/etc/rancher/k3s/k3s.yaml` et répond `permission denied`.

> Ce fichier donne un accès administrateur complet au cluster : gardez-le en `chmod 600` et ne le partagez pas. Si k3s est réinstallé, ses certificats changent : il faut refaire la copie.

**Autres possibilités :**

```bash
# Ponctuellement, sans copie (en root : le cache de Helm sera créé dans /root)
sudo helm list -A --kubeconfig /etc/rancher/k3s/k3s.yaml

# À l'installation de k3s, rendre le fichier lisible par tous : déconseillé,
# car tout utilisateur de la machine devient administrateur du cluster
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 644
```

**Vérifier quel cluster Helm et kubectl utilisent :**

```bash
echo $KUBECONFIG
kubectl config current-context        # « default » sur k3s
kubectl config view --minify          # serveur : https://127.0.0.1:6443
```

---

## 2. Créer le chart

> ⚠️ **Ne lancez jamais `helm create yelb` dans le dossier `helm/` du dépôt.** Le chart `helm/yelb` existe déjà, et `helm create` écrase sans demander `Chart.yaml`, `values.yaml`, `_helpers.tpl` et `ingress.yaml`, puis ajoute les templates nginx d'exemple. L'installation échoue ensuite avec des erreurs comme :
>
> ```
> warning: destination for yelb.ingress.tls is a table. Ignoring non-table value ([])
> Error: INSTALLATION FAILED: … no template "yelb.componentName" associated with template "gotpl"
> ```
>
> Pour réparer, voir [Restaurer le chart](#restaurer-le-chart-après-un-helm-create-de-trop).

### Comment le chart du dépôt a été créé

Le point de départ a été généré avec `helm create yelb`, qui produit un chart d'exemple (nginx). On a ensuite :

1. supprimé ses templates `deployment.yaml`, `service.yaml`, `ingress.yaml`, `hpa.yaml`, `httproute.yaml`, `serviceaccount.yaml` et `tests/test-connection.yaml` ;
2. écrit un template par composant de Yelb à partir des manifestes des TP 1 et 2 ;
3. adapté `_helpers.tpl`, `NOTES.txt`, `Chart.yaml` et `values.yaml`.

### Refaire l'exercice soi-même

On travaille dans un **autre dossier**, hors du dépôt, sous un autre nom :

```bash
cd ~
helm create mon-yelb
rm mon-yelb/templates/*.yaml mon-yelb/templates/tests/*.yaml
cp ~/tp-kubernetes-yelb/[1-5]*.yaml mon-yelb/templates/
# puis paramétrer les templates avec {{ .Values.… }} et remplir mon-yelb/values.yaml
helm lint mon-yelb
```

Le chart `helm/yelb` du dépôt sert alors de correction.

### Restaurer le chart après un `helm create` de trop

Git permet de revenir à la version du dépôt :

```bash
cd ~/tp-kubernetes-yelb
git status helm/                       # fichiers modifiés (M) et ajoutés (??) par helm create
git restore helm/yelb                  # remet les fichiers modifiés
git clean -fd helm/yelb                # supprime les fichiers ajoutés
git status helm/                       # plus rien à signaler
helm lint ./helm/yelb -f helm/yelb/values-prod.yaml
```

Si une installation a échoué entre-temps, on la supprime avant de recommencer :

```bash
helm list -A --all                     # une release en « failed » ?
helm uninstall prod -n yelb-prod
```

---

## 3. Structure du chart

```
helm/yelb/
├── Chart.yaml              # nom, version du chart, version de l'appli
├── values.yaml             # valeurs par défaut (tous les paramètres)
├── values-dev.yaml         # surcharges pour dev
├── values-prod.yaml        # surcharges pour prod
├── .helmignore
└── templates/
    ├── _helpers.tpl        # noms et labels communs
    ├── db.yaml             # Secret, PVC (optionnel), Deployment, Service PostgreSQL
    ├── redis.yaml          # Deployment, Service Redis
    ├── appserver.yaml      # ConfigMap, Deployment, Service de l'API
    ├── ui.yaml             # ConfigMap, Deployment, Service du front
    ├── ingress.yaml        # Ingress HTTPS + redirection HTTP (Middleware Traefik)
    ├── NOTES.txt           # message affiché après install / upgrade
    └── tests/
        └── test-app.yaml   # pod lancé par « helm test »
```

### Ce qui change par rapport aux manifestes bruts

| Manifestes (TP 1-2) | Chart (TP 3) |
|---|---|
| Namespace créé par `00-namespace.yaml` | Namespace choisi à l'installation : `-n yelb-dev --create-namespace` |
| Noms fixes : `yelb-db`, `yelb-ui`… | Noms préfixés par la release : `dev-yelb-db`, `prod-yelb-db`… Deux releases peuvent donc cohabiter |
| L'API trouve la base par le nom imposé `yelb-db` | La ConfigMap de l'API reçoit les noms préfixés (`RACK_ENV=custom`) |
| Valeurs écrites en dur | Images, tags, replicas, hôte, émetteur, volume… dans `values.yaml` |
| Modifier une ConfigMap ne redémarre pas les pods | Annotation `checksum/config` : les pods sont recréés quand leur ConfigMap change |

Voir le YAML final produit par le chart :

```bash
helm template dev ./helm/yelb -n yelb-dev -f helm/yelb/values-dev.yaml
```

---

## 4. Paramètres (values.yaml)

| Paramètre | Défaut | Dev | Prod | Rôle |
|---|---|---|---|---|
| `ui.image.repository` / `ui.image.tag` | `mreferre/yelb-ui` / `0.10` | | | Image du front |
| `ui.replicaCount` | `2` | `1` | `2` | Replicas du front |
| `appserver.image.repository` / `appserver.image.tag` | `mreferre/yelb-appserver` / `0.7` | | | Image de l'API |
| `appserver.replicaCount` | `2` | `1` | `3` | Replicas de l'API |
| `db.image.repository` / `db.image.tag` | `mreferre/yelb-db` / `0.6` | | | Image de la base |
| `db.password` | `postgres_password` | | | Mot de passe (imposé par l'API, ne pas changer) |
| `db.existingSecret` | `""` | | | Secret existant (clé `POSTGRES_PASSWORD`) à utiliser à la place de celui du chart. Utilisé par Argo CD au TP 4 |
| `db.persistence.enabled` | `true` | `false` | `true` | PVC, ou `emptyDir` si `false` |
| `db.persistence.size` | `1Gi` | | `2Gi` | Taille du volume |
| `db.persistence.storageClass` | `""` | | | StorageClass (vide = celle par défaut) |
| `redis.image.repository` / `redis.image.tag` | `redis` / `7.4-alpine` | | | Image de Redis |
| `ingress.enabled` | `true` | | | Créer l'Ingress |
| `ingress.className` | `traefik` | | | IngressClass |
| `ingress.host` | `demo.killian-stein-3.lab-cesi.fr` | `dev.…` | `demo.…` | Nom d'hôte |
| `ingress.tls.enabled` | `true` | | | HTTPS (sinon HTTP seul) |
| `ingress.tls.clusterIssuer` | `letsencrypt-staging` | staging | `letsencrypt-prod` | Émetteur cert-manager |
| `ingress.httpsRedirect` | `true` | | | Redirection HTTP → HTTPS |
| `*.resources` | voir le fichier | | | requests / limits de chaque composant |
| `imagePullPolicy` | `IfNotPresent` | | | Politique de téléchargement |

Chaque étudiant met ses propres noms d'hôte dans `values-dev.yaml` et `values-prod.yaml` :

```bash
# Linux (macOS : sed -i '' …)
sed -i 's/killian-stein-3/prenom/' helm/yelb/values.yaml helm/yelb/values-dev.yaml helm/yelb/values-prod.yaml
grep -n "host:" helm/yelb/values*.yaml
```

Lister tous les paramètres d'un chart :

```bash
helm show values ./helm/yelb
helm show chart ./helm/yelb
```

---

## 5. Vérifier le chart avant d'installer

```bash
# Erreurs de syntaxe et bonnes pratiques
helm lint ./helm/yelb -f helm/yelb/values-dev.yaml
helm lint ./helm/yelb -f helm/yelb/values-prod.yaml

# Le YAML généré, sans rien installer
helm template dev ./helm/yelb -n yelb-dev -f helm/yelb/values-dev.yaml

# Un seul fichier du chart
helm template dev ./helm/yelb -f helm/yelb/values-dev.yaml -s templates/ingress.yaml

# Simulation complète, validée par le cluster
helm install dev ./helm/yelb -n yelb-dev --create-namespace -f helm/yelb/values-dev.yaml --dry-run=server
```

---

## 6. Installer une release dev et une release prod

Une **release** est une installation d'un chart, avec un nom et un namespace. On en crée deux à partir du même chart :

```bash
# DEV : 1 replica, pas de volume, certificat de staging
helm install dev ./helm/yelb -n yelb-dev --create-namespace -f helm/yelb/values-dev.yaml --wait

# PROD : 3 API, volume de 2 Gi, vrai certificat
helm install prod ./helm/yelb -n yelb-prod --create-namespace -f helm/yelb/values-prod.yaml --wait
```

`--wait` attend que tous les pods soient prêts avant de rendre la main. À la fin, Helm affiche le contenu de `NOTES.txt` : l'adresse et les commandes utiles.

Vérifier :

```bash
helm list -A
kubectl -n yelb-dev get pods,svc,ingress,certificate
kubectl -n yelb-prod get pods,svc,pvc,ingress,certificate
```

Résultat attendu :

| | dev | prod |
|---|---|---|
| Pods | 4 : 1 front, 1 API, 1 base, 1 Redis | 7 : 2 front, 3 API, 1 base, 1 Redis |
| PVC | aucun | `prod-yelb-db-data` (2 Gi) |
| Certificat | `dev-yelb-tls` (staging) | `prod-yelb-tls` (prod) |
| Adresse | https://dev.killian-stein-3.lab-cesi.fr | https://demo.killian-stein-3.lab-cesi.fr |

Une valeur ponctuelle se passe aussi en ligne de commande, sans modifier de fichier :

```bash
helm install essai ./helm/yelb -n yelb-essai --create-namespace \
  --set ingress.enabled=false --set db.persistence.enabled=false
```

---

## 7. Inspecter une release

```bash
helm status prod -n yelb-prod                  # état et NOTES
helm get values prod -n yelb-prod              # valeurs passées à l'installation
helm get values prod -n yelb-prod --all        # toutes les valeurs, défauts compris
helm get manifest prod -n yelb-prod            # YAML réellement appliqué
helm get notes prod -n yelb-prod
helm history prod -n yelb-prod                 # révisions

# Helm range chaque révision dans un Secret du namespace
kubectl -n yelb-prod get secret -l owner=helm
```

---

## 8. Upgrade

`helm upgrade` applique une nouvelle version du chart ou de nouvelles valeurs, et crée une **nouvelle révision**.

### Upgrade réussi : passer l'API à 4 replicas

```bash
helm upgrade prod ./helm/yelb -n yelb-prod -f helm/yelb/values-prod.yaml \
  --set appserver.replicaCount=4 --wait

kubectl -n yelb-prod get deploy prod-yelb-appserver     # 4/4
helm history prod -n yelb-prod                          # révision 2 : deployed
```

À chaque upgrade, il faut **toujours repasser le fichier de valeurs** (`-f`). Sinon, Helm repart des valeurs par défaut. Option : `--reuse-values` reprend les valeurs de la révision précédente.

Pour une modification durable, mieux vaut changer `values-prod.yaml` puis relancer la même commande sans `--set`.

### Upgrade raté : passer le front en 0.9

Le front 0.9 n'est pas compatible avec ce chart : il ajoute lui-même `:4567` à l'adresse de l'API, et nginx refuse de démarrer.

```bash
helm upgrade prod ./helm/yelb -n yelb-prod -f helm/yelb/values-prod.yaml \
  --set ui.image.tag=0.9 --wait --timeout 2m
# Error: UPGRADE FAILED: … prod-yelb-ui not ready

kubectl -n yelb-prod get pods -l app.kubernetes.io/component=ui
# un pod 0.9 en CrashLoopBackOff, les anciens toujours Running

kubectl -n yelb-prod logs -l app.kubernetes.io/component=ui --tail=5
# nginx: [emerg] invalid port in upstream "http://prod-yelb-appserver:4567:4567/api"

helm history prod -n yelb-prod                # la révision apparaît en « failed »
```

Le site est resté en ligne : avec `maxUnavailable: 0`, Kubernetes n'arrête les anciens pods que lorsque les nouveaux sont prêts.

Avec `--rollback-on-failure` (`--atomic` en Helm 3), Helm annule seul un upgrade raté.

---

## 9. Rollback

```bash
helm history prod -n yelb-prod

# Revenir à la révision précédente
helm rollback prod -n yelb-prod --wait

# Ou à une révision précise
helm rollback prod 1 -n yelb-prod --wait

kubectl -n yelb-prod get pods -l app.kubernetes.io/component=ui      # pods 0.10 seulement
helm history prod -n yelb-prod                                       # « Rollback to 1 »
```

Un rollback ne réécrit pas l'historique : il crée une **nouvelle révision** identique à l'ancienne. L'historique se lit par exemple ainsi : 1 installée, 2 échouée, 3 « Rollback to 1 ».

---

## 10. Bonus : helm test

Le chart contient un test, [`templates/tests/test-app.yaml`](yelb/templates/tests/test-app.yaml). C'est un pod jetable (busybox) qui :

1. appelle `/api/hostname` sur l'API pour vérifier sa santé. Yelb n'a pas d'endpoint `/healthz` : `/api/hostname` en tient lieu ;
2. appelle `/api/getvotes` **à travers le front**, ce qui vérifie toute la chaîne front → API → PostgreSQL.

Le pod porte l'annotation `helm.sh/hook: test` : il n'est créé que par `helm test`, jamais par `install` ou `upgrade`.

```bash
helm test dev -n yelb-dev --logs
helm test prod -n yelb-prod --logs
```

Sortie attendue :

```
Phase:          Succeeded
POD LOGS: prod-yelb-test (test)
1/2 Santé de l'API : http://prod-yelb-appserver:4567/api/hostname
prod-yelb-appserver-55cf8874b6-f5vqt
2/2 Chaîne complète front -> API -> base : http://prod-yelb-ui/api/getvotes
OK
```

Vérifier que le test détecte une panne :

```bash
kubectl -n yelb-dev scale deploy/dev-yelb-appserver --replicas=0
kubectl -n yelb-dev wait --for=delete pod -l app.kubernetes.io/component=appserver --timeout=90s
helm test dev -n yelb-dev --logs
# Phase: Failed — wget: can't connect to remote host … Connection refused

kubectl -n yelb-dev scale deploy/dev-yelb-appserver --replicas=1
```

Le `wait --for=delete` compte : tant qu'un ancien pod est en cours d'arrêt, il peut encore répondre et faire passer le test.

Le pod de test est conservé après exécution, pour qu'on puisse relire ses logs :

```bash
kubectl -n yelb-dev logs dev-yelb-test
```

---

## 11. Dépannage

| Symptôme | Commande | Cause probable |
|---|---|---|
| `kubernetes cluster unreachable: Get "http://localhost:8080/version"` | `echo $KUBECONFIG` et `ls -l ~/.kube/config` | Helm ne trouve pas de kubeconfig (cas de k3s) : voir [Sur k3s : donner à Helm l'accès au cluster](#sur-k3s--donner-à-helm-laccès-au-cluster) |
| `error loading config file … permission denied` | `ls -l ~/.kube/config /etc/rancher/k3s/k3s.yaml` | Le fichier appartient à root : refaire le `chown` |
| `no template "yelb.componentName"`, `yelb.ingress.tls is a table`, `nil pointer evaluating … .image` | `git status helm/` | `helm create` relancé sur le chart du dépôt : voir [Restaurer le chart](#restaurer-le-chart-après-un-helm-create-de-trop) |
| `INSTALLATION FAILED: cannot re-use a name that is still in use` | `helm list -A` | Release déjà installée : utiliser `helm upgrade --install` |
| `UPGRADE FAILED: another operation is in progress` | `helm history <release> -n <ns>` | Opération précédente interrompue : `helm rollback` vers la dernière révision `deployed` |
| `no matches for kind "Middleware"` | `kubectl get crd middlewares.traefik.io` | CRD Traefik absentes : `--set ingress.httpsRedirect=false` |
| `no matches for kind "ClusterIssuer"` ou certificat jamais créé | `kubectl get clusterissuer` | cert-manager ou les ClusterIssuers ne sont pas installés |
| 404 ou mauvais site sur le domaine | `kubectl get ingress -A` | Le même hôte est déclaré dans deux Ingress (TP 2 encore déployé ?) |
| Erreur de template | `helm template … --debug` | Indentation ou valeur manquante dans un template |
| `helm test` en échec | `kubectl -n <ns> logs <release>-yelb-test` | Le log indique quelle étape (1/2 ou 2/2) a échoué |

`helm upgrade --install` installe la release si elle n'existe pas et la met à jour sinon. C'est la commande à utiliser dans un pipeline CI/CD :

```bash
helm upgrade --install prod ./helm/yelb -n yelb-prod --create-namespace -f helm/yelb/values-prod.yaml --wait
```

---

## 12. Tout supprimer

```bash
helm uninstall dev -n yelb-dev
helm uninstall prod -n yelb-prod      # supprime aussi le PVC et donc les votes

kubectl delete namespace yelb-dev yelb-prod
```
