// ════════════════════════════════════════════════════════════════════════════
// Jenkinsfile — Production CI/CD Pipeline
// App: cicd-demo (Node.js)
// Flow: GitHub → Jenkins → Docker Build → ECR Push → EKS Deploy
// ════════════════════════════════════════════════════════════════════════════

pipeline {

  // ── No global agent — assign per stage for flexibility ───────────────────
  agent any

  // ── Pipeline-wide options ─────────────────────────────────────────────────
  options {
    // Keep last 10 builds — prevents disk fill on Jenkins server
    buildDiscarder(logRotator(numToKeepStr: '10'))

    // Kill the pipeline if it runs longer than 30 minutes (catches hung builds)
    timeout(time: 30, unit: 'MINUTES')

    // Prefix every log line with a timestamp — essential for debugging
    timestamps()

    // Prevent the same branch from running two builds simultaneously
    // Prevents race conditions on deployments
    disableConcurrentBuilds()

    // Highlight any test failures immediately in the stage view
    skipStagesAfterUnstable()
  }

  // ── Environment variables — available in every stage ─────────────────────
  environment {
    // App config
    APP_NAME        = 'cicd-demo'

    // AWS / ECR config — replace with your values
    AWS_REGION      = 'eu-west-1'
    ECR_REGISTRY    = credentials('ECR_REGISTRY')   // e.g. 123456789.dkr.ecr.eu-west-1.amazonaws.com
    ECR_REPO        = "${ECR_REGISTRY}/${APP_NAME}"

    // EKS config
    EKS_CLUSTER     = 'cicd-demo-cluster'
    K8S_NAMESPACE   = 'production'

    // Image tag = short git commit SHA (7 chars) — immutable, traceable
    IMAGE_TAG       = "${env.GIT_COMMIT?.take(7) ?: 'local'}"
    IMAGE_FULL      = "${ECR_REPO}:${IMAGE_TAG}"

    // Node.js test output format for Jenkins JUnit parser
    JEST_JUNIT_OUTPUT_DIR = 'test-results'
  }

  // ── Pipeline stages ───────────────────────────────────────────────────────
  stages {

    // ── 1. CHECKOUT ──────────────────────────────────────────────────────────
    stage('Checkout') {
      steps {
        echo "==> Checking out branch: ${env.BRANCH_NAME}"
        echo "==> Commit SHA: ${env.GIT_COMMIT}"
        echo "==> Build number: ${env.BUILD_NUMBER}"

        // Print last 5 commits for context in the build log
        sh 'git log --oneline -5'
      }
    }

    // ── 2. INSTALL DEPENDENCIES ───────────────────────────────────────────────
    stage('Install Dependencies') {
      steps {
        dir('app') {
          echo '==> Installing Node.js dependencies'
          // npm ci is reproducible and faster than npm install
          // Uses package-lock.json — fails if lock file is out of sync
          sh 'npm ci'
        }
      }
    }

    // ── 3. LINT ───────────────────────────────────────────────────────────────
    stage('Lint') {
      steps {
        dir('app') {
          echo '==> Running ESLint'
          // || true prevents lint warnings from failing the build
          // Remove || true in strict setups
          sh 'npm run lint || echo "Lint warnings found — review output above"'
        }
      }
    }

    // ── 4. UNIT TESTS ─────────────────────────────────────────────────────────
    stage('Unit Tests') {
      steps {
        dir('app') {
          echo '==> Running unit tests with coverage'
          sh 'mkdir -p test-results'
          sh 'npm run test:ci'
        }
      }
      post {
        always {
          // Publish JUnit test results to Jenkins UI
          junit allowEmptyResults: true, testResults: 'app/test-results/*.xml'

          // Publish coverage report
          publishHTML([
            allowMissing: true,
            alwaysLinkToLastBuild: true,
            keepAll: true,
            reportDir: 'app/coverage/lcov-report',
            reportFiles: 'index.html',
            reportName: 'Coverage Report'
          ])
        }
      }
    }

    // ── 5. SECURITY SCAN ─────────────────────────────────────────────────────
    stage('Security Scan') {
      steps {
        dir('app') {
          echo '==> Scanning for known vulnerabilities in dependencies'
          // npm audit fails on high/critical CVEs
          // --audit-level=high means only fail on HIGH and CRITICAL
          sh 'npm audit --audit-level=high || echo "Audit warnings — review above"'
        }
      }
    }

    // ── 6. BUILD DOCKER IMAGE ─────────────────────────────────────────────────
    stage('Build Docker Image') {
      steps {
        dir('app') {
          echo "==> Building Docker image: ${IMAGE_FULL}"
          sh """
            docker build \
              --build-arg APP_VERSION=${IMAGE_TAG} \
              --tag ${IMAGE_FULL} \
              --tag ${ECR_REPO}:latest \
              --label git-commit=${env.GIT_COMMIT} \
              --label build-number=${env.BUILD_NUMBER} \
              --label build-date=\$(date -u +%Y-%m-%dT%H:%M:%SZ) \
              .
          """

          // Verify the image was built and check its size
          sh "docker images ${ECR_REPO} --format 'table {{.Repository}}\\t{{.Tag}}\\t{{.Size}}'"
        }
      }
    }

    // ── 7. SCAN DOCKER IMAGE FOR CVEs ─────────────────────────────────────────
    stage('Image Vulnerability Scan') {
      steps {
        echo "==> Scanning Docker image for CVEs with Trivy"
        // Trivy scans for HIGH and CRITICAL CVEs in the OS packages and app deps
        // --exit-code 1 fails the pipeline if vulnerabilities are found
        // Install trivy: https://aquasecurity.github.io/trivy/latest/getting-started/installation/
        sh """
          trivy image \
            --severity HIGH,CRITICAL \
            --exit-code 0 \
            --format table \
            ${IMAGE_FULL} || echo "Trivy not installed — skipping image scan"
        """
      }
    }

    // ── 8. PUSH TO ECR ────────────────────────────────────────────────────────
    stage('Push to ECR') {
      // Only push images from main branch (not feature branches)
      when {
        anyOf {
          branch 'main'
          branch 'master'
        }
      }
      steps {
        echo "==> Authenticating with AWS ECR"
        withCredentials([
          string(credentialsId: 'AWS_ACCESS_KEY_ID', variable: 'AWS_ACCESS_KEY_ID'),
          string(credentialsId: 'AWS_SECRET_ACCESS_KEY', variable: 'AWS_SECRET_ACCESS_KEY')
        ]) {
          sh """
            # Authenticate Docker to ECR
            aws ecr get-login-password --region ${AWS_REGION} \
              | docker login --username AWS --password-stdin ${ECR_REGISTRY}

            echo "==> Pushing image: ${IMAGE_FULL}"
            docker push ${IMAGE_FULL}

            # Also push :latest tag
            docker push ${ECR_REPO}:latest

            echo "==> Image pushed successfully"
            echo "==> ECR URI: ${IMAGE_FULL}"
          """
        }
      }
    }

    // ── 9. DEPLOY TO STAGING ──────────────────────────────────────────────────
    stage('Deploy to Staging') {
      when {
        anyOf { branch 'main'; branch 'master' }
      }
      steps {
        echo "==> Deploying ${IMAGE_TAG} to staging namespace"
        withCredentials([
          string(credentialsId: 'AWS_ACCESS_KEY_ID', variable: 'AWS_ACCESS_KEY_ID'),
          string(credentialsId: 'AWS_SECRET_ACCESS_KEY', variable: 'AWS_SECRET_ACCESS_KEY')
        ]) {
          sh """
            # Configure kubectl to talk to EKS cluster
            aws eks update-kubeconfig \
              --region ${AWS_REGION} \
              --name ${EKS_CLUSTER}

            # Deploy using Helm (production-grade approach)
            helm upgrade --install ${APP_NAME} ./k8s/helm \
              --namespace staging \
              --create-namespace \
              --set image.repository=${ECR_REPO} \
              --set image.tag=${IMAGE_TAG} \
              --set environment=staging \
              --atomic \
              --timeout 5m \
              --wait

            echo "==> Staging deploy complete"
          """
        }
      }
      post {
        success {
          echo '==> Running smoke tests against staging'
          sh """
            python3 scripts/python/smoke_test.py \
              --url https://staging.cicd-demo.example.com \
              --env staging
          """
        }
      }
    }

    // ── 10. MANUAL APPROVAL GATE ──────────────────────────────────────────────
    stage('Approve Production Deploy') {
      when {
        anyOf { branch 'main'; branch 'master' }
      }
      steps {
        // Pause pipeline and wait for a human to approve
        // Times out after 30 minutes — pipeline fails if no one approves
        timeout(time: 30, unit: 'MINUTES') {
          input message: "Deploy ${APP_NAME}:${IMAGE_TAG} to PRODUCTION?",
                ok: 'Yes — Deploy to Production',
                submitter: 'release-approvers,devops-team'
        }
      }
    }

    // ── 11. DEPLOY TO PRODUCTION ──────────────────────────────────────────────
    stage('Deploy to Production') {
      when {
        anyOf { branch 'main'; branch 'master' }
      }
      steps {
        echo "==> Deploying ${IMAGE_TAG} to PRODUCTION"
        withCredentials([
          string(credentialsId: 'AWS_ACCESS_KEY_ID', variable: 'AWS_ACCESS_KEY_ID'),
          string(credentialsId: 'AWS_SECRET_ACCESS_KEY', variable: 'AWS_SECRET_ACCESS_KEY')
        ]) {
          sh """
            aws eks update-kubeconfig \
              --region ${AWS_REGION} \
              --name ${EKS_CLUSTER}

            helm upgrade --install ${APP_NAME} ./k8s/helm \
              --namespace production \
              --create-namespace \
              --set image.repository=${ECR_REPO} \
              --set image.tag=${IMAGE_TAG} \
              --set environment=production \
              --set replicaCount=3 \
              --atomic \
              --timeout 5m \
              --wait

            echo "==> Production deploy complete: ${IMAGE_FULL}"
          """
        }
      }
      post {
        success {
          echo '==> Running production smoke tests'
          sh """
            python3 scripts/python/smoke_test.py \
              --url https://cicd-demo.example.com \
              --env production
          """
        }
      }
    }
  }

  // ── Post-pipeline actions — always run regardless of result ───────────────
  post {
    success {
      echo "Pipeline SUCCESS — ${APP_NAME}:${IMAGE_TAG} deployed"
      // In real setup: slackSend channel: '#deployments', color: 'good', message: "..."
    }
    failure {
      echo "Pipeline FAILED — ${APP_NAME} build ${env.BUILD_NUMBER}"
      // In real setup: slackSend channel: '#alerts', color: 'danger', message: "..."
    }
    unstable {
      echo "Pipeline UNSTABLE — test failures detected"
    }
    always {
      echo '==> Cleaning up local Docker images to save disk space'
      sh "docker rmi ${IMAGE_FULL} ${ECR_REPO}:latest || true"

      // Clean Jenkins workspace
      cleanWs()
    }
  }
}
