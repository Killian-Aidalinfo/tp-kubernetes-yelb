# TP 5 : verrouiller le namespace

On durcit le namespace `yelb-prod` du TP 4 sur trois plans :

| Plan | Outil Kubernetes | Ce qu'on obtient |
|---|---|---|
| **Qui peut faire quoi** | RBAC : ServiceAccount, Role, RoleBinding | Un compte `ci` qui lit tout mais ne modifie rien, et ne voit pas les Secrets |
| **Qui parle à qui** | NetworkPolicy | Plus aucun trafic par défaut, puis seulement Traefik → web → api → postgres (+ Redis) |
| **Ce que les pods ont le droit d'être** | Pod Security Admission, profil `restricted` | Pas de root, pas de capacités, pas d'élévation de privilèges |

Bonus : scanner les images avec **Trivy** et corriger une vulnérabilité critique.

Tout passe par Git, comme au TP 4 : Argo CD applique les changements.

## Sommaire

1. [Prérequis](#1-prérequis)
2. [Étape 1 : un ServiceAccount ci en lecture seule](#2-étape-1--un-serviceaccount-ci-en-lecture-seule)
3. [Étape 2 : deny-all, puis seulement les flux utiles](#3-étape-2--deny-all-puis-seulement-les-flux-utiles)
4. [Étape 3 : namespace en restricted, corriger les pods refusés](#4-étape-3--namespace-en-restricted-corriger-les-pods-refusés)
5. [Bonus : Trivy](#5-bonus--trivy)
6. [Dépannage](#6-dépannage)
7. [Revenir en arrière](#7-revenir-en-arrière)

### Fichiers du TP

| Fichier | Rôle |
|---|---|
| [`gitops/security/yelb-prod/rbac-ci.yaml`](yelb-prod/rbac-ci.yaml) | ServiceAccount `ci`, Role `ci-readonly`, RoleBinding |
| [`gitops/security/yelb-prod/networkpolicies.yaml`](yelb-prod/networkpolicies.yaml) | `deny-all` et les flux autorisés |
| [`gitops/apps/yelb-prod.yaml`](../apps/yelb-prod.yaml) | 3ᵉ source (`gitops/security/yelb-prod`) et labels Pod Security du namespace |
| `helm/yelb` (chart 0.4.0) | Option `podSecurity.restricted`, uid de la base réglable, script d'init de la base |
| `helm/yelb/values-prod.yaml` | `podSecurity.restricted: true` et image `postgres:17.12-alpine` |
| [`.trivyignore`](../../.trivyignore) | Vulnérabilités acceptées, avec justification |
| `.github/workflows/k8s-lint.yml` | Job `trivy` : scan des images à chaque PR |

---

## 1. Prérequis

- Le TP 4 qui tourne : Application `yelb-prod` en `Synced` / `Healthy` dans Argo CD.
- Votre dépôt à jour avec ce TP : la nouvelle source de l'Application doit pointer vers **votre** dépôt.

  ```bash
  grep -n repoURL gitops/apps/yelb-prod.yaml      # 3 sources, toutes vers votre dépôt
  ```

- Un CNI qui applique les NetworkPolicies : c'est le cas de **k3s**, grâce à son contrôleur intégré. Sans cela, les NetworkPolicies sont acceptées mais n'ont aucun effet.

Après chaque modification de l'Application (`gitops/apps/yelb-prod.yaml`), il faut la réappliquer : c'est le seul fichier qu'Argo CD ne lit pas tout seul.

```bash
kubectl apply -f gitops/apps/yelb-prod.yaml
```

---

## 2. Étape 1 : un ServiceAccount ci en lecture seule

[`rbac-ci.yaml`](yelb-prod/rbac-ci.yaml) crée trois objets :

| Objet | Rôle |
|---|---|
| `ServiceAccount ci` | L'identité que la CI utilisera |
| `Role ci-readonly` | Les droits : `get`, `list`, `watch` sur pods, logs, services, configmaps, deployments, ingresses, events, certificats… **Pas les Secrets** |
| `RoleBinding ci-readonly` | Donne ce Role au ServiceAccount, **dans ce namespace seulement** |

Il est déployé par Argo CD, via la 3ᵉ source de l'Application :

```bash
kubectl apply -f gitops/apps/yelb-prod.yaml
kubectl -n yelb-prod get serviceaccount,role,rolebinding
```

### Vérifier avec kubectl auth can-i

`--as` fait poser la question « en tant que » le ServiceAccount, dont le nom complet est `system:serviceaccount:<namespace>:<nom>` :

```bash
SA=system:serviceaccount:yelb-prod:ci

kubectl auth can-i list pods       -n yelb-prod --as=$SA     # yes
kubectl auth can-i get pods/log    -n yelb-prod --as=$SA     # yes
kubectl auth can-i watch deployments.apps -n yelb-prod --as=$SA   # yes
kubectl auth can-i get secrets     -n yelb-prod --as=$SA     # no  : pas de secrets
kubectl auth can-i delete pods     -n yelb-prod --as=$SA     # no  : lecture seule
kubectl auth can-i patch deployments.apps -n yelb-prod --as=$SA   # no
kubectl auth can-i create pods/exec -n yelb-prod --as=$SA    # no  : pas de shell dans les pods
kubectl auth can-i list pods       -n default   --as=$SA     # no  : rien hors de yelb-prod

# Tous les droits d'un coup
kubectl auth can-i --list -n yelb-prod --as=$SA
```

### Utiliser le ServiceAccount comme le ferait une CI

On crée un jeton de courte durée et un kubeconfig qui ne contient **que** ce jeton :

```bash
TOKEN=$(kubectl -n yelb-prod create token ci --duration=1h)
SERVER=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
kubectl config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' | base64 -d > ca.crt

kubectl config --kubeconfig=ci.kubeconfig set-cluster k3s --server="$SERVER" --certificate-authority=ca.crt --embed-certs=true
kubectl config --kubeconfig=ci.kubeconfig set-credentials ci --token="$TOKEN"
kubectl config --kubeconfig=ci.kubeconfig set-context ci --cluster=k3s --user=ci --namespace=yelb-prod
kubectl config --kubeconfig=ci.kubeconfig use-context ci

kubectl --kubeconfig=ci.kubeconfig auth whoami                 # system:serviceaccount:yelb-prod:ci
kubectl --kubeconfig=ci.kubeconfig get pods                    # OK
kubectl --kubeconfig=ci.kubeconfig delete pod -l app.kubernetes.io/component=redis   # Forbidden
kubectl --kubeconfig=ci.kubeconfig get secrets                 # Forbidden
```

> **Piège :** `kubectl --token=$TOKEN …` avec votre kubeconfig habituel ne teste rien. Sur k3s, ce kubeconfig contient un certificat client administrateur, que l'API server authentifie **avant** le jeton : la commande s'exécute en administrateur. D'où le kubeconfig dédié ci-dessus. Pensez à supprimer `ci.kubeconfig` et `ca.crt` après le TP.

---

## 3. Étape 2 : deny-all, puis seulement les flux utiles

### Le principe

Sans NetworkPolicy, tous les pods du cluster peuvent se parler. Une NetworkPolicy qui sélectionne un pod le fait passer en « liste blanche » : seul ce qu'une règle autorise reste permis. On pose donc d'abord une politique qui sélectionne **tous** les pods sans rien autoriser, puis on ouvre flux par flux.

```
                ┌──────────────────────────── namespace yelb-prod ───────────────────────────┐
  Traefik ──80─►│ ui ──4567──► appserver ──5432──► db                                       │
 (kube-system)  │                  └──────6379──► redis                                     │
                │  tous les pods ──53──► kube-dns (kube-system)                              │
                │  test (helm test) ──► appserver, ui     solver ACME ◄── Traefik (8089)    │
                └────────────────────────────────────────────────────────────────────────────┘
```

| NetworkPolicy | Pods visés | Autorise |
|---|---|---|
| `deny-all` | tous | rien, ni en entrée ni en sortie |
| `allow-dns` | tous | sortie vers kube-dns, port 53 UDP/TCP |
| `allow-traefik-to-ui` | ui | entrée depuis les pods Traefik, quel que soit leur namespace |
| `allow-ui-to-appserver` / `appserver-ingress` | ui → appserver | **web vers api** : sortie du front et entrée de l'API (4567) |
| `allow-appserver-to-db-and-redis` / `db-ingress` / `redis-ingress` | appserver → db, redis | **api vers postgres** (5432) et vers Redis (6379) |
| `allow-test-egress` / `ui-ingress-from-test` | pod de `helm test` | appels vers l'API et le front |
| `allow-traefik-to-acme-solver` | pod solver de cert-manager | entrée depuis Traefik (8089), pour renouveler le certificat |

Points à comprendre :

- **Un flux s'ouvre des deux côtés** : en sortie du pod qui appelle (`egress`) et en entrée du pod appelé (`ingress`), car `deny-all` bloque les deux sens.
- **Le DNS** : sans `allow-dns`, plus aucun pod ne trouve `prod-yelb-db` par son nom, et tout casse.
- **Redis** : la slide ne parle que de web → api → postgres, mais l'API compte les pages vues dans Redis. Sans ce flux, la page d'accueil reste en erreur.
- **Le renouvellement du certificat** : tous les 60 jours environ, cert-manager crée un pod solver dans ce namespace. Sans sa règle, le certificat expire en silence 30 jours plus tard.
- Les pods sont désignés par le label `app.kubernetes.io/component` posé par le chart.

Comme au TP 4, Argo CD applique le dossier :

```bash
kubectl apply -f gitops/apps/yelb-prod.yaml           # si ce n'est pas déjà fait à l'étape 1
kubectl -n yelb-prod get networkpolicy
kubectl -n yelb-prod describe networkpolicy deny-all
```

### Vérifier que ce qui doit passer passe

L'appli doit toujours fonctionner, de bout en bout :

```bash
curl -s https://demo.prenom.lab-cesi.fr/api/getvotes     # Traefik -> ui -> api -> postgres
curl -s https://demo.prenom.lab-cesi.fr/api/pageviews    # ... -> api -> redis
```

### Vérifier que le reste est bloqué

On lance un pod de test jetable, qui porte le label d'un composant pour « se faire passer » pour lui. Il doit respecter le profil `restricted` : on construit sa spécification avec `jq` (`sudo apt-get install -y jq`).

```bash
probe() {   # usage : probe <composant> '<commande shell>'
  local spec
  spec=$(jq -cn --arg cmd "sleep 2; $2" '{spec: {
    securityContext: {runAsNonRoot: true, runAsUser: 65534, seccompProfile: {type: "RuntimeDefault"}},
    containers: [{name: "probe", image: "busybox:1.37", command: ["sh", "-c", $cmd],
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}}]}}')
  kubectl -n yelb-prod run probe-$RANDOM --rm -i --restart=Never --quiet \
    --image=busybox:1.37 --labels="app.kubernetes.io/component=$1" --overrides="$spec"
}

# En tant que web (ui) : l'API oui, la base et Redis non
probe ui 'wget -qO- -T 3 http://prod-yelb-appserver:4567/api/hostname && echo " <- api OK"'
probe ui 'nc -z -w 3 prod-yelb-db 5432 && echo "db OUVERT" || echo "db BLOQUÉ"'
probe ui 'nc -z -w 3 prod-yelb-redis 6379 && echo "redis OUVERT" || echo "redis BLOQUÉ"'

# En tant qu'api : la base et Redis oui
probe appserver 'nc -z -w 3 prod-yelb-db 5432 && echo "db OK" || echo "db BLOQUÉ"'

# Un pod quelconque : le DNS oui, tout le reste non
probe intrus 'nslookup prod-yelb-db.yelb-prod.svc.cluster.local >/dev/null && echo "DNS OK"'
probe intrus 'wget -qO- -T 3 http://prod-yelb-ui/ >/dev/null && echo "ui OUVERT" || echo "ui BLOQUÉ"'
probe intrus 'wget -qO- -T 3 http://example.com >/dev/null && echo "internet OUVERT" || echo "internet BLOQUÉ"'
```

Résultat attendu, vérifié sur un cluster de test :

| Depuis | Vers | Résultat |
|---|---|---|
| ui | api | ouvert |
| ui | db, redis, internet | **bloqué** |
| appserver | db, redis | ouvert |
| appserver | ui | **bloqué** |
| autre pod | DNS | ouvert |
| autre pod | ui, db | **bloqué** |

Avec busybox, utilisez le nom DNS complet (`…​.yelb-prod.svc.cluster.local`) pour `nslookup` : avec le nom court, son code retour est faux même quand la résolution marche.

---

## 4. Étape 3 : namespace en restricted, corriger les pods refusés

### 4.1 Les trois profils

Pod Security Admission vérifie chaque pod à sa création, selon le label du namespace :

| Profil | En bref |
|---|---|
| `privileged` | Aucune restriction |
| `baseline` | Interdit les pods privilégiés, les montages du nœud, `hostNetwork`… |
| `restricted` | `baseline` + non root obligatoire, capacités supprimées (`drop: ["ALL"]`), `allowPrivilegeEscalation: false`, profil `seccomp` |

Chaque profil s'applique selon trois modes : `enforce` refuse le pod, `warn` affiche un avertissement, `audit` écrit dans le journal d'audit.

### 4.2 Voir ce qui serait refusé, sans rien casser

```bash
kubectl label --dry-run=server --overwrite ns yelb-prod pod-security.kubernetes.io/enforce=restricted
# Warning: existing pods in namespace "yelb-prod" violate the new PodSecurity enforce level "restricted:latest"
# Warning: prod-yelb-ui-…: allowPrivilegeEscalation != false, unrestricted capabilities, runAsNonRoot != true, seccompProfile
# …
```

### 4.3 Passer le namespace en restricted (par Git)

Le namespace est créé par Argo CD (`CreateNamespace=true`). Ses labels se déclarent donc dans l'Application, sous `managedNamespaceMetadata` :

```yaml
  syncPolicy:
    managedNamespaceMetadata:
      labels:
        pod-security.kubernetes.io/enforce: restricted
        pod-security.kubernetes.io/enforce-version: latest
        pod-security.kubernetes.io/warn: restricted
        pod-security.kubernetes.io/audit: restricted
```

```bash
kubectl apply -f gitops/apps/yelb-prod.yaml
kubectl get ns yelb-prod --show-labels
```

Les pods qui tournent déjà ne sont pas touchés. Les **nouveaux** pods, eux, sont refusés : on le voit au prochain redémarrage.

```bash
kubectl -n yelb-prod rollout restart deploy/prod-yelb-ui
kubectl -n yelb-prod get deploy                       # READY bloqué, UP-TO-DATE à 0
kubectl -n yelb-prod get events --field-selector reason=FailedCreate
# Error creating: pods "prod-yelb-ui-…" is forbidden: violates PodSecurity "restricted:latest":
#   allowPrivilegeEscalation != false, unrestricted capabilities (container "ui" must set
#   securityContext.capabilities.drop=["ALL"]), runAsNonRoot != true, seccompProfile …
```

Redis passe déjà : son chart était durci dès le TP 1. Le front, l'API et la base, eux, sont refusés.

### 4.4 Corriger les pods

Il faut, pour chaque pod :

```yaml
spec:
  securityContext:                  # niveau pod
    runAsNonRoot: true
    runAsUser: <uid non nul>
    seccompProfile:
      type: RuntimeDefault
  containers:
    - securityContext:              # niveau conteneur
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
```

Le chart le fait quand `podSecurity.restricted: true`. Le plus délicat, c'est de trouver **sous quel utilisateur chaque image peut tourner** :

| Composant | Image | Problème en non root | Correction dans le chart |
|---|---|---|---|
| Front | `yelb-ui` | Le script de démarrage réécrit la conf nginx (fichiers de root) et écoute sur le port 80, réservé à root | nginx lancé directement en utilisateur `nginx` (uid 101), sur le port **8080**, avec une conf fournie par ConfigMap. Disque en lecture seule + `/tmp` en `emptyDir` |
| API | `yelb-appserver` | Image prévue pour root, mais ses fichiers sont lisibles par tous | uid 1001, disque en lecture seule + `/tmp` en `emptyDir` |
| Base | `postgres` | Le point d'entrée passe de root à postgres avec `gosu` | Démarrage direct en utilisateur postgres (`db.runAsUser` : 70 en alpine, 999 en Debian) + `fsGroup` pour que le volume lui soit accessible |
| Redis | `redis` | aucun | déjà conforme |

Le Service du front garde son port 80 : seul le `targetPort` (nommé `http`) passe à 8080. L'Ingress et les NetworkPolicies, qui utilisent ce nom de port, n'ont pas à changer.

La correction passe par un commit :

```bash
# helm/yelb/values-prod.yaml
#   podSecurity:
#     restricted: true
git commit -am "fix: pods conformes au profil restricted"
git push
kubectl -n argocd annotate application yelb-prod argocd.argoproj.io/refresh=normal --overwrite

kubectl -n yelb-prod get pods -w                      # tous Running
kubectl -n yelb-prod get events --field-selector reason=FailedCreate   # plus de nouveaux refus
```

Vérifier qu'aucun pod ne tourne en root :

```bash
kubectl -n yelb-prod get pods -o custom-columns='POD:.metadata.name,UID:.spec.securityContext.runAsUser,NONROOT:.spec.securityContext.runAsNonRoot'
for d in ui appserver db redis; do echo "$d : $(kubectl -n yelb-prod exec deploy/prod-yelb-$d -- id)"; done
```

Pour tester le chart sans Argo CD, dans un namespace jetable :

```bash
kubectl create ns psa-demo
kubectl label ns psa-demo pod-security.kubernetes.io/enforce=restricted
helm install demo ./helm/yelb -n psa-demo --set ingress.enabled=false --set podSecurity.restricted=false   # pods refusés
helm upgrade demo ./helm/yelb -n psa-demo --set ingress.enabled=false --set podSecurity.restricted=true --wait
helm test demo -n psa-demo
helm uninstall demo -n psa-demo && kubectl delete ns psa-demo
```

---

## 5. Bonus : Trivy

### 5.1 Installer Trivy

```bash
# Debian / Ubuntu (dépôt officiel d'Aqua Security)
sudo apt-get install -y wget gnupg
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor | sudo tee /usr/share/keyrings/trivy.gpg >/dev/null
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" | sudo tee /etc/apt/sources.list.d/trivy.list
sudo apt-get update && sudo apt-get install -y trivy
trivy --version

# Ou sans installation, avec Docker
alias trivy='docker run --rm aquasec/trivy:0.76.1'
```

### 5.2 Scanner les images de l'appli

```bash
# Les images réellement déployées
kubectl -n yelb-prod get pods -o jsonpath='{range .items[*]}{.spec.containers[*].image}{"\n"}{end}' | sort -u

# Une image, vulnérabilités critiques et hautes
trivy image --severity CRITICAL,HIGH mreferre/yelb-db:0.6

# Seulement ce qui a un correctif disponible
trivy image --severity CRITICAL --ignore-unfixed mreferre/yelb-db:0.6

# Un résumé par image
for img in mreferre/yelb-ui:0.10 mreferre/yelb-appserver:0.7 mreferre/yelb-db:0.6 redis:7.4-alpine; do
  echo "== $img"; trivy image --quiet --severity CRITICAL --format table "$img" | grep -E "^Total|CRITICAL: [0-9]+"
done
```

Résultats relevés le 18 novembre 2026 (Trivy 0.76.1) :

| Image | CRITICAL | HIGH | Commentaire |
|---|---|---|---|
| `mreferre/yelb-ui:0.10` | 39 | 125 | Image non maintenue (2022) |
| `mreferre/yelb-appserver:0.7` | 61 | 698 | Image non maintenue (2022) |
| `mreferre/yelb-db:0.6` | **8** | 104 | **PostgreSQL 10, en fin de vie depuis 2022** |
| `redis:7.4-alpine` | 0 | 0 | |
| `postgres:17.12-alpine` | 1 | 25 | La CVE critique est dans `gosu`, voir plus bas |

### 5.3 Corriger : remplacer l'image de la base

Les images Yelb ne sont plus maintenues : pour les corriger, il faudrait les reconstruire soi-même. La base, en revanche, n'a rien de spécifique à Yelb. On remplace `mreferre/yelb-db:0.6` par l'image **officielle** `postgres:17.12-alpine`, maintenue.

Par exemple, la CVE critique **CVE-2019-12900** (libbz2) de `yelb-db:0.6` disparaît, comme 7 des 8 critiques. L'image officielle ne contient pas le script qui crée la base `yelbdatabase` : le chart le fournit maintenant, par une ConfigMap montée dans `/docker-entrypoint-initdb.d`.

Dans `helm/yelb/values-prod.yaml` :

```yaml
db:
  image:
    repository: postgres
    tag: "17.12-alpine"
  runAsUser: 70           # utilisateur postgres des images alpine
```

Passer de PostgreSQL 10 à 17 impose **une base neuve** : le volume existant contient des données d'une autre version majeure, appartenant à un autre uid. Le pod de base partirait en `CrashLoopBackOff` (`initdb: could not access directory … Permission denied`). Les votes étant des données de démo, on repart d'un volume vide, et Argo CD le recrée :

```bash
git commit -am "fix(sécurité): base sur postgres:17.12-alpine (CVE critiques de yelb-db:0.6)"
git push
kubectl -n argocd annotate application yelb-prod argocd.argoproj.io/refresh=normal --overwrite

# Volume neuf : on supprime l'ancien, Argo CD recrée le PVC depuis Git
kubectl -n yelb-prod delete pvc prod-yelb-db-data --wait=false
kubectl -n yelb-prod delete pod -l app.kubernetes.io/component=db

kubectl -n yelb-prod get pvc,pods -w
kubectl -n yelb-prod exec deploy/prod-yelb-db -- psql -U postgres -d yelbdatabase -c "SELECT * FROM restaurants;"
```

Avec de vraies données, on ferait d'abord un `pg_dump` de l'ancienne base, puis une restauration dans la nouvelle.

Rescanner :

```bash
trivy image --severity CRITICAL postgres:17.12-alpine
# 1 CRITICAL : CVE-2025-68121, dans /usr/local/bin/gosu (bibliothèque Go)
```

### 5.4 Accepter un risque, par écrit : .trivyignore

La CVE restante est dans `gosu`, qui ne sert qu'à passer de root à `postgres` au démarrage. En mode `restricted`, le conteneur démarre directement en uid 70 : `gosu` n'est **jamais exécuté**. On l'accepte, avec sa justification et une date de revue, dans [`.trivyignore`](../../.trivyignore) :

```bash
trivy image --severity CRITICAL --ignore-unfixed --ignorefile .trivyignore --exit-code 1 postgres:17.12-alpine
echo $?     # 0 : plus aucune critique non justifiée
```

### 5.5 Trivy dans la CI

Le job `trivy` du workflow [`k8s-lint.yml`](../../.github/workflows/k8s-lint.yml) rejoue ce scan à chaque Pull Request :

- il liste les images du chart en prod (`helm template` + `grep image:`) ;
- **postgres, redis, busybox** : la PR échoue si une CVE critique avec correctif apparaît, hors `.trivyignore` ;
- **images Yelb** : rapport seul, car on ne peut pas les corriger sans les reconstruire.

---

## 6. Dépannage

| Symptôme | Commande | Cause probable |
|---|---|---|
| Deployment bloqué à `0/N`, aucun pod créé | `kubectl -n yelb-prod get events --field-selector reason=FailedCreate` | Pod refusé par Pod Security : le message dit quel champ manque |
| Front en `CrashLoopBackOff` : `bind() to 0.0.0.0:80 failed (13: Permission denied)` | `kubectl -n yelb-prod logs deploy/prod-yelb-ui` | Non root sur le port 80 : utiliser le mode restricted du chart (port 8080) |
| Base en `CrashLoopBackOff` : `could not access directory … Permission denied` | `kubectl -n yelb-prod logs deploy/prod-yelb-db` | Volume créé par un autre uid ou une autre version de PostgreSQL : voir 5.3 |
| Page d'accueil en erreur après `deny-all` | `kubectl -n yelb-prod logs deploy/prod-yelb-appserver` | Un flux manque : DNS, API vers Redis… |
| 504 / `Gateway Timeout` de Traefik | `kubectl -n yelb-prod describe networkpolicy allow-traefik-to-ui` | Traefik n'a pas le label `app.kubernetes.io/name: traefik` : `kubectl get pods -A -l app.kubernetes.io/name=traefik` |
| Certificat non renouvelé | `kubectl -n yelb-prod describe challenge` | Policy du solver ACME absente ou mauvais port (8089) |
| NetworkPolicies sans effet | `kubectl get pods -n kube-system` | CNI qui ne les applique pas (Flannel seul, par exemple). k3s les applique |
| `can-i` répond `yes` à tout | | Vous testez avec `--token` et votre kubeconfig admin : voir le piège de l'étape 1 |
| `helm test` échoue | `kubectl -n <ns> logs <release>-yelb-test` | Policies `allow-test-egress` / `ui-ingress-from-test` absentes |

---

## 7. Revenir en arrière

Tout est dans Git, donc un `git revert` du commit concerné, suivi d'un `push`, suffit. Pour retirer les labels Pod Security, on enlève le bloc `managedNamespaceMetadata` de l'Application, on la réapplique, puis :

```bash
kubectl label ns yelb-prod pod-security.kubernetes.io/enforce- pod-security.kubernetes.io/warn- pod-security.kubernetes.io/audit- pod-security.kubernetes.io/enforce-version-
```
