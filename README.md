# TP Kubernetes : Yelb (web + API + PostgreSQL)

Yelb est une petite appli de vote « où manger ce midi ». Elle compte quatre composants, tous en images publiques :

| Composant | Image | Port | Service | Exposition |
|---|---|---|---|---|
| Interface web (Angular + nginx) | `mreferre/yelb-ui:0.10` | 80 | `yelb-ui` | ClusterIP + **Ingress Traefik (HTTPS)** |
| API (Ruby / Sinatra) | `mreferre/yelb-appserver:0.7` | 4567 | `yelb-appserver` | ClusterIP |
| Base PostgreSQL 10 | `mreferre/yelb-db:0.6` | 5432 | `yelb-db` | ClusterIP + PVC 1 Gi |
| Cache Redis | `redis:7.4-alpine` | 6379 | `redis-server` | ClusterIP |

```
navigateur ──HTTPS──► Traefik (Ingress) ──► yelb-ui ──/api──► yelb-appserver ──► yelb-db (PVC)
                                                                         └──────► redis-server
```

## Sommaire

0. [Contenu du dépôt](#0-contenu-du-dépôt)
1. [Prérequis et vérifications](#1-prérequis-et-vérifications)
2. [Récupérer le dépôt et mettre son nom de domaine](#2-récupérer-le-dépôt-et-mettre-son-nom-de-domaine)
3. [Installer cert-manager](#3-installer-cert-manager)
4. [Créer les ClusterIssuers Let's Encrypt](#4-créer-les-clusterissuers-lets-encrypt)
5. [Déployer l'appli](#5-déployer-lappli)
6. [Vérifier chaque composant](#6-vérifier-chaque-composant)
7. [HTTPS : staging puis production](#7-https--staging-puis-production)
8. [Bonus : suivre la demande de certificat pas à pas](#8-bonus--suivre-la-demande-de-certificat-pas-à-pas)
9. [Opérations courantes](#9-opérations-courantes)
10. [Dépannage](#10-dépannage)
11. [Tout supprimer](#11-tout-supprimer)
12. [Bonnes pratiques appliquées](#12-bonnes-pratiques-appliquées)
13. [Limites connues de l'appli](#13-limites-connues-de-lappli)
14. [Idées d'exercices](#14-idées-dexercices)
15. [TP 3 : packager l'appli avec Helm](#15-tp-3--packager-lappli-avec-helm)

---

## 0. Contenu du dépôt

| Fichier | Contenu |
|---|---|
| `00-namespace.yaml` | Namespace `yelb` |
| `10-db.yaml` | Secret, PersistentVolumeClaim, Deployment et Service de PostgreSQL |
| `20-redis.yaml` | Deployment et Service de Redis |
| `30-appserver.yaml` | ConfigMap, Deployment et Service de l'API |
| `40-ui.yaml` | ConfigMap, Deployment et Service ClusterIP du front |
| `50-ingress.yaml` | Ingress HTTPS : entrée `websecure`, bloc `tls`, annotation cert-manager |
| `51-ingress-http-redirect.yaml` | Middleware Traefik et Ingress HTTP qui redirigent vers HTTPS |
| `kustomization.yaml` | Liste des fichiers de l'appli, pour `kubectl apply -k .` |
| `helm/` | TP 3 : chart Helm de l'appli et son guide ([helm/README.md](helm/README.md)) |
| `cert-manager/cluster-issuers.yaml` | ClusterIssuers `letsencrypt-staging` et `letsencrypt-prod`. Hors kustomization, car ils concernent tout le cluster |

---

## 1. Prérequis et vérifications

Il faut :

- un cluster Kubernetes et `kubectl` configuré dessus ;
- un contrôleur Ingress **Traefik** avec l'IngressClass `traefik` (présent par défaut sur k3s) ;
- des nœuds **amd64** : les images Yelb n'existent pas pour ARM ;
- une **StorageClass par défaut**, pour le PVC de la base ;
- un enregistrement **DNS** qui pointe vers l'IP publique de Traefik ;
- les ports **80 et 443** ouverts vers Traefik. Le port 80 sert aussi à la validation Let's Encrypt.

Commandes pour tout vérifier :

```bash
# Accès au cluster
kubectl version
kubectl get nodes -o wide

# Architecture des nœuds : doit afficher amd64
kubectl get nodes -L kubernetes.io/arch

# IngressClass traefik présente
kubectl get ingressclass

# IP publique de Traefik (colonne EXTERNAL-IP)
# Sur k3s, Traefik est dans kube-system ; installé par Helm, souvent dans traefik.
kubectl get svc -A | grep -i traefik

# CRD Traefik présentes (nécessaires pour le Middleware de redirection)
kubectl get crd middlewares.traefik.io

# StorageClass par défaut : marquée « (default) »
kubectl get storageclass

# Le DNS pointe-t-il vers l'IP de Traefik ?
dig +short demo.prenom.lab-cesi.fr
# ou, sans dig :
nslookup demo.prenom.lab-cesi.fr
```

---

## 2. Récupérer le dépôt et mettre son nom de domaine

```bash
git clone https://github.com/Killian-Aidalinfo/tp-kubernetes-yelb.git
cd tp-kubernetes-yelb
```

Le nom de domaine `demo.killian-stein-3.lab-cesi.fr` apparaît **trois fois** : deux `host:` et le bloc `tls`, répartis dans `50-ingress.yaml` et `51-ingress-http-redirect.yaml`. On le remplace par le sien en une commande :

```bash
# Linux
sed -i 's/demo.killian-stein-3.lab-cesi.fr/demo.prenom.lab-cesi.fr/g' 50-ingress.yaml 51-ingress-http-redirect.yaml

# macOS
sed -i '' 's/demo.killian-stein-3.lab-cesi.fr/demo.prenom.lab-cesi.fr/g' 50-ingress.yaml 51-ingress-http-redirect.yaml

# Vérifier : les 3 lignes doivent montrer votre domaine
grep -n "lab-cesi.fr" 50-ingress.yaml 51-ingress-http-redirect.yaml
```

Avant d'appliquer, on peut valider les manifestes sans rien créer :

```bash
kubectl kustomize .                              # affiche le YAML final assemblé
kubectl apply -k . --dry-run=client              # validation locale
```

---

## 3. Installer cert-manager

À faire une seule fois par cluster.

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.3/cert-manager.yaml

# Attendre que les 3 composants soient prêts
kubectl -n cert-manager wait --for=condition=Available deploy --all --timeout=300s

# Vérifier
kubectl -n cert-manager get pods            # cert-manager, cainjector, webhook : Running
kubectl get crd | grep cert-manager.io      # Certificate, Issuer, ClusterIssuer, Order, Challenge…
```

---

## 4. Créer les ClusterIssuers Let's Encrypt

```bash
kubectl apply -f cert-manager/cluster-issuers.yaml

kubectl get clusterissuer                   # les deux doivent être READY=True
kubectl describe clusterissuer letsencrypt-staging
```

`READY=True` signifie que cert-manager a ouvert un compte chez Let's Encrypt. La clé de ce compte est rangée dans un Secret du namespace `cert-manager` :

```bash
kubectl -n cert-manager get secret | grep letsencrypt
```

| Émetteur | Usage |
|---|---|
| `letsencrypt-staging` | Tests. Quotas larges, mais certificat non reconnu par les navigateurs |
| `letsencrypt-prod` | Vrai certificat (le cadenas). Quotas stricts : 5 certificats identiques par semaine |

---

## 5. Déployer l'appli

```bash
kubectl apply -k .
```

`kubectl apply -f .` fonctionne aussi : les fichiers sont appliqués dans l'ordre des numéros.

Suivre le démarrage :

```bash
# Les pods en direct (Ctrl+C pour quitter)
kubectl -n yelb get pods -w

# Attendre que tous les Deployments soient disponibles
kubectl -n yelb wait --for=condition=Available deploy --all --timeout=300s

# Ou Deployment par Deployment
kubectl -n yelb rollout status deploy/yelb-db
kubectl -n yelb rollout status deploy/yelb-appserver

# Vue d'ensemble
kubectl -n yelb get deploy,pods,svc,pvc,ingress,certificate
```

Résultat attendu :

- 6 pods `Running` et `1/1` : 1 base, 1 Redis, 2 API, 2 front ;
- le PVC `yelb-db-data` à l'état `Bound` ;
- les Ingress `yelb` (ports 80 et 443) et `yelb-http-redirect` (port 80) ;
- le Certificate `yelb-tls`, qui passe à `READY=True` après une à deux minutes.

---

## 6. Vérifier chaque composant

### Services et endpoints

Un Service sans endpoint signifie qu'aucun pod n'est prêt : readinessProbe en échec, ou labels qui ne correspondent pas.

```bash
kubectl -n yelb get svc
kubectl -n yelb get endpointslices
# Pour un seul Service :
kubectl -n yelb get endpointslices -l kubernetes.io/service-name=yelb-appserver
```

`kubectl get endpoints` fonctionne encore, mais l'objet Endpoints est déprécié depuis Kubernetes 1.33 au profit des EndpointSlices.

### Base PostgreSQL

```bash
kubectl -n yelb logs deploy/yelb-db

# Prête à accepter des connexions ?
kubectl -n yelb exec deploy/yelb-db -- pg_isready -U postgres

# Le contenu de la table des votes
kubectl -n yelb exec deploy/yelb-db -- psql -U postgres -d yelbdatabase -c "SELECT * FROM restaurants;"

# Le volume monté
kubectl -n yelb get pvc yelb-db-data
kubectl -n yelb exec deploy/yelb-db -- df -h /var/lib/postgresql/data
```

### Redis

```bash
kubectl -n yelb exec deploy/redis-server -- redis-cli ping           # PONG
kubectl -n yelb exec deploy/redis-server -- redis-cli get pageviews  # nombre de pages vues
```

### API

```bash
kubectl -n yelb logs deploy/yelb-appserver
kubectl -n yelb logs -l app.kubernetes.io/name=yelb-appserver --prefix   # les logs de tous les pods

# Appeler l'API en direct, sans passer par l'Ingress
kubectl -n yelb port-forward svc/yelb-appserver 4567:4567
# Dans un autre terminal :
curl localhost:4567/api/hostname     # nom du pod qui répond
curl localhost:4567/api/getvotes     # votes (lus dans PostgreSQL)
curl localhost:4567/api/pageviews    # pages vues (Redis)
```

Endpoints disponibles : `/api/hostname`, `/api/getvotes`, `/api/pageviews`, `/api/getstats`, et un vote par restaurant : `/api/outback`, `/api/bucadibeppo`, `/api/chipotle`, `/api/ihop`.

### Front

```bash
kubectl -n yelb logs deploy/yelb-ui
kubectl -n yelb port-forward svc/yelb-ui 8080:80
# Puis ouvrir http://localhost:8080
```

### Résolution DNS interne

On lance un pod jetable pour tester les noms des Services depuis l'intérieur du cluster :

```bash
kubectl -n yelb run test-dns --rm -it --image=busybox:1.37 --restart=Never -- nslookup yelb-db
# Nom complet : yelb-db.yelb.svc.cluster.local
```

---

## 7. HTTPS : staging puis production

### 7.1 Staging

L'Ingress est livré avec `cert-manager.io/cluster-issuer: letsencrypt-staging`.

```bash
kubectl -n yelb get certificate -w          # attendre READY=True
```

Le site répond sur <https://demo.prenom.lab-cesi.fr>, avec une **alerte du navigateur**. C'est normal : le certificat de staging est signé par une fausse autorité. On vérifie l'émetteur :

```bash
curl -vk https://demo.prenom.lab-cesi.fr 2>&1 | grep -i issuer      # « (STAGING) … »

# ou avec openssl
echo | openssl s_client -connect demo.prenom.lab-cesi.fr:443 -servername demo.prenom.lab-cesi.fr 2>/dev/null \
  | openssl x509 -noout -issuer -subject -dates
```

La redirection HTTP vers HTTPS :

```bash
curl -I http://demo.prenom.lab-cesi.fr      # 301, Location: https://…
```

### 7.2 Production : le vrai cadenas

On ne passe en production qu'une fois le staging validé.

```bash
# Linux
sed -i 's/letsencrypt-staging/letsencrypt-prod/' 50-ingress.yaml
# macOS
sed -i '' 's/letsencrypt-staging/letsencrypt-prod/' 50-ingress.yaml

kubectl apply -k .
kubectl -n yelb get certificate -w          # repasse par READY=False, puis True
```

cert-manager voit que le certificat vient d'un autre émetteur et en redemande un. Si l'ancien reste servi, on supprime le Secret pour forcer une nouvelle émission :

```bash
kubectl -n yelb delete secret yelb-tls
```

Vérification : le navigateur affiche le cadenas, et l'émetteur est désormais Let's Encrypt (R10, R11, E5…) sans la mention STAGING :

```bash
curl -v https://demo.prenom.lab-cesi.fr 2>&1 | grep -iE "issuer|SSL certificate verify"
```

### 7.3 Tester sans DNS

On peut forcer la résolution du nom vers l'IP de Traefik. Le certificat Let's Encrypt, lui, ne sera pas émis sans un vrai DNS.

```bash
curl -k --resolve demo.prenom.lab-cesi.fr:443:<IP de Traefik> https://demo.prenom.lab-cesi.fr/api/getvotes
curl -H "Host: demo.prenom.lab-cesi.fr" -I http://<IP de Traefik>/
```

---

## 8. Bonus : suivre la demande de certificat pas à pas

cert-manager crée une chaîne d'objets, à inspecter dans l'ordre :

```
Ingress (annotation) ─► Certificate ─► CertificateRequest ─► Order ─► Challenge ─► Secret yelb-tls
```

```bash
# Tout d'un coup, en direct
kubectl -n yelb get certificate,certificaterequest,order,challenge -w

# 1. Certificate : état global et événements
kubectl -n yelb describe certificate yelb-tls

# 2. CertificateRequest : la demande de signature (CSR)
kubectl -n yelb get certificaterequest
kubectl -n yelb describe certificaterequest

# 3. Order : la commande ACME chez Let's Encrypt
kubectl -n yelb get order
kubectl -n yelb describe order

# 4. Challenge : le défi HTTP-01, la partie qui coince en général
kubectl -n yelb get challenge
kubectl -n yelb describe challenge

# Pendant le défi, cert-manager crée un Ingress temporaire cm-acme-http-solver-xxxxx
kubectl -n yelb get ingress

# 5. Le Secret final
kubectl -n yelb get secret yelb-tls
kubectl -n yelb get secret yelb-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -issuer -subject -dates

# En dernier recours : les logs de cert-manager
kubectl -n cert-manager logs deploy/cert-manager --tail=100

# Tous les événements du namespace, dans l'ordre
kubectl -n yelb get events --sort-by=.lastTimestamp
```

Si `cmctl`, l'outil en ligne de commande de cert-manager, est installé :

```bash
cmctl status certificate yelb-tls -n yelb    # résumé de toute la chaîne
cmctl renew yelb-tls -n yelb                 # forcer un renouvellement
```

Messages fréquents dans `describe challenge` :

| Message | Cause probable |
|---|---|
| `wrong status code '404', expected '200'` | Le DNS ne pointe pas vers ce Traefik, ou le port 80 n'arrive pas jusqu'à lui |
| `no such host` / `NXDOMAIN` | L'enregistrement DNS n'existe pas encore ou n'est pas propagé |
| `connection refused` / timeout | Port 80 fermé (pare-feu, groupe de sécurité) |
| `rateLimited` | Trop de certificats de production : repasser en staging |

Une fois le certificat émis, l'Order et le Challenge disparaissent ou passent à `valid`. Le Secret `yelb-tls` contient `tls.crt` et `tls.key`, et cert-manager le renouvelle seul environ 30 jours avant l'expiration.

---

## 9. Opérations courantes

```bash
# Passer l'API à 4 replicas, puis revenir à 2
kubectl -n yelb scale deploy/yelb-appserver --replicas=4
kubectl -n yelb get pods -l app.kubernetes.io/name=yelb-appserver -o wide
kubectl -n yelb scale deploy/yelb-appserver --replicas=2

# Redémarrer proprement un Deployment (après modification d'une ConfigMap par ex.)
kubectl -n yelb rollout restart deploy/yelb-appserver
kubectl -n yelb rollout status deploy/yelb-appserver

# Historique et retour arrière
kubectl -n yelb rollout history deploy/yelb-ui
kubectl -n yelb rollout undo deploy/yelb-ui

# Changer d'image, puis revenir en arrière.
# Exemple volontairement raté : le front 0.9 ajoute lui-même « :4567 » à
# l'adresse de l'API et nginx refuse de démarrer (CrashLoopBackOff).
# Grâce à maxUnavailable: 0, les anciens pods continuent de servir pendant ce temps.
kubectl -n yelb set image deploy/yelb-ui ui=mreferre/yelb-ui:0.9
kubectl -n yelb rollout status deploy/yelb-ui --timeout=60s    # échoue
kubectl -n yelb logs deploy/yelb-ui                              # « invalid port in upstream »
kubectl -n yelb rollout undo deploy/yelb-ui

# Voir les sondes, les ressources et les événements d'un pod
kubectl -n yelb describe pod -l app.kubernetes.io/name=yelb-appserver

# Consommation CPU / mémoire (nécessite metrics-server, présent sur k3s)
kubectl -n yelb top pods

# Ouvrir un shell dans un conteneur
kubectl -n yelb exec -it deploy/yelb-appserver -- bash

# Lire la configuration injectée
kubectl -n yelb get configmap yelb-appserver -o yaml
kubectl -n yelb get secret yelb-db -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo

# Comparer le dépôt avec ce qui tourne, avant d'appliquer
kubectl diff -k .
```

---

## 10. Dépannage

| Symptôme | Commande pour enquêter | Cause probable |
|---|---|---|
| `ErrImagePull` / `ImagePullBackOff` | `kubectl -n yelb describe pod <pod>` | Tag d'image faux : il n'y a pas de `latest` pour Yelb. Ou limite de téléchargement Docker Hub (`toomanyrequests`) |
| `exec format error`, `no matching manifest` | `kubectl get nodes -L kubernetes.io/arch` | Nœud ARM : les images Yelb sont amd64 seulement |
| Pod `Pending` | `kubectl -n yelb describe pod <pod>` | Pas assez de ressources, ou PVC non lié |
| PVC `Pending` | `kubectl -n yelb describe pvc yelb-db-data` et `kubectl get storageclass` | Pas de StorageClass par défaut |
| `CrashLoopBackOff` | `kubectl -n yelb logs <pod> --previous` | Erreur au démarrage, à lire dans les logs du conteneur précédent |
| Pod `Running` mais `0/1` | `kubectl -n yelb describe pod <pod>` (section Events) | readinessProbe en échec |
| Front OK mais votes en erreur | `kubectl -n yelb logs deploy/yelb-appserver` | Base injoignable : nom du Service, ConfigMap, mot de passe |
| 404 Traefik sur le domaine | `kubectl -n yelb get ingress` et `kubectl -n yelb describe ingress yelb` | Nom d'hôte différent de celui demandé, ou mauvaise IngressClass |
| Certificat `READY=False` | Section 8 | DNS, port 80, quotas |
| Alerte du navigateur avec Let's Encrypt | `curl -vk https://… 2>&1 \| grep issuer` | Encore en staging : passer en prod (section 7.2) |

Commandes générales :

```bash
kubectl -n yelb get events --sort-by=.lastTimestamp
kubectl -n yelb get all
kubectl -n yelb describe <type>/<nom>
kubectl -n yelb logs <pod> --previous
```

---

## 11. Tout supprimer

```bash
# L'appli, son volume et son certificat
kubectl delete namespace yelb

# Les ClusterIssuers
kubectl delete -f cert-manager/cluster-issuers.yaml

# cert-manager lui-même (supprime aussi ses CRD et tous les certificats du cluster)
kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.3/cert-manager.yaml
```

---

## 12. Bonnes pratiques appliquées

- **Tags d'image fixés** (jamais `:latest`) avec `imagePullPolicy: IfNotPresent`.
- **Labels standards** `app.kubernetes.io/*` ; les sélecteurs se basent sur `app.kubernetes.io/name`.
- **requests / limits** sur chaque conteneur. Seule la mémoire est plafonnée, pour éviter de brider le CPU.
- **Sondes partout :** chaque conteneur a une readinessProbe (pod retiré du Service tant qu'il n'est pas prêt) et une livenessProbe (conteneur redémarré s'il ne répond plus).

  | Composant | readinessProbe | livenessProbe |
  |---|---|---|
  | PostgreSQL | `pg_isready -d yelbdatabase` | `pg_isready` |
  | Redis | `redis-cli ping` | port 6379 ouvert |
  | API | HTTP `/api/hostname` | HTTP `/api/hostname` |
  | Front | HTTP `/` | HTTP `/` |

- **Configuration hors de l'image :** ConfigMap pour les adresses, Secret pour le mot de passe.
- **Base sur PVC** avec `strategy: Recreate`, car un volume ReadWriteOnce ne peut pas être monté par deux pods pendant une mise à jour. `PGDATA` pointe vers un sous-dossier pour éviter l'erreur `lost+found`.
- **API et front sans état** à 2 replicas, en `RollingUpdate` avec `maxUnavailable: 0` pour des mises à jour sans coupure.
- **Un seul point d'entrée : l'Ingress.** Tous les Services sont en ClusterIP, et Traefik route selon le nom d'hôte.
- **HTTPS par défaut :** certificat Let's Encrypt géré et renouvelé par cert-manager, staging avant prod, et redirection HTTP vers HTTPS qui laisse passer le défi ACME.
- **Durcissement :** `automountServiceAccountToken: false` partout, `allowPrivilegeEscalation: false`, et Redis sans root avec un système de fichiers en lecture seule.

---

## 13. Limites connues de l'appli

- **amd64 uniquement** pour les trois images Yelb : elles ne tournent pas sur des nœuds ARM, sauf avec une émulation.
- **Les tags `latest` n'existent pas** sur Docker Hub pour Yelb. Il faut toujours écrire le tag complet.
- **Mot de passe imposé :** l'API a `postgres_password` écrit en dur dans son code et ne lit aucune variable pour ce mot de passe. Le Secret alimente la base, mais pas l'API. Changer le Secret casse la connexion.
- **Noms de Service imposés :** le front cherche `yelb-appserver`. L'API cherche `yelb-db` et `redis-server`, mais ces deux noms peuvent être changés dans la ConfigMap `yelb-appserver`.

---

## 14. Idées d'exercices

1. **Répartition de charge.** Passer l'API à 4 replicas et recharger la page : le champ « server » change selon le pod qui répond.
   ```bash
   kubectl -n yelb scale deploy/yelb-appserver --replicas=4
   ```
2. **Persistance.** Voter, supprimer le pod de la base, et constater que les votes sont conservés grâce au PVC. Refaire l'expérience avec un `emptyDir` à la place du PVC.
   ```bash
   kubectl -n yelb delete pod -l app.kubernetes.io/name=yelb-db
   kubectl -n yelb exec deploy/yelb-db -- psql -U postgres -d yelbdatabase -c "SELECT * FROM restaurants;"
   ```
3. **DNS des Services.** Renommer le Service `yelb-db`, observer l'erreur, puis corriger via la ConfigMap et un redémarrage.
   ```bash
   kubectl -n yelb edit configmap yelb-appserver     # YELB_DB_SERVER_ENDPOINT
   kubectl -n yelb rollout restart deploy/yelb-appserver
   ```
4. **Sondes.** Mettre un mauvais chemin dans la readinessProbe de l'API, puis observer les endpoints se vider.
   ```bash
   kubectl -n yelb edit deploy yelb-appserver
   kubectl -n yelb get endpointslices -l kubernetes.io/service-name=yelb-appserver -w
   ```
5. **Certificats.** Supprimer le Secret `yelb-tls` et suivre sa recréation.
   ```bash
   kubectl -n yelb delete secret yelb-tls
   kubectl -n yelb get certificate,order,challenge -w
   ```
6. **Pour aller plus loin :** remplacer le Deployment PostgreSQL par un StatefulSet.

---

## 15. TP 3 : packager l'appli avec Helm

Les manifestes ci-dessus sont repris dans un chart Helm, `helm/yelb`, qui installe une release **dev** et une release **prod** à partir du même code. Le guide complet se trouve dans [helm/README.md](helm/README.md) : création du chart, paramètres, install, upgrade, rollback et `helm test`.

```bash
helm install dev  ./helm/yelb -n yelb-dev  --create-namespace -f helm/yelb/values-dev.yaml  --wait
helm install prod ./helm/yelb -n yelb-prod --create-namespace -f helm/yelb/values-prod.yaml --wait
helm test prod -n yelb-prod --logs
```
