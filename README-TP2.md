# TP Terraform — Intermédiaire : for_each et Modules

> **Objectif** : Reprendre l'infrastructure du TP1 (VPC, EC2, S3), transformer l'instance EC2 en `for_each` pour créer un environnement **dev** et un environnement **prod**, puis extraire cette logique dans un **module réutilisable**.
> **Durée estimée** : 35 min
> **Prérequis** : Avoir terminé le TP1 (VPC + EC2 + S3 fonctionnel)

---

## Sommaire

1. [Rappel du point de départ](#1-rappel-du-point-de-départ)
2. [Partie 1 — Transformer l'EC2 en `for_each` (dev / prod)](#2-partie-1--transformer-lec2-en-for_each-dev--prod)
3. [Partie 2 — Extraire l'EC2 dans un module réutilisable](#3-partie-2--extraire-lec2-dans-un-module-réutilisable)
4. [Partie 3 — Appeler le module deux fois](#4-partie-3--appeler-le-module-deux-fois)
5. [Déployer](#5-déployer)
6. [Nettoyer les ressources](#6-nettoyer-les-ressources)
7. [Récapitulatif](#7-récapitulatif)

---

## 1. Rappel du point de départ

Vous partez du `main.tf` du TP1, qui contient déjà :
- un `aws_vpc`, un `aws_subnet`, un `aws_internet_gateway`, une `aws_route_table`
- un `aws_security_group`
- **une seule** instance `aws_instance.mon_ec2`
- un bucket `aws_s3_bucket.mon_bucket`

L'objectif de ce TP est de faire évoluer **uniquement la partie EC2**, sans toucher au reste (VPC, S3).

```bash
cd tp-terraform
```

---

## 2. Partie 1 — Transformer l'EC2 en `for_each` (dev / prod)

### Pourquoi `for_each` ?

Plutôt que de dupliquer le bloc `resource "aws_instance"`, on utilise `for_each` pour créer **plusieurs instances à partir d'une seule déclaration**, en faisant varier certains paramètres (nom, type d'instance...).

### Étape 1 — Supprimer l'ancienne instance unique

Dans `main.tf`, supprimez (ou commentez) le bloc suivant :

```hcl
resource "aws_instance" "mon_ec2" {
  ami                         = "ami-0905a3c97561e0b69"
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.mon_subnet.id
  vpc_security_group_ids      = [aws_security_group.mon_sg.id]
  associate_public_ip_address = true

  tags = {
    Name = "mon-ec2-tp"
  }
}
```

### Étape 2 — Créer une variable locale pour les environnements

Ajoutez ce bloc `locals` juste avant la ressource EC2 :

```hcl
locals {
  environnements = {
    dev = {
      instance_type = "t3.micro"
    }
    prod = {
      instance_type = "t3.micro" # reste t3.micro pour le Free Tier
    }
  }
}
```

### Étape 3 — Recréer l'EC2 avec `for_each`

```hcl
resource "aws_instance" "ec2" {
  for_each = local.environnements

  ami                         = "ami-0905a3c97561e0b69"
  instance_type               = each.value.instance_type
  subnet_id                   = aws_subnet.mon_subnet.id
  vpc_security_group_ids      = [aws_security_group.mon_sg.id]
  associate_public_ip_address = true

  tags = {
    Name        = "mon-ec2-${each.key}"
    Environment = each.key
  }
}
```

> 💡 `each.key` correspond à `"dev"` ou `"prod"`, et `each.value` au bloc de paramètres associé.

### Étape 4 — Mettre à jour les outputs

Remplacez l'ancien output `ec2_ip_public` par une version qui liste toutes les IP :

```hcl
output "ec2_ip_public" {
  description = "Adresses IP publiques des instances EC2 par environnement"
  value       = { for env, instance in aws_instance.ec2 : env => instance.public_ip }
}
```

### Tester

```bash
terraform plan
```

Vous devez voir Terraform annoncer la **création de 2 instances** (`aws_instance.ec2["dev"]` et `aws_instance.ec2["prod"]`) et la **destruction** de l'ancienne `aws_instance.mon_ec2`.

---

## 3. Partie 2 — Extraire l'EC2 dans un module réutilisable

### Pourquoi un module ?

Le `for_each` fonctionne, mais si demain vous voulez réutiliser cette logique EC2 dans un autre projet, il faudra copier-coller le code. Un **module** encapsule cette logique pour la rendre réutilisable et paramétrable.

### Étape 1 — Créer la structure du module

```bash
mkdir -p modules/ec2-instance
```

Structure finale attendue :

```
tp-terraform/
├── main.tf
└── modules/
    └── ec2-instance/
        ├── main.tf
        ├── variables.tf
        └── outputs.tf
```

### Étape 2 — `modules/ec2-instance/variables.tf`

```hcl
variable "nom" {
  description = "Nom de l'instance (utilisé dans le tag Name)"
  type        = string
}

variable "ami" {
  description = "ID de l'AMI à utiliser"
  type        = string
}

variable "instance_type" {
  description = "Type d'instance EC2"
  type        = string
  default     = "t3.micro"
}

variable "subnet_id" {
  description = "ID du sous-réseau"
  type        = string
}

variable "security_group_ids" {
  description = "Liste des IDs de security groups"
  type        = list(string)
}

variable "tags_supplementaires" {
  description = "Tags additionnels à fusionner avec le tag Name"
  type        = map(string)
  default     = {}
}
```

### Étape 3 — `modules/ec2-instance/main.tf`

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
}
```

### Étape 4 — `modules/ec2-instance/outputs.tf`

```hcl
output "id" {
  description = "ID de l'instance créée"
  value       = aws_instance.cette_instance.id
}

output "ip_publique" {
  description = "Adresse IP publique de l'instance"
  value       = aws_instance.cette_instance.public_ip
}
```

---

## 4. Partie 3 — Appeler le module deux fois

### Étape 1 — Supprimer le `for_each` du `main.tf` racine

Dans `main.tf`, supprimez le bloc `resource "aws_instance" "ec2" { ... }` ainsi que le `locals { environnements = ... }` (le module gère désormais chaque instance individuellement).

### Étape 2 — Appeler le module pour `dev` et `prod`

Ajoutez dans `main.tf` :

```hcl
module "ec2_dev" {
  source = "./modules/ec2-instance"

  nom                 = "mon-ec2-dev"
  ami                 = "ami-0905a3c97561e0b69"
  instance_type       = "t3.micro"
  subnet_id           = aws_subnet.mon_subnet.id
  security_group_ids  = [aws_security_group.mon_sg.id]

  tags_supplementaires = {
    Environment = "dev"
  }
}

module "ec2_prod" {
  source = "./modules/ec2-instance"

  nom                 = "mon-ec2-prod"
  ami                 = "ami-0905a3c97561e0b69"
  instance_type       = "t3.micro" # reste Free Tier ; en vrai on mettrait un type plus gros
  subnet_id           = aws_subnet.mon_subnet.id
  security_group_ids  = [aws_security_group.mon_sg.id]

  tags_supplementaires = {
    Environment = "prod"
  }
}
```

### Étape 3 — Mettre à jour les outputs racine

```hcl
output "ec2_dev_ip" {
  description = "IP publique de l'instance dev"
  value       = module.ec2_dev.ip_publique
}

output "ec2_prod_ip" {
  description = "IP publique de l'instance prod"
  value       = module.ec2_prod.ip_publique
}
```

> 💡 Chaque appel au module (`module "ec2_dev"` et `module "ec2_prod"`) crée sa propre instance, avec ses propres paramètres, à partir du **même code source**.

---

## 5. Déployer

```bash
# Réinitialiser pour que Terraform détecte le nouveau module
terraform init

# Vérifier ce qui va être créé / détruit / modifié
terraform plan

# Appliquer les changements
terraform apply
```

Tapez `yes` pour confirmer.

À la fin, vous devez voir :

```
Outputs:
bucket_name  = "mon-bucket-tp-a1b2c3d4"
ec2_dev_ip   = "54.x.x.x"
ec2_prod_ip  = "54.x.x.x"
vpc_id       = "vpc-0abc123..."
```

✅ **Vous avez deux instances EC2 (dev et prod) créées via un module réutilisable.**

---

## 6. Nettoyer les ressources

```bash
terraform destroy
```

Tapez `yes` pour confirmer.

---

## 7. Récapitulatif

| Concept | Ce que ça apporte |
|---|---|
| `for_each` | Créer plusieurs ressources similaires à partir d'une seule déclaration, en itérant sur une map ou un set |
| `each.key` / `each.value` | Accéder à la clé et à la valeur courantes dans la boucle `for_each` |
| Module | Encapsuler un bloc de ressources dans un composant réutilisable, paramétrable via des `variable` |
| `source = "./modules/..."` | Appeler un module local |
| Appels multiples d'un module | Réutiliser la même logique avec des paramètres différents (ici : dev vs prod) |

### Structure finale du projet

```
tp-terraform/
├── main.tf                      # VPC, S3, appels des modules EC2
└── modules/
    └── ec2-instance/
        ├── main.tf               # Ressource aws_instance générique
        ├── variables.tf          # Paramètres du module
        └── outputs.tf            # Sorties du module
```

---

> 💡 **Pour aller plus loin** : essayez de transformer le bucket S3 en module lui aussi, ou d'ajouter une troisième variable d'environnement (`staging`) sans toucher au code du module — seulement en ajoutant un nouvel appel `module "ec2_staging" { ... }`.
