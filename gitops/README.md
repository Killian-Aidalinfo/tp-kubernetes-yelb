# TP 4 : livrer en GitOps

Jusqu'ici, on déployait à la main avec `kubectl apply` ou `helm install`. En GitOps, **le dépôt Git est la seule source de vérité**. Un outil installé dans le cluster, ici **Argo CD**, lit le dépôt en continu et applique ce qu'il contient. Pour déployer, on pousse un commit, et on ne touche plus au cluster à la main.

Problème : le mot de passe PostgreSQL ne peut pas aller en clair dans Git. **Sealed Secrets** le chiffre avec une clé publique du cluster. Le fichier chiffré, un *SealedSecret*, peut être commité sans risque : seul le contrôleur installé dans le cluster sait le déchiffrer.

```
  vous ── git push ──► dépôt Git ◄── lit toutes les 3 min ── Argo CD (dans le cluster)
                       ├── helm/yelb (chart du TP 3)                │
                       └── gitops/secrets/…  (SealedSecret)         ▼ applique
                                                      SealedSecret ─► contrôleur Sealed Secrets ─► Secret
                                                      chart Helm   ─► Deployments, Services, Ingress…
```

## Sommaire

1. [Prérequis](#1-prérequis)
2. [Étape 1 : Sealed Secrets et kubeseal](#2-étape-1--sealed-secrets-et-kubeseal)
3. [Étape 2 : pousser le chart et le SealedSecret dans votre dépôt](#3-étape-2--pousser-le-chart-et-le-sealedsecret-dans-votre-dépôt)
4. [Étape 3 : déployer avec Argo CD](#4-étape-3--déployer-avec-argo-cd)
5. [Vivre en GitOps : changer, réparer, revenir en arrière](#5-vivre-en-gitops--changer-réparer-revenir-en-arrière)
6. [Dépannage](#6-dépannage)
7. [Tout supprimer](#7-tout-supprimer)

### Fichiers du TP

| Fichier | Rôle |
|---|---|
| `gitops/apps/yelb-prod.yaml` | Application Argo CD : quoi déployer (chart + SealedSecret), où, et comment synchroniser |
| `gitops/secrets/yelb-prod/yelb-db-credentials.yaml` | SealedSecret du mot de passe PostgreSQL. **Exemple à régénérer** pour votre cluster |
| `helm/yelb` | Le chart du TP 3. Il accepte maintenant `db.existingSecret` pour utiliser un Secret fourni d'ailleurs |
| `.gitignore` | Empêche de commiter la clé privée de Sealed Secrets ou un Secret en clair |

---

## 1. Prérequis

- Les TP 1 à 3 : Traefik, cert-manager, les ClusterIssuers, DNS. Voir le [README principal](../README.md).
- `kubectl` et `helm` sans `sudo` sur k3s : voir [Sur k3s : donner à Helm l'accès au cluster](../helm/README.md#sur-k3s--donner-à-helm-laccès-au-cluster).
- Un compte GitHub (ou GitLab…) pour héberger **votre** dépôt.
- **Supprimer la release prod du TP 3**, si elle existe : Argo CD va reprendre le namespace `yelb-prod`, et deux outils ne doivent pas gérer les mêmes ressources.

  ```bash
  helm uninstall prod -n yelb-prod --ignore-not-found
  kubectl delete namespace yelb --ignore-not-found      # déploiement du TP 2
  ```

---

## 2. Étape 1 : Sealed Secrets et kubeseal

### 2.1 Installer le contrôleur dans le cluster

```bash
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.41.2/controller.yaml
kubectl -n kube-system rollout status deploy/sealed-secrets-controller

# Vérifier
kubectl -n kube-system get pods -l name=sealed-secrets-controller
kubectl get crd sealedsecrets.bitnami.com
```

Au démarrage, le contrôleur génère une paire de clés. La clé privée reste dans le cluster, dans un Secret de `kube-system`. La clé publique sert à chiffrer.

### 2.2 Installer le CLI kubeseal sur la VM

```bash
KUBESEAL_VERSION=0.41.2
curl -sSLO "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xzf "kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz" kubeseal
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
rm kubeseal "kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"

kubeseal --version
```

Sur macOS : `brew install kubeseal`.

### 2.3 Chiffrer le mot de passe PostgreSQL

On fabrique un Secret **sans l'envoyer au cluster** (`--dry-run=client`), et on le passe directement à kubeseal, qui le chiffre avec la clé publique du cluster :

```bash
kubectl create secret generic yelb-db-credentials \
  --namespace yelb-prod \
  --from-literal=POSTGRES_PASSWORD=postgres_password \
  --dry-run=client -o yaml \
| kubeseal --format yaml > gitops/secrets/yelb-prod/yelb-db-credentials.yaml
```

- Le Secret en clair n'est jamais écrit sur disque.
- Le nom (`yelb-db-credentials`) et le namespace (`yelb-prod`) sont **inscrits dans le chiffrement**. Le SealedSecret ne se déchiffre que sous ce nom et dans ce namespace : c'est la portée `strict`, par défaut. Copié dans un autre namespace, il ne sert à rien.
- Le mot de passe doit rester `postgres_password`, car l'API Yelb l'a écrit en dur dans son code. Le TP porte sur le mécanisme, pas sur la valeur.

Regarder le résultat :

```bash
cat gitops/secrets/yelb-prod/yelb-db-credentials.yaml
# kind: SealedSecret, avec encryptedData.POSTGRES_PASSWORD: AgB… (illisible)

# Vérifier que le cluster sait le déchiffrer
kubeseal --validate < gitops/secrets/yelb-prod/yelb-db-credentials.yaml && echo "OK"
```

Chiffrer deux fois la même valeur donne deux résultats différents : c'est normal, le chiffrement est aléatoire.

### 2.4 Sauvegarder la clé du contrôleur

Si le cluster est réinstallé, une nouvelle clé est générée, et **tous les SealedSecrets du dépôt deviennent indéchiffrables**. On garde donc une copie de la clé, **hors de Git** :

```bash
kubectl -n kube-system get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml > sealed-secrets-key.backup.yaml
# À ranger en lieu sûr (gestionnaire de mots de passe, coffre…). Le .gitignore l'exclut du dépôt.
```

Pour la restaurer sur un nouveau cluster : `kubectl apply -f sealed-secrets-key.backup.yaml`, puis `kubectl -n kube-system delete pod -l name=sealed-secrets-controller`.

### 2.5 Chiffrer sans accès au cluster (facultatif)

La clé publique peut être récupérée une fois, puis partagée avec l'équipe :

```bash
kubeseal --fetch-cert > pub-cert.pem
kubectl create secret generic yelb-db-credentials --namespace yelb-prod \
  --from-literal=POSTGRES_PASSWORD=postgres_password --dry-run=client -o yaml \
| kubeseal --cert pub-cert.pem --format yaml > gitops/secrets/yelb-prod/yelb-db-credentials.yaml
```

---

## 3. Étape 2 : pousser le chart et le SealedSecret dans votre dépôt

Argo CD doit lire **votre** dépôt : celui qui contient **votre** SealedSecret, chiffré pour **votre** cluster.

### 3.1 Créer votre dépôt

Sur GitHub, créez un dépôt **public** vide, par exemple `tp-kubernetes-yelb`. Un dépôt privé fonctionne aussi, mais il faut alors donner un jeton d'accès à Argo CD (voir le dépannage). Avec le CLI `gh` :

```bash
gh repo create tp-kubernetes-yelb --public
```

### 3.2 Pointer le dépôt local vers le vôtre

```bash
cd ~/tp-kubernetes-yelb
git remote rename origin upstream          # le dépôt du cours reste accessible sous « upstream »
git remote add origin https://github.com/<votre-compte>/tp-kubernetes-yelb.git
git remote -v
```

### 3.3 Personnaliser

```bash
# 1. L'Application Argo CD doit lire VOTRE dépôt (2 occurrences)
sed -i 's#https://github.com/Killian-Aidalinfo/tp-kubernetes-yelb.git#https://github.com/<votre-compte>/tp-kubernetes-yelb.git#' gitops/apps/yelb-prod.yaml
grep -n repoURL gitops/apps/yelb-prod.yaml

# 2. Votre nom d'hôte dans les valeurs du chart (TP 3)
sed -i 's/killian-stein-3/prenom/' helm/yelb/values.yaml helm/yelb/values-dev.yaml helm/yelb/values-prod.yaml
grep -n "host:" helm/yelb/values*.yaml
```

Le SealedSecret a déjà été régénéré à l'étape 2.3.

### 3.4 Commiter et pousser

```bash
git status                                   # vérifier : aucun fichier sealed-secrets-key*, aucun Secret en clair
git add gitops/ helm/
git commit -m "feat: déploiement GitOps de Yelb (Argo CD + SealedSecret)"
git push -u origin main
```

Vérification utile : le mot de passe ne doit apparaître **nulle part** en clair, sauf dans `values.yaml`, où il sert aux TP précédents et n'est pas utilisé par Argo CD.

```bash
git grep -n "postgres_password" -- gitops/apps gitops/secrets
# aucune ligne attendue
```

---

## 4. Étape 3 : déployer avec Argo CD

### 4.1 Installer Argo CD

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.6.1/manifests/install.yaml

kubectl -n argocd rollout status deploy/argocd-server
kubectl -n argocd rollout status deploy/argocd-repo-server
kubectl -n argocd rollout status statefulset/argocd-application-controller
kubectl -n argocd get pods
```

`--server-side` est nécessaire : les CRD d'Argo CD sont trop volumineuses pour un `kubectl apply` classique.

### 4.2 Ouvrir l'interface web (facultatif)

```bash
# Mot de passe initial de l'utilisateur admin
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# Tunnel vers l'interface
kubectl -n argocd port-forward svc/argocd-server 8080:443
```

Sur la VM distante, ouvrez un tunnel SSH depuis votre poste, puis allez sur <https://localhost:8080> (certificat autosigné) avec l'utilisateur `admin` :

```bash
ssh -L 8080:localhost:8080 etudiant@<IP de la VM>
```

### 4.3 Créer l'Application

L'[Application](apps/yelb-prod.yaml) décrit ce qu'Argo CD doit déployer :

| Champ | Valeur | Rôle |
|---|---|---|
| `sources[0]` | `helm/yelb` + `values-prod.yaml` | Le chart du TP 3. `valuesObject.db.existingSecret` lui dit d'utiliser le Secret `yelb-db-credentials` au lieu de créer le sien |
| `sources[1]` | `gitops/secrets/yelb-prod` | Le SealedSecret, appliqué tel quel |
| `targetRevision` | `main` | Branche suivie |
| `destination.namespace` | `yelb-prod` | Créé au besoin (`CreateNamespace=true`) |
| `syncPolicy.automated.prune` | `true` | Ce qui disparaît de Git disparaît du cluster |
| `syncPolicy.automated.selfHeal` | `true` | Ce qui est modifié à la main est remis comme dans Git |

C'est le **seul** `kubectl apply` du TP. Tout le reste passera par Git.

```bash
kubectl apply -f gitops/apps/yelb-prod.yaml

# Suivre la synchronisation : attendre SYNC=Synced et HEALTH=Healthy
kubectl -n argocd get applications -w
```

Ce qu'Argo CD a créé :

```bash
kubectl -n yelb-prod get sealedsecret,secret,pods,pvc,ingress,certificate

# Le contrôleur a déchiffré le SealedSecret en un Secret classique
kubectl -n yelb-prod get secret yelb-db-credentials -o jsonpath='{.data.POSTGRES_PASSWORD}' | base64 -d; echo

# État détaillé de l'Application
kubectl -n argocd describe application yelb-prod
```

L'appli répond sur <https://demo.prenom.lab-cesi.fr>.

> L'API Argo CD est en `argoproj.io/v1alpha1`. Ce n'est pas une ancienne version : c'est toujours la seule version des CRD d'Argo CD, en 3.x comme avant. Pareil pour `bitnami.com/v1alpha1` chez Sealed Secrets.

---

## 5. Vivre en GitOps : changer, réparer, revenir en arrière

### 5.1 Changer quelque chose : par un commit

Passer l'API de 3 à 2 replicas :

```bash
# Dans helm/yelb/values-prod.yaml : appserver.replicaCount: 3 -> 2
sed -i '/^appserver:/,/^[a-z]/ s/replicaCount: 3/replicaCount: 2/' helm/yelb/values-prod.yaml
git commit -am "chore: API à 2 replicas"
git push
```

Argo CD interroge le dépôt toutes les 3 minutes. Pour ne pas attendre, on force une relecture :

```bash
kubectl -n argocd annotate application yelb-prod argocd.argoproj.io/refresh=normal --overwrite

kubectl -n yelb-prod get deploy prod-yelb-appserver -w          # 3 -> 2
# Application à deux sources : une révision par source, toutes deux = dernier commit
kubectl -n argocd get application yelb-prod -o jsonpath='{.status.sync.revisions}'; echo
git log -1 --format=%H
```

### 5.2 Une modification à la main est annulée (selfHeal)

```bash
kubectl -n yelb-prod scale deploy/prod-yelb-appserver --replicas=5
kubectl -n yelb-prod get deploy prod-yelb-appserver -w          # revient aussitôt à la valeur de Git
```

Le cluster ne dérive jamais de Git. Pour changer quelque chose, il faut passer par un commit.

### 5.3 Revenir en arrière : git revert

Le retour arrière ne passe plus par `helm rollback` : on annule le commit, et Argo CD suit.

```bash
git log --oneline -3
git revert --no-edit HEAD
git push
kubectl -n argocd annotate application yelb-prod argocd.argoproj.io/refresh=normal --overwrite
```

L'historique Git est l'historique des déploiements :

```bash
kubectl -n argocd get application yelb-prod -o jsonpath='{range .status.history[*]}{.id}  {.deployedAt}  {.revisions}{"\n"}{end}'
```

### 5.4 Changer un secret

On rechiffre avec kubeseal (étape 2.3), on commite et on pousse le nouveau SealedSecret. Le contrôleur met à jour le Secret. Pour que PostgreSQL relise la valeur, il faut redémarrer son pod : `kubectl -n yelb-prod rollout restart deploy/prod-yelb-db`. Dans ce TP, la valeur reste imposée par l'API.

---

## 6. Dépannage

| Symptôme | Commande | Cause probable |
|---|---|---|
| Application `Unknown` / `ComparisonError` | `kubectl -n argocd describe application yelb-prod` | Dépôt inaccessible (URL fausse ou dépôt privé), ou chemin `path` inexistant sur la branche |
| Dépôt privé | | Déclarer le dépôt avec un jeton : `argocd repo add https://github.com/<compte>/<dépôt>.git --username <compte> --password <jeton>`, ou un Secret labellisé `argocd.argoproj.io/secret-type: repository` |
| Application `OutOfSync` qui ne bouge pas | `kubectl -n argocd get application yelb-prod -o yaml` | Commit pas encore lu : forcer `argocd.argoproj.io/refresh=normal`. Vérifier que le push est sur `targetRevision` |
| `HEALTH=Progressing` qui dure, pods tous `Running` | `kubectl -n yelb-prod get ingress` (colonne ADDRESS) | L'Ingress n'a pas d'adresse : Traefik n'a pas d'IP de LoadBalancer. Normal sur kind, pas sur k3s (ServiceLB) |
| Certificat `READY=False`, Application `Progressing` | Section 8 du [README principal](../README.md) | DNS, port 80, ou ClusterIssuer absent |
| Pod base `CreateContainerConfigError` : `secret "yelb-db-credentials" not found` | `kubectl -n yelb-prod describe sealedsecret yelb-db-credentials` | Le SealedSecret n'a pas pu être déchiffré, voir la ligne suivante |
| SealedSecret : `no key could decrypt secret` | `kubectl -n kube-system logs deploy/sealed-secrets-controller` | Chiffré pour un **autre** cluster (l'exemple du dépôt par ex.), ou sous un autre nom ou namespace : refaire l'étape 2.3 |
| Ressources « possédées » par Helm, conflits | `helm list -A` | La release du TP 3 tourne encore dans `yelb-prod` : `helm uninstall prod -n yelb-prod` |
| `kubeseal: cannot fetch certificate` | `kubectl -n kube-system get svc sealed-secrets-controller` | Contrôleur absent, ou installé sous un autre nom : ajouter `--controller-name` / `--controller-namespace` |

---

## 7. Tout supprimer

```bash
# L'Application et tout ce qu'elle a déployé (grâce au finalizer)
kubectl delete -f gitops/apps/yelb-prod.yaml
kubectl delete namespace yelb-prod

# Argo CD
kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.6.1/manifests/install.yaml
kubectl delete namespace argocd

# Sealed Secrets (la clé privée est perdue : gardez la sauvegarde de l'étape 2.4 si besoin)
kubectl delete -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.41.2/controller.yaml
```
