# Insert access_key and secret key of Aws account
provider "aws" {
  region     = "ap-southeast-1"
  access_key = "xxxxxxxxxxxxxxxxxx"
  secret_key = "xxxxxxxxxxxxxxxxxxxx"
}

 # 1. Create vpc

resource "aws_vpc" "prod-vpc" {
  cidr_block = "10.0.0.0/16"
  tags = {
    Name = "production"
  }
}

# 2. Create Internet Gateway

resource "aws_internet_gateway" "gw" {
  vpc_id = aws_vpc.prod-vpc.id

}

# 3. Create Custom Route Table

resource "aws_route_table" "prod-route-table" {
  vpc_id = aws_vpc.prod-vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.gw.id
  }

  route {
    ipv6_cidr_block = "::/0"
    gateway_id      = aws_internet_gateway.gw.id
  }

  tags = {
    Name = "Prod-rt"
  }
}

# 4. Create a Subnet 

resource "aws_subnet" "subnet-1" {
  vpc_id            = aws_vpc.prod-vpc.id
  cidr_block        = "10.0.1.0/24"
  availability_zone = "ap-southeast-1a"

  tags = {
    Name = "prod-subnet-1"
  }
}

resource "aws_subnet" "subnet-2" {
  vpc_id            = aws_vpc.prod-vpc.id
  cidr_block        = "10.0.2.0/24"
  availability_zone = "ap-southeast-1b"

  tags = {
    Name = "prod-subnet-2"
  }
}

# 5. Associate subnet with Route Table
resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.subnet-1.id
  route_table_id = aws_route_table.prod-route-table.id
}

# 6. Create Security Group to allow port 22,80,443, 3306
resource "aws_security_group" "allow_web" {
  name        = "allow_web_traffic"
  description = "Allow Web inbound traffic"
  vpc_id      = aws_vpc.prod-vpc.id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
      description = "MySQL"
      from_port = 3306
      protocol = "tcp"
      to_port = 3306
      cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "allow_web"
  }
}


# 7. Create a network interface with an ip in the subnet that was created in step 4

resource "aws_network_interface" "web-server-nic" {
  subnet_id       = aws_subnet.subnet-1.id
  private_ips     = ["10.0.1.50"]
  security_groups = [aws_security_group.allow_web.id]

}

# 8. Assign an elastic IP to the network interface created in step 7

resource "aws_eip" "one" {
  vpc                       = true
  network_interface         = aws_network_interface.web-server-nic.id
  associate_with_private_ip = "10.0.1.50"
  depends_on                = [aws_internet_gateway.gw]
}

output "server_public_ip" {
  value = aws_eip.one.public_ip
}

resource "aws_db_subnet_group" "db-subnet" {
  name       = "main"
  subnet_ids = [aws_subnet.subnet-1.id, aws_subnet.subnet-2.id]

  tags = {
    Name = "db_subnet_group"
  }
}

# 9. Create AWS RDS

resource "aws_db_instance" "db-server" {
    instance_class = "db.t2.micro"
    allocated_storage = 20
    db_subnet_group_name = aws_db_subnet_group.db-subnet.name
    vpc_security_group_ids = [aws_security_group.allow_web.id]
    allow_major_version_upgrade = false
    auto_minor_version_upgrade = true
    backup_retention_period = 0
    identifier = "sample-app-db"
    name = "sample"
    engine = "mysql"
    engine_version = "8.0.23"
    username = "admin"
    password = "12345678"
    monitoring_interval = 0
    multi_az = false
    port = 3306
    publicly_accessible = false
    skip_final_snapshot = true
      
}
# 10. Get db instance endpoint

output "rds_endpoint" {
  value = aws_db_instance.db-server.endpoint
}

# 11. Create web server and install/enable apache

resource "aws_instance" "web-server-instance" {
  ami               = "ami-03326c3f2f37e56a4"
  instance_type     = "t2.micro"
  availability_zone = "ap-southeast-1a"
  key_name          = "main-key"

  network_interface {
    device_index         = 0
    network_interface_id = aws_network_interface.web-server-nic.id
  }

  user_data = <<-EOF
                #!/bin/bash
                sudo yum update -y
                sudo amazon-linux-extras install -y lamp-mariadb10.2-php7.2 php7.2
                sudo yum install -y git
                sudo yum install -y httpd
                sudo systemctl start httpd
                sudo systemctl enable httpd
                sudo usermod -a -G apache ec2-user
                sudo chown -R ec2-user:apache /var/www
                sudo chmod 2775 /var/www 
                find /var/www -type d -exec sudo chmod 2775 {} \;
                find /var/www -type f -exec sudo chmod 0664 {} \;
                cd /var/www
                mkdir inc
                cd inc
                /bin/cat <<EOM >dbinfo.inc
                  <?php

                    define('DB_SERVER', '${aws_db_instance.db-server.endpoint}');
                    define('DB_USERNAME', '${aws_db_instance.db-server.username}');
                    define('DB_PASSWORD', '${aws_db_instance.db-server.password}');
                    define('DB_DATABASE', '${aws_db_instance.db-server.name}');

                  ?>
                  
                EOM
                cd /var/www/html
                git clone https://github.com/quocdon/sample-page.git
                cd sample-page
                cp SamplePage.php /var/www/html
                EOF
  tags = {
    Name = "web-server"
  }
}




