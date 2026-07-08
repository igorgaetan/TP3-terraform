output "id" {
  description = "ID de l'instance créée"
  value       = aws_instance.cette_instance.id
}

output "ip_publique" {
  description = "Adresse IP publique de l'instance"
  value       = aws_instance.cette_instance.public_ip
}