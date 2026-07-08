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

