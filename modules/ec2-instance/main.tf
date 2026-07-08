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
    prevent_destroy        = false
    create_before_destroy   = true
    ignore_changes          = [ami] # une mise à jour d'AMI ne doit pas recréer l'instance automatiquement
  }
}