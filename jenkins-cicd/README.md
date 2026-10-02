# Jenkins CI/CD Automation

Centralized Jenkins pipeline repository for managing CI/CD and deployment
automation for Frontend, Backend and OTA applications.

## Architecture

Developer
   |
   +------------------+
   |                  |
Frontend            Backend             OTA
   |                  |                  |
   +---------> Jenkins <-----------------+
                  |
          +-------+-------+
          |       |       |
       Build    Test    Deploy
          |       |       |
          +-------+-------+
                  |
             Linux Server
                  |
              Nginx / Apps


## Projects

### Frontend Pipeline

Pipeline responsible for:

1. Checkout source code
2. Install dependencies
3. Build frontend
4. Validate build
5. Backup existing deployment
6. Deploy build
7. Verify deployment
8. Reload Nginx

### Backend Pipeline

Pipeline responsible for:

1. Checkout source code
2. Maven build
3. Run tests
4. Package JAR
5. Transfer artifact
6. Deploy JAR
7. Restart application service
8. Health check
9. Archive deployment

### OTA Pipeline

Pipeline responsible for:

1. Checkout OTA configuration
2. Validate OTA package
3. Identify version
4. Upload firmware
5. Create/update version file
6. Verify uploaded files
7. Report deployment status


## Technologies

- Jenkins
- Git / GitLab
- GitHub
- Maven
- Docker
- Linux
- Bash
- Nginx
- SSH
- CI/CD


## Pipeline Management

| Pipeline | Purpose |
|---|---|
| Frontend | Build and deploy frontend applications |
| Backend | Build and deploy backend services |
| OTA | Firmware/package deployment |
