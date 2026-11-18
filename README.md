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

## Prérequis

- Un contrôleur Ingress **Traefik** avec l'IngressClass `traefik` (présent par défaut sur k3s) : `kubectl get ingressclass`.
- Un enregistrement DNS qui pointe vers l'IP publique de Traefik. Le nom est défini dans `50-ingress.yaml` et `51-ingress-http-redirect.yaml` : `demo.killian-stein-3.lab-cesi.fr`. Chaque étudiant y met le sien, aux **trois** endroits (deux `host:` et le bloc `tls`).
- Les ports **80 et 443** ouverts vers Traefik. Le port 80 sert aussi à la validation Let's Encrypt.
- **cert-manager** et les ClusterIssuers Let's Encrypt (voir ci-dessous).

## Déployer

### 1. Installer cert-manager (une fois par cluster)

```bash
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.21.3/cert-manager.yaml
kubectl -n cert-manager wait --for=condition=Available deploy --all --timeout=300s
```

### 2. Créer les ClusterIssuers Let's Encrypt, staging puis prod

```bash
kubectl apply -f cert-manager/cluster-issuers.yaml
kubectl get clusterissuer      # les deux doivent être READY=True
```

`READY=True` signifie que cert-manager a ouvert un compte chez Let's Encrypt.

### 3. Déployer l'appli (certificat de **staging**)

```bash
kubectl apply -k .
kubectl -n yelb get pods,svc,pvc,ingress,certificate
```

Après une à deux minutes, `certificate/yelb-tls` passe à `READY=True`. <https://demo.killian-stein-3.lab-cesi.fr> répond alors, avec une **alerte du navigateur** : c'est normal, le certificat de staging est signé par une fausse autorité. On vérifie l'émetteur :

```bash
curl -vk https://demo.killian-stein-3.lab-cesi.fr 2>&1 | grep issuer   # « (STAGING) ... »
```

### 4. Passer en **production** : le vrai cadenas

Dans `50-ingress.yaml`, remplacer `letsencrypt-staging` par `letsencrypt-prod`, puis :

```bash
kubectl apply -k .
kubectl -n yelb get certificate -w      # attendre READY=True
```

cert-manager voit que le certificat vient d'un autre émetteur et en redemande un. Si l'ancien reste servi, on supprime le Secret pour forcer une nouvelle émission : `kubectl -n yelb delete secret yelb-tls`.

`http://` redirige automatiquement vers `https://` (Ingress `yelb-http-redirect`).

> Ne passez en production qu'une fois le staging validé : Let's Encrypt limite le nombre de certificats identiques à 5 par semaine.

### Suivre la demande pas à pas (bonus)

cert-manager crée une chaîne d'objets, à inspecter dans l'ordre :

```
Ingress (annotation) ─► Certificate ─► CertificateRequest ─► Order ─► Challenge ─► Secret yelb-tls
```

```bash
kubectl -n yelb describe certificate yelb-tls         # état global, événements
kubectl -n yelb get certificaterequest
kubectl -n yelb describe order                        # commande ACME chez Let's Encrypt
kubectl -n yelb describe challenge                    # défi HTTP-01 : la partie qui coince en général
kubectl -n yelb get ingress                           # un Ingress cm-acme-http-solver-xxx apparaît pendant le défi
kubectl -n cert-manager logs deploy/cert-manager      # en dernier recours
```

Messages fréquents dans `describe challenge` :

| Message | Cause probable |
|---|---|
| `wrong status code '404', expected '200'` | Le DNS ne pointe pas vers ce Traefik, ou le port 80 n'arrive pas jusqu'à lui |
| `no such host` / `NXDOMAIN` | L'enregistrement DNS n'existe pas encore ou n'est pas propagé |
| `connection refused` / timeout | Port 80 fermé (pare-feu, groupe de sécurité) |
| `rateLimited` | Trop de certificats de production : repasser en staging |

Une fois le certificat émis, l'Order et le Challenge disparaissent ou passent à `valid`. Le Secret `yelb-tls` contient `tls.crt` et `tls.key`.

### Tester sans DNS

On peut forcer le nom d'hôte. En revanche, le certificat Let's Encrypt ne sera pas émis sans un vrai DNS.

```bash
curl -k --resolve demo.killian-stein-3.lab-cesi.fr:443:<IP de Traefik> https://demo.killian-stein-3.lab-cesi.fr/api/getvotes
```

