# TP Kubernetes : Yelb (web + API + PostgreSQL)

Yelb est une petite appli de vote « où manger ce midi ». Elle compte quatre composants, tous en images publiques :

| Composant | Image | Port | Service | Exposition |
|---|---|---|---|---|
| Interface web (Angular + nginx) | `mreferre/yelb-ui:0.10` | 80 | `yelb-ui` | ClusterIP + **Ingress Traefik** |
| API (Ruby / Sinatra) | `mreferre/yelb-appserver:0.7` | 4567 | `yelb-appserver` | ClusterIP |
| Base PostgreSQL 10 | `mreferre/yelb-db:0.6` | 5432 | `yelb-db` | ClusterIP + PVC 1 Gi |
| Cache Redis | `redis:7.4-alpine` | 6379 | `redis-server` | ClusterIP |

```
navigateur ──► Traefik (Ingress) ──► yelb-ui ──/api──► yelb-appserver ──► yelb-db (PVC)
                                                                 └──────► redis-server
```

## Prérequis

- Un contrôleur Ingress **Traefik** avec l'IngressClass `traefik` (présent par défaut sur k3s) : `kubectl get ingressclass`.
- Un enregistrement DNS qui pointe vers l'IP publique de Traefik. Le nom est défini dans `50-ingress.yaml` : `demo.killian-stein-3.lab-cesi.fr`. Chaque étudiant y met le sien.

## Déployer

```bash
kubectl apply -k .          # ou : kubectl apply -f .  (dans l'ordre des numéros)
kubectl -n yelb get pods,svc,pvc,ingress
```

Ouvrir ensuite <http://demo.killian-stein-3.lab-cesi.fr>, en HTTP : pas encore de TLS.

Pour tester sans DNS, on peut forcer le nom d'hôte :

```bash
curl -H "Host: demo.killian-stein-3.lab-cesi.fr" http://<IP de Traefik>/api/getvotes
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
| `50-ingress.yaml` | Ingress Traefik (HTTP, entrée `web`) vers le front |
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
5. Pour aller plus loin : ajouter le HTTPS avec cert-manager (entrée `websecure` + bloc `tls` dans l'Ingress), et remplacer le Deployment PostgreSQL par un StatefulSet.
