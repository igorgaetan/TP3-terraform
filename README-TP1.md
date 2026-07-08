# TP Terraform — Débutant : VPC, EC2 et S3 sur AWS

> **Objectif** : Créer une infrastructure AWS basique avec Terraform — un réseau (VPC), une machine virtuelle (EC2) et un espace de stockage (S3).  
> **Durée estimée** : 1h30  
> **Prérequis** : Un compte AWS actif

---

## Sommaire

1. [Installation des outils](#1-installation-des-outils)
2. [Configuration AWS CLI](#2-configuration-aws-cli)
3. [Installer Terraform](#3-installer-terraform)
4. [Partie 1 — Créer un VPC et un EC2](#4-partie-1--créer-un-vpc-et-un-ec2)
5. [Partie 2 — Ajouter un bucket S3](#5-partie-2--ajouter-un-bucket-s3)
6. [Nettoyer les ressources](#6-nettoyer-les-ressources)

---

## 1. Installation des outils

### AWS CLI

**Sur Ubuntu :**
```bash
sudo apt update
sudo apt install unzip curl -y

curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
sudo ./aws/install
```

**Sur macOS :**
```bash
curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "AWSCLIV2.pkg"
sudo installer -pkg AWSCLIV2.pkg -target /
```

Vérifier l'installation :
```bash
aws --version
# Résultat attendu : aws-cli/2.x.x ...
```

---

## 2. Configuration AWS CLI

### Créer une clé d'accès AWS

1. Connectez-vous à la **Console AWS** → [https://console.aws.amazon.com](https://console.aws.amazon.com)
2. Cliquez sur votre nom en haut à droite → **Security credentials**
3. Descendez jusqu'à **Access keys** → cliquez **Create access key**
4. Choisissez **CLI** → cochez la case → **Create**
5. **Copiez** l'`Access Key ID` et le `Secret Access Key` (vous ne pourrez plus les voir ensuite !)

### Configurer AWS CLI

```bash
aws configure
```

Remplissez les informations demandées :
```
AWS Access Key ID [None]: AKIAIOSFODNN7EXAMPLE
AWS Secret Access Key [None]: wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
Default region name [None]: eu-west-1
Default output format [None]: json
```

> 💡 **Région** : utilisez `eu-west-1` (Irlande) ou `us-east-1` (Virginie) pour ce TP.

### Tester la connexion

```bash
aws sts get-caller-identity
```

Vous devez voir votre `Account`, `UserId` et `Arn`. Si c'est le cas, la configuration est correcte ✅

---

## 3. Installer Terraform

**Sur Ubuntu :**
```bash
sudo apt install gnupg software-properties-common -y

wget -O- https://apt.releases.hashicorp.com/gpg | \
  sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

sudo apt update && sudo apt install terraform -y
```

**Sur macOS :**
```bash
brew tap hashicorp/tap
brew install hashicorp/tap/terraform
```

Vérifier l'installation :
```bash
terraform -version
# Résultat attendu : Terraform v1.x.x
```

---

## 4. Partie 1 — Créer un VPC et un EC2

### Structure du projet

Créez un dossier de travail :
```bash
mkdir tp-terraform && cd tp-terraform
```

### Fichier `main.tf`

Créez le fichier `main.tf` avec ce contenu :

```hcl
# Fournisseur AWS
provider "aws" {
  region = "eu-west-1"
}

# ── VPC ──────────────────────────────────────────────────
resource "aws_vpc" "mon_vpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "mon-vpc-tp"
  }
}

# Sous-réseau public dans le VPC
resource "aws_subnet" "mon_subnet" {
  vpc_id            = aws_vpc.mon_vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "eu-west-1a"

  tags = {
    Name = "mon-subnet-tp"
  }
}

# Passerelle Internet (pour que l'EC2 ait accès à Internet)
resource "aws_internet_gateway" "mon_igw" {
  vpc_id = aws_vpc.mon_vpc.id

  tags = {
    Name = "mon-igw-tp"
  }
}

# Table de routage
resource "aws_route_table" "ma_route_table" {
  vpc_id = aws_vpc.mon_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.mon_igw.id
  }

  tags = {
    Name = "ma-route-table-tp"
  }
}

# Associer la table de routage au sous-réseau
resource "aws_route_table_association" "assoc" {
  subnet_id      = aws_subnet.mon_subnet.id
  route_table_id = aws_route_table.ma_route_table.id
}

# ── EC2 ──────────────────────────────────────────────────
# Groupe de sécurité (pare-feu basique)
resource "aws_security_group" "mon_sg" {
  name   = "mon-sg-tp"
  vpc_id = aws_vpc.mon_vpc.id

  # Autoriser SSH entrant
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Autoriser tout le trafic sortant
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "mon-sg-tp"
  }
}

# Instance EC2
resource "aws_instance" "mon_ec2" {
  ami                         = "ami-0905a3c97561e0b69"  # Amazon Linux 2 (eu-west-1)
  instance_type               = "t2.micro"               # Éligible au Free Tier
  subnet_id                   = aws_subnet.mon_subnet.id
  vpc_security_group_ids      = [aws_security_group.mon_sg.id]
  associate_public_ip_address = true

  tags = {
    Name = "mon-ec2-tp"
  }
}

# ── OUTPUTS ──────────────────────────────────────────────
output "vpc_id" {
  description = "ID du VPC créé"
  value       = aws_vpc.mon_vpc.id
}

output "ec2_ip_public" {
  description = "Adresse IP publique de l'EC2"
  value       = aws_instance.mon_ec2.public_ip
}
```

### Déployer l'infrastructure

```bash
# Étape 1 : Initialiser Terraform (télécharge le provider AWS)
terraform init

# Étape 2 : Voir ce que Terraform va créer (sans rien faire)
terraform plan

# Étape 3 : Créer les ressources
terraform apply
```

Tapez `yes` quand Terraform vous demande confirmation.

À la fin, vous verrez les outputs :
```
Outputs:
vpc_id        = "vpc-0abc123..."
ec2_ip_public = "54.x.x.x"
```

✅ **Bravo ! Votre VPC et votre EC2 sont en ligne.**

---

## 5. Partie 2 — Ajouter un bucket S3

Maintenant on enrichit l'infrastructure en ajoutant un bucket S3.

### Modifier `main.tf`

Ajoutez ce bloc à la fin de votre `main.tf` (avant les outputs) :

```hcl
# ── S3 ───────────────────────────────────────────────────
resource "aws_s3_bucket" "mon_bucket" {
  # Le nom du bucket doit être unique dans tout AWS
  bucket = "mon-bucket-tp-${random_id.suffixe.hex}"

  tags = {
    Name = "mon-bucket-tp"
  }
}

# Génère un suffixe aléatoire pour rendre le nom unique
resource "random_id" "suffixe" {
  byte_length = 4
}

# Bloquer tout accès public (bonne pratique)
resource "aws_s3_bucket_public_access_block" "blocage" {
  bucket = aws_s3_bucket.mon_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

Ajoutez aussi cet output avec les autres :
```hcl
output "bucket_name" {
  description = "Nom du bucket S3 créé"
  value       = aws_s3_bucket.mon_bucket.bucket
}
```

### Mettre à jour le provider `random`

En haut de `main.tf`, remplacez le bloc `provider` par :

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
}

provider "aws" {
  region = "eu-west-1"
}
```

### Déployer les modifications

```bash
# Ré-initialiser pour télécharger le provider "random"
terraform init

# Voir les changements (uniquement le S3 sera ajouté)
terraform plan

# Appliquer
terraform apply
```

Tapez `yes` pour confirmer.

```
Outputs:
vpc_id        = "vpc-0abc123..."
ec2_ip_public = "54.x.x.x"
bucket_name   = "mon-bucket-tp-a1b2c3d4"
```

✅ **Votre bucket S3 est créé et sécurisé.**

---

## 6. Nettoyer les ressources

> ⚠️ **Important** : les ressources AWS coûtent de l'argent. Détruisez-les après le TP.

```bash
terraform destroy
```

Tapez `yes` pour confirmer. Toutes les ressources créées pendant ce TP seront supprimées.

---

## Récapitulatif

| Commande | Description |
|---|---|
| `terraform init` | Initialise le projet, télécharge les providers |
| `terraform plan` | Affiche ce qui va être créé/modifié/supprimé |
| `terraform apply` | Applique les changements sur AWS |
| `terraform destroy` | Supprime toutes les ressources |
| `terraform show` | Affiche l'état actuel de l'infrastructure |

---

## Structure finale du projet

```
tp-terraform/
└── main.tf          # Toute l'infrastructure : VPC, EC2, S3
```

---

> 💡 **Pour aller plus loin** : explorez les fichiers `variables.tf` (pour paramétrer votre code) et `outputs.tf` (pour séparer les sorties), ainsi que les **modules Terraform** pour réutiliser du code.
