# TP Terraform — Avancé : Backend distant, Lifecycle et CI/CD GitHub Actions

> **Objectif** : Sécuriser et automatiser l'infrastructure des TP précédents (VPC, EC2 via module, S3) en migrant le state vers un backend S3 distant avec verrouillage, en protégeant une ressource avec un `lifecycle`, et en mettant en place une pipeline CI/CD GitHub Actions capable de créer **et** détruire l'infrastructure.
> **Durée estimée** : 45 min
> **Prérequis** : Avoir terminé le TP2 (VPC + S3 + module `ec2-instance` appelé pour `dev` et `prod`)

---

## Sommaire

1. [Rappel du point de départ](#1-rappel-du-point-de-départ)
2. [Partie 1 — Backend S3 distant avec verrouillage natif](#2-partie-1--backend-s3-distant-avec-verrouillage-natif)
3. [Partie 2 — Protéger une ressource avec `lifecycle`](#3-partie-2--protéger-une-ressource-avec-lifecycle)
4. [Partie 3 (optionnel) — Gestion des secrets avec AWS Secrets Manager](#4-partie-3-optionnel--gestion-des-secrets-avec-aws-secrets-manager)
5. [Partie 4 — Pipeline CI/CD avec GitHub Actions](#5-partie-4--pipeline-cicd-avec-github-actions)
6. [Tester la pipeline](#6-tester-la-pipeline)
7. [Nettoyer les ressources](#7-nettoyer-les-ressources)
8. [Récapitulatif](#8-récapitulatif)

---

## 1. Rappel du point de départ

Vous partez du projet du TP2 :

```
tp-terraform/
├── main.tf                      # VPC, S3, appels des modules EC2
└── modules/
    └── ec2-instance/
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

Jusqu'ici, le state Terraform (`terraform.tfstate`) est resté **en local**, sur votre machine. C'est un problème dès qu'on travaille à plusieurs ou depuis une CI : il faut un **backend distant partagé**.

---

## 2. Partie 1 — Backend S3 distant avec verrouillage natif

### Pourquoi ?

- Le state local n'est pas partagé : si une CI/CD ou un collègue lance `terraform apply`, il ne voit pas le state que vous avez sur votre poste → risque de recréer les ressources en double.
- Un backend S3 centralise le state pour tout le monde (humains + pipeline).
- Le **verrou** (lock) empêche deux `apply` de s'exécuter en même temps sur le même state, ce qui corromprait le fichier.

> 💡 Depuis Terraform 1.10, le backend `s3` sait gérer le verrouillage **nativement** (option `use_lockfile`), sans avoir besoin d'une table DynamoDB séparée comme c'était le cas avant. C'est cette approche qu'on utilise ici.

### Étape 1 — Créer le bucket de state (hors Terraform du projet)

Ce bucket doit exister **avant** de configurer le backend dessus (problème de l'œuf et la poule). On le crée donc rapidement à la main, via l'AWS CLI :

```bash
BUCKET_NAME="mon-bucket-tfstate-$(openssl rand -hex 4)"
echo $BUCKET_NAME > .bucket-state-name.txt

aws s3api create-bucket \
  --bucket $BUCKET_NAME \
  --region eu-west-1 \
  --create-bucket-configuration LocationConstraint=eu-west-1

# Versioning : indispensable pour pouvoir revenir en arrière si le state est corrompu
aws s3api put-bucket-versioning \
  --bucket $BUCKET_NAME \
  --versioning-configuration Status=Enabled

# Chiffrement par défaut du bucket
aws s3api put-bucket-encryption \
  --bucket $BUCKET_NAME \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
  }'

# Blocage de tout accès public (le state contient des infos sensibles)
aws s3api put-public-access-block \
  --bucket $BUCKET_NAME \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
```

Notez le nom généré, vous en aurez besoin juste après.

### Étape 2 — Configurer le backend dans `main.tf`

En haut de `main.tf`, dans le bloc `terraform { ... }`, ajoutez le backend :

```hcl
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket       = "mon-bucket-tfstate-xxxxxxxx" # remplacez par le nom réel du bucket créé
    key          = "tp-terraform/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true # verrouillage natif S3, plus besoin de DynamoDB
  }
}
```

### Étape 3 — Migrer le state local vers le backend distant

```bash
terraform init -migrate-state
```

Terraform détecte que le backend a changé et vous propose de copier le state local existant vers S3. Répondez `yes`.

### Vérifier

```bash
aws s3 ls s3://mon-bucket-tfstate-0b3e0db7/tp-terraform/
```

Vous devez voir apparaître `terraform.tfstate`. Votre state n'est plus en local, il est maintenant centralisé et verrouillable.

> ⚠️ **Attention** : le fichier `.bucket-state-name.txt` et le nom du bucket ne doivent pas être perdus. Le bucket de state n'est volontairement **pas géré par ce même projet Terraform** (sinon on pourrait le détruire avec `terraform destroy`, ce qui supprimerait le state qui décrit... lui-même).

---

## 3. Partie 2 — Protéger une ressource avec `lifecycle`

### Pourquoi ?

Le bloc `lifecycle` permet de changer le comportement par défaut de Terraform sur une ressource précise : empêcher sa suppression accidentelle, ignorer certains changements détectés en dehors de Terraform, ou forcer une recréation avant destruction pour éviter une coupure de service.

On applique ici deux comportements différents, un par environnement, sur les instances EC2 gérées par le module `ec2-instance`.

### Étape 1 — Protéger l'instance `prod` contre la destruction

Le module `ec2-instance` ne gère pas encore `lifecycle` : on l'ajoute dans `modules/ec2-instance/main.tf`, en le rendant paramétrable :

```hcl
resource "aws_instance" "cette_instance" {
  ami                         = var.ami
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.security_group_ids
  associate_public_ip_address = true

  tags = merge(
    {
      Name = var.nom
    },
    var.tags_supplementaires
  )

  lifecycle {
    prevent_destroy        = true
    create_before_destroy   = true
    ignore_changes          = [ami] # une mise à jour d'AMI ne doit pas recréer l'instance automatiquement
  }
}
```

> 💡 `prevent_destroy` ne peut **pas** être une variable dynamique classique dans certaines versions de Terraform (les arguments de `lifecycle` doivent être des valeurs littérales connues au moment du plan). Si votre version de Terraform refuse `var.protection_destruction` ici, mettez directement `prevent_destroy = true` en dur dans une copie du module dédiée à la prod, ou dupliquez le bloc `lifecycle` pour l'environnement `prod` uniquement.

### Étape 2 — Activer la protection uniquement pour `prod`

Dans `main.tf` (racine), sur l'appel du module `ec2_prod` :

```hcl
module "ec2_prod" {
  source = "./modules/ec2-instance"

  nom                    = "mon-ec2-prod"
  ami                    = "ami-0905a3c97561e0b69"
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.mon_subnet.id
  security_group_ids     = [aws_security_group.mon_sg.id]
  protection_destruction = true

  tags_supplementaires = {
    Environment = "prod"
  }
}
```

L'instance `dev`, elle, garde `protection_destruction = false` (valeur par défaut) : on peut la détruire librement.

### Tester

```bash
terraform plan
```

Puis essayez (juste pour comprendre le mécanisme, sans vraiment le faire) :

```bash
terraform destroy -target=module.ec2_prod.aws_instance.cette_instance
```

Terraform doit **refuser** avec une erreur du type `Instance cannot be destroyed` grâce à `prevent_destroy`.

---

## 4. Partie 3 (optionnel) — Gestion des secrets avec AWS Secrets Manager

C'est possible d'intégrer un secret manager avec Terraform, aussi bien **AWS Secrets Manager** que **HashiCorp Vault** (provider `hashicorp/vault`). Deux logiques différentes existent :

- **Lire** un secret déjà existant dans Secrets Manager/Vault, pour l'injecter dans une ressource (ex : mot de passe de base de données). C'est le cas d'usage le plus courant et le plus sûr.
- **Créer** le secret depuis Terraform lui-même — possible, mais attention : la valeur du secret finit alors **en clair dans le state**, sauf si le backend est chiffré (ce qui est notre cas ici avec `encrypt = true`) et l'accès au bucket restreint.

### Exemple : lire un secret existant (AWS Secrets Manager)

```hcl
data "aws_secretsmanager_secret" "db_password" {
  name = "tp-terraform/db-password"
}

data "aws_secretsmanager_secret_version" "db_password" {
  secret_id = data.aws_secretsmanager_secret.db_password.id
}

# Utilisation, par exemple dans des variables d'environnement de l'EC2 via user_data :
# password = data.aws_secretsmanager_secret_version.db_password.secret_string
```

Le secret doit être créé au préalable (manuellement, ou via un pipeline séparé dédié aux secrets — pas dans le même `apply` que l'infra applicative) :

```bash
aws secretsmanager create-secret \
  --name tp-terraform/db-password \
  --secret-string "un-mot-de-passe-fort"
```

> ⚠️ Ne mettez jamais un secret en clair dans un fichier `.tf` versionné sur Git. Ce module n'est présenté qu'à titre d'exemple pour ce TP ; son usage réel dans la pipeline CI/CD (partie suivante) reste optionnel et n'est pas requis pour valider le TP.

---

## 5. Partie 4 — Pipeline CI/CD avec GitHub Actions

### Objectif

Une pipeline qui :
- exécute `terraform plan` automatiquement sur chaque Pull Request,
- exécute `terraform apply` automatiquement quand le code est mergé sur `main`,
- permet de lancer un `terraform destroy` **manuellement**, depuis l'interface GitHub Actions, à la demande.

### Étape 1 — Créer un utilisateur IAM dédié à la CI

Créez un utilisateur IAM avec des accès programmatiques (ou mieux, une fédération OIDC — voir la remarque en fin de section) et récupérez son Access Key / Secret Key.

### Étape 2 — Ajouter les secrets dans le repo GitHub

Dans **Settings → Secrets and variables → Actions**, ajoutez :

| Nom du secret | Valeur |
|---|---|
| `AWS_ACCESS_KEY_ID` | Access key de l'utilisateur CI |
| `AWS_SECRET_ACCESS_KEY` | Secret key de l'utilisateur CI |
| `AWS_REGION` | `eu-west-1` |
| `TF_STATE_BUCKET` | le nom du bucket créé en Partie 1 |

### Étape 3 — Créer le fichier de workflow

Créez `.github/workflows/terraform.yml` :

```yaml
name: Terraform CI/CD

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]
  workflow_dispatch:
    inputs:
      action:
        description: "Action à exécuter"
        required: true
        default: "plan"
        type: choice
        options:
          - plan
          - apply
          - destroy

env:
  AWS_REGION: ${{ secrets.AWS_REGION }}
  TF_IN_AUTOMATION: "true"

jobs:
  terraform:
    name: Terraform ${{ github.event.inputs.action || 'plan/apply' }}
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: tp-terraform

    steps:
      - name: Checkout du code
        uses: actions/checkout@v4

      - name: Configurer les identifiants AWS
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Installer Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.10.0"

      - name: Terraform Init
        run: terraform init

      - name: Terraform Format Check
        run: terraform fmt -check
        continue-on-error: true

      - name: Terraform Validate
        run: terraform validate

      # ── Cas 1 : Pull Request → juste un plan, pas d'apply ──────
      - name: Terraform Plan
        if: github.event_name == 'pull_request' || github.event.inputs.action == 'plan'
        run: terraform plan -no-color

      # ── Cas 2 : Push sur main, ou déclenchement manuel "apply" ──
      - name: Terraform Apply
        if: >
          (github.event_name == 'push' && github.ref == 'refs/heads/main') ||
          github.event.inputs.action == 'apply'
        run: terraform apply -auto-approve

      # ── Cas 3 : Déclenchement manuel "destroy" uniquement ───────
      - name: Terraform Destroy
        if: github.event.inputs.action == 'destroy'
        run: terraform destroy -auto-approve
```

### Points clés du workflow

- **`pull_request`** → seulement un `plan`, jamais d'`apply` ni de `destroy` : on ne modifie jamais l'infra depuis une PR non mergée.
- **`push` sur `main`** → `apply` automatique, car le code a été validé et mergé.
- **`workflow_dispatch`** avec un menu déroulant (`plan` / `apply` / `destroy`) → c'est ce qui permet de lancer la destruction **manuellement** depuis l'onglet **Actions** de GitHub, sans avoir besoin de pousser du code. C'est la réponse au besoin « pouvoir lancer la destruction directement sur l'interface de GitHub Actions ».
- Le state distant (Partie 1) est indispensable ici : la CI n'a pas de state local, elle doit retrouver le même state que celui utilisé en local grâce au backend S3.

> 💡 **Pour aller plus loin (sécurité)** : plutôt que des clés IAM statiques en secrets GitHub, on peut utiliser l'authentification **OIDC** (`aws-actions/configure-aws-credentials` supporte `role-to-assume`), ce qui évite de stocker un secret AWS de longue durée dans GitHub.

---

## 6. Tester la pipeline

1. Poussez le code (avec le backend configuré et le workflow) sur une branche, ouvrez une Pull Request → vérifiez que seul un `plan` s'exécute.
2. Mergez la PR sur `main` → vérifiez que l'`apply` se déclenche automatiquement et crée l'infrastructure.
3. Allez dans l'onglet **Actions** du repo → sélectionnez le workflow **Terraform CI/CD** → **Run workflow** → choisissez `destroy` dans le menu déroulant → lancez.
4. Vérifiez dans la console AWS (ou avec `aws ec2 describe-instances`) que les ressources non protégées (`dev`) ont bien été détruites, et que l'instance `prod` protégée par `prevent_destroy` fait échouer le job (comportement attendu, à commenter/adapter si vous voulez réellement tout nettoyer en fin de TP).

---

## 7. Nettoyer les ressources

Pour un nettoyage complet en fin de TP (y compris l'instance `prod` protégée) :

```bash
# 1. Retirer temporairement la protection avant destruction
#    (repassez protection_destruction à false sur le module ec2_prod, puis :)
terraform apply

# 2. Détruire l'infrastructure applicative
terraform destroy

# 3. Supprimer le bucket de state (créé hors Terraform en Partie 1)
aws s3 rm s3://mon-bucket-tfstate-xxxxxxxx --recursive
aws s3api delete-bucket --bucket mon-bucket-tfstate-xxxxxxxx --region eu-west-1
```

---

## 8. Récapitulatif

| Concept | Ce que ça apporte |
|---|---|
| Backend `s3` | Centralise le state Terraform, accessible par tous (humains + CI) |
| `use_lockfile` | Verrouillage natif du state directement sur S3, sans DynamoDB |
| `terraform init -migrate-state` | Migre un state local existant vers le backend distant |
| `lifecycle { prevent_destroy }` | Empêche la suppression accidentelle d'une ressource critique (ex : `prod`) |
| `lifecycle { create_before_destroy }` | Recrée la ressource avant de détruire l'ancienne, pour limiter la coupure |
| `lifecycle { ignore_changes }` | Ignore certains changements détectés hors Terraform, pour éviter des recréations inutiles |
| Secrets Manager / Vault (`data` source) | Lire un secret existant depuis Terraform sans l'écrire en clair dans le code |
| GitHub Actions `workflow_dispatch` | Permet de choisir manuellement une action (`plan`/`apply`/`destroy`) depuis l'interface GitHub |
| Pipeline plan (PR) / apply (main) / destroy (manuel) | Automatise le cycle de vie complet de l'infrastructure |

### Structure finale du projet

```
tp-terraform/
├── .github/
│   └── workflows/
│       └── terraform.yml        # Pipeline CI/CD (plan / apply / destroy)
├── main.tf                       # VPC, S3, backend distant, appels des modules EC2
└── modules/
    └── ec2-instance/
        ├── main.tf                # Ressource aws_instance + bloc lifecycle
        ├── variables.tf           # Paramètres du module (dont protection_destruction)
        └── outputs.tf
```

---

> 💡 **Pour aller plus loin** : ajoutez un job GitHub Actions séparé qui poste automatiquement le résultat du `terraform plan` en commentaire sur la Pull Request (avec `actions/github-script` ou l'action `terraform-plan-comment`), pour faciliter la revue de code par l'équipe avant merge.