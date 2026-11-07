output "client_id" {
  value = aws_instance.client.id
}

output "db_identifier" {
  value = aws_db_instance.main.identifier
}

output "table_name" {
  value = aws_dynamodb_table.notes.name
}
