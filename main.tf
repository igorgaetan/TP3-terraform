terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    bucket       = "mon-bucket-tfstate-0b3e0db7"
    key          = "tp-terraform/terraform.tfstate"
    region       = "eu-west-1"
    encrypt      = true
    use_lockfile = true
  }
}

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

# ── OUTPUTS ──────────────────────────────────────────────
output "vpc_id" {
  description = "ID du VPC créé"
  value       = aws_vpc.mon_vpc.id
}

output "ec2_dev_ip" {
  description = "IP publique de l'instance dev"
  value       = module.ec2_dev.ip_publique
}

output "ec2_prod_ip" {
  description = "IP publique de l'instance prod"
  value       = module.ec2_prod.ip_publique
}

output "bucket_name" {
  description = "Nom du bucket S3 créé"
  value       = aws_s3_bucket.mon_bucket.bucket
}