Tout supprimer, volume compris :

```bash
kubectl delete namespace yelb
```

## Fichiers

| Fichier | Contenu |
|---|---|
| `00-namespace.yaml` | Namespace `yelb` |
| `10-db.yaml` | Secret, PersistentVolumeClaim, Deployment et Service de PostgreSQL |
| `20-redis.yaml` | Deployment et Service de Redis |
| `30-appserver.yaml` | ConfigMap, Deployment et Service de l'API |
| `40-ui.yaml` | ConfigMap, Deployment et Service ClusterIP du front |
| `50-ingress.yaml` | Ingress HTTPS (entrée `websecure`, bloc `tls`, annotation cert-manager) vers le front |
| `51-ingress-http-redirect.yaml` | Middleware Traefik et Ingress HTTP qui redirigent vers HTTPS |
| `cert-manager/cluster-issuers.yaml` | ClusterIssuers `letsencrypt-staging` et `letsencrypt-prod` (HTTP-01, classe traefik). Hors kustomization, car ils concernent tout le cluster |
| `kustomization.yaml` | Liste des fichiers pour `kubectl apply -k` |

## Bonnes pratiques appliquées

- **Tags d'image fixés** (jamais `:latest`) avec `imagePullPolicy: IfNotPresent`.
- **Labels standards** `app.kubernetes.io/*` ; les sélecteurs se basent sur `app.kubernetes.io/name`.
- **requests / limits** sur chaque conteneur. Seule la mémoire est plafonnée, pour éviter de brider le CPU.
- **readinessProbe et livenessProbe** sur chaque composant (`pg_isready`, `redis-cli ping`, HTTP).
- **Configuration hors de l'image :** ConfigMap pour les adresses, Secret pour le mot de passe.
- **Base sur PVC** avec `strategy: Recreate`, car un volume ReadWriteOnce ne peut pas être monté par deux pods pendant une mise à jour. `PGDATA` pointe vers un sous-dossier pour éviter l'erreur `lost+found`.
- **API et front sans état** à 2 replicas, en `RollingUpdate` avec `maxUnavailable: 0` pour des mises à jour sans coupure.
- **Un seul point d'entrée : l'Ingress.** Tous les Services sont en ClusterIP, et Traefik route selon le nom d'hôte.
- **HTTPS par défaut :** certificat Let's Encrypt géré et renouvelé par cert-manager, staging avant prod, et redirection HTTP vers HTTPS qui laisse passer le défi ACME.
- **Sondes partout :** chaque conteneur a une readinessProbe (pod retiré du Service tant qu'il n'est pas prêt) et une livenessProbe (conteneur redémarré s'il ne répond plus).
- **Durcissement :** `automountServiceAccountToken: false` partout, `allowPrivilegeEscalation: false`, et Redis sans root avec un système de fichiers en lecture seule.

## Limites connues de l'appli

- **amd64 uniquement** pour les trois images Yelb : elles ne tournent pas sur des nœuds ARM, sauf avec une émulation.
- **Les tags `latest` n'existent pas** sur Docker Hub pour Yelb. Il faut toujours écrire le tag complet.
- **Mot de passe imposé :** l'API a `postgres_password` écrit en dur. Changer le Secret casse la connexion.
- **Noms de Service imposés :** le front cherche `yelb-appserver`. L'API cherche `yelb-db` et `redis-server`, mais ces deux noms peuvent être changés dans la ConfigMap `yelb-appserver`.

## Idées d'exercices

1. Passer l'API à 4 replicas (`kubectl scale`) et recharger la page : le champ « server » change selon le pod qui répond.
2. Supprimer le pod `yelb-db` et constater que les votes sont conservés grâce au PVC. Refaire l'expérience sans PVC (`emptyDir`).
3. Renommer le Service `yelb-db` et observer l'erreur, puis corriger via la ConfigMap et un `kubectl rollout restart`.
4. Casser la readinessProbe de l'API, par exemple avec un mauvais chemin, et observer `kubectl get endpoints`.
5. Supprimer le Secret `yelb-tls` et suivre sa recréation avec `kubectl -n yelb get certificate,order,challenge -w`.
6. Pour aller plus loin : remplacer le Deployment PostgreSQL par un StatefulSet.
