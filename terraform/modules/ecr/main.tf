variable "app_name" { type = string }

resource "aws_ecr_repository" "app" {
  name                 = var.app_name
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration { scan_on_push = true }
  encryption_configuration    { encryption_type = "AES256" }
}

# Keep last 10 tagged images, delete untagged after 7 days
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name
  policy = jsonencode({ rules = [
    { rulePriority = 1, description = "Keep last 10 tagged images",
      selection = { tagStatus = "tagged", tagPrefixList = ["sha","v"],
        countType = "imageCountMoreThan", countNumber = 10 },
      action = { type = "expire" } },
    { rulePriority = 2, description = "Delete untagged images after 7 days",
      selection = { tagStatus = "untagged",
        countType = "sinceImagePushed", countUnit = "days", countNumber = 7 },
      action = { type = "expire" } }
  ]})
}

output "repository_url" { value = aws_ecr_repository.app.repository_url }
output "repository_arn" { value = aws_ecr_repository.app.arn }
