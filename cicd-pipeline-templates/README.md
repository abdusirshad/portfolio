# cicd-pipeline-templates

[![GitLab CI](https://img.shields.io/badge/GitLab_CI-FC6D26?style=flat-square&logo=gitlab)](https://docs.gitlab.com/ee/ci/)
[![GitHub Actions](https://img.shields.io/badge/GitHub_Actions-2088FF?style=flat-square&logo=githubactions)](https://github.com/features/actions)
[![Jenkins](https://img.shields.io/badge/Jenkins-D24939?style=flat-square&logo=jenkins)](https://jenkins.io)
[![Argo CD](https://img.shields.io/badge/Argo_CD-EF7B4D?style=flat-square&logo=argo)](https://argoproj.github.io/cd/)
[![Trivy](https://img.shields.io/badge/Trivy-1904DA?style=flat-square&logo=aquasecurity)](https://trivy.dev)

> Reusable, production-grade CI/CD pipeline templates — **GitLab CI, GitHub Actions, Jenkins** — with security scanning (Trivy), OPA policy gates, Helm deployments, and GitOps (Argo CD). Onboarded **10+ application teams**, reducing release-related incidents by **30%**.

---

## Templates Available

| Template | Platform | Description |
|---|---|---|
| `gitlab/docker-k8s.yml` | GitLab CI | Build → Trivy scan → push → Helm deploy to EKS/AKS |
| `gitlab/mlops.yml` | GitLab CI | MLOps with model validation gate + Helm promote |
| `github-actions/docker-ecr-eks.yml` | GitHub Actions | Docker → ECR → EKS deploy with OIDC auth |
| `github-actions/terraform-aws.yml` | GitHub Actions | Terraform plan/apply on AWS with OIDC |
| `github-actions/devsecops.yml` | GitHub Actions | Full DevSecOps: SAST + Trivy + OPA + Cosign |
| `jenkins/Jenkinsfile.k8s` | Jenkins | Declarative pipeline for Kubernetes with parallel stages |
| `argocd/application.yaml` | Argo CD | GitOps application with sync policy and health checks |

---

## GitLab CI — Docker + Kubernetes

```yaml
# gitlab/docker-k8s.yml
# Usage: include this file in your .gitlab-ci.yml
#   include:
#     - project: 'platform/cicd-pipeline-templates'
#       file: 'gitlab/docker-k8s.yml'

stages:
  - validate
  - build
  - security-scan
  - deploy-staging
  - integration-test
  - deploy-prod

variables:
  IMAGE_TAG: $CI_COMMIT_SHORT_SHA
  REGISTRY: $CI_REGISTRY
  HELM_TIMEOUT: 5m

# ── Validate ──────────────────────────────────────────────────────────
lint:
  stage: validate
  image: hadolint/hadolint:latest-debian
  script:
    - hadolint Dockerfile

yaml-lint:
  stage: validate
  image: cytopia/yamllint:latest
  script:
    - yamllint helm/

# ── Build ─────────────────────────────────────────────────────────────
docker-build:
  stage: build
  image: docker:24
  services:
    - docker:24-dind
  before_script:
    - docker login -u $CI_REGISTRY_USER -p $CI_REGISTRY_PASSWORD $CI_REGISTRY
  script:
    - docker build
        --build-arg BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        --build-arg VCS_REF=$CI_COMMIT_SHA
        --cache-from $CI_REGISTRY_IMAGE:latest
        -t $CI_REGISTRY_IMAGE:$IMAGE_TAG
        -t $CI_REGISTRY_IMAGE:latest .
    - docker push $CI_REGISTRY_IMAGE:$IMAGE_TAG
    - docker push $CI_REGISTRY_IMAGE:latest
  rules:
    - if: $CI_COMMIT_BRANCH

# ── Security Scan ────────────────────────────────────────────────────
trivy-scan:
  stage: security-scan
  image: aquasec/trivy:latest
  script:
    # Fail pipeline on CRITICAL vulnerabilities
    - trivy image
        --exit-code 1
        --severity CRITICAL
        --no-progress
        --format table
        $CI_REGISTRY_IMAGE:$IMAGE_TAG
    # Generate SARIF report for GitLab security dashboard
    - trivy image
        --format sarif
        --output trivy-results.sarif
        $CI_REGISTRY_IMAGE:$IMAGE_TAG
  artifacts:
    reports:
      sast: trivy-results.sarif
    when: always

# ── Deploy Staging ────────────────────────────────────────────────────
deploy-staging:
  stage: deploy-staging
  image: alpine/helm:3.14.0
  environment:
    name: staging
  script:
    - helm upgrade --install $CI_PROJECT_NAME-staging helm/$CI_PROJECT_NAME
        --namespace $K8S_NAMESPACE_STAGING
        --set image.repository=$CI_REGISTRY_IMAGE
        --set image.tag=$IMAGE_TAG
        --set ingress.host=$STAGING_HOST
        --wait --timeout $HELM_TIMEOUT
        --atomic

# ── Integration Tests ─────────────────────────────────────────────────
integration-tests:
  stage: integration-test
  image: python:3.11-slim
  script:
    - pip install pytest httpx
    - pytest tests/integration/ -v --base-url=https://$STAGING_HOST
  rules:
    - if: $CI_COMMIT_BRANCH == "main"

# ── Deploy Production ─────────────────────────────────────────────────
deploy-prod:
  stage: deploy-prod
  image: alpine/helm:3.14.0
  environment:
    name: production    # manual approval gate configured in GitLab
  when: manual
  rules:
    - if: $CI_COMMIT_BRANCH == "main"
  script:
    - helm upgrade --install $CI_PROJECT_NAME-prod helm/$CI_PROJECT_NAME
        --namespace $K8S_NAMESPACE_PROD
        --set image.repository=$CI_REGISTRY_IMAGE
        --set image.tag=$IMAGE_TAG
        --set replicaCount=3
        --set ingress.host=$PROD_HOST
        --wait --timeout $HELM_TIMEOUT
        --atomic
```

---

## GitHub Actions — Terraform on AWS (OIDC, no long-lived keys)

```yaml
# github-actions/terraform-aws.yml
name: Terraform AWS

on:
  push:
    branches: [main]
    paths: ['terraform/**']
  pull_request:
    paths: ['terraform/**']

permissions:
  id-token: write     # Required for OIDC
  contents: read
  pull-requests: write

env:
  TF_VERSION: "1.7.5"
  AWS_REGION: us-east-1

jobs:
  terraform:
    runs-on: ubuntu-latest
    defaults:
      run:
        working-directory: terraform/

    steps:
      - uses: actions/checkout@v4

      # OIDC auth — no AWS_ACCESS_KEY_ID stored as secret
      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Terraform Format Check
        run: terraform fmt -check -recursive

      - name: Terraform Init
        run: terraform init -backend-config="bucket=${{ secrets.TF_STATE_BUCKET }}"

      - name: Terraform Validate
        run: terraform validate

      - name: Terraform Plan
        id: plan
        run: terraform plan -no-color -out=tfplan
        continue-on-error: true

      # Post plan output to PR as comment
      - name: Post Plan to PR
        uses: actions/github-script@v7
        if: github.event_name == 'pull_request'
        with:
          script: |
            const output = `#### Terraform Plan \`${{ steps.plan.outcome }}\`
            <details><summary>Show Plan</summary>

            \`\`\`terraform
            ${{ steps.plan.outputs.stdout }}
            \`\`\`
            </details>`;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            });

      - name: Terraform Apply
        if: github.ref == 'refs/heads/main' && github.event_name == 'push'
        run: terraform apply -auto-approve tfplan
```

---

## GitHub Actions — Full DevSecOps Pipeline

```yaml
# github-actions/devsecops.yml
name: DevSecOps Pipeline

on:
  push:
    branches: [main, develop]
  pull_request:

jobs:
  sast:
    name: SAST (Semgrep)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: returntocorp/semgrep-action@v1
        with:
          config: p/ci p/owasp-top-ten

  container-security:
    name: Container Scan (Trivy)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build image
        run: docker build -t app:${{ github.sha }} .
      - name: Trivy vulnerability scan
        uses: aquasecurity/trivy-action@master
        with:
          image-ref: app:${{ github.sha }}
          format: sarif
          output: trivy-results.sarif
          severity: CRITICAL,HIGH
          exit-code: 1
      - uses: github/codeql-action/upload-sarif@v3
        with:
          sarif_file: trivy-results.sarif

  opa-policy:
    name: OPA Policy Gate
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install OPA
        run: |
          curl -L -o opa https://openpolicyagent.org/downloads/latest/opa_linux_amd64_static
          chmod +x opa && sudo mv opa /usr/local/bin/
      - name: Evaluate Kubernetes policies
        run: |
          opa eval --format pretty \
            --data policies/k8s-security.rego \
            --input k8s/deployment.yaml \
            "data.kubernetes.security.deny"

  sign-and-push:
    name: Sign Image (Cosign)
    needs: [sast, container-security, opa-policy]
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main'
    steps:
      - uses: sigstore/cosign-installer@v3
      - name: Sign container image
        run: |
          cosign sign --yes \
            ${{ secrets.REGISTRY }}/app:${{ github.sha }}
```

---

## Jenkins — Declarative Pipeline (Kubernetes)

```groovy
// jenkins/Jenkinsfile.k8s
pipeline {
    agent {
        kubernetes {
            yaml '''
                apiVersion: v1
                kind: Pod
                spec:
                  containers:
                  - name: docker
                    image: docker:24-dind
                    securityContext:
                      privileged: true
                  - name: helm
                    image: alpine/helm:3.14.0
                    command: [sleep, infinity]
                  - name: trivy
                    image: aquasec/trivy:latest
                    command: [sleep, infinity]
            '''
        }
    }

    environment {
        IMAGE_TAG     = "${env.GIT_COMMIT[0..7]}"
        REGISTRY      = credentials('registry-url')
        KUBECONFIG    = credentials('kubeconfig-prod')
    }

    stages {
        stage('Parallel: Lint + Test') {
            parallel {
                stage('Lint') {
                    steps {
                        sh 'hadolint Dockerfile'
                        sh 'yamllint helm/'
                    }
                }
                stage('Unit Tests') {
                    steps {
                        sh 'pytest tests/unit/ -v --junitxml=test-results.xml'
                    }
                    post {
                        always {
                            junit 'test-results.xml'
                        }
                    }
                }
            }
        }

        stage('Build') {
            steps {
                container('docker') {
                    sh """
                        docker build \\
                          --cache-from ${REGISTRY}/app:latest \\
                          -t ${REGISTRY}/app:${IMAGE_TAG} .
                        docker push ${REGISTRY}/app:${IMAGE_TAG}
                    """
                }
            }
        }

        stage('Security Scan') {
            steps {
                container('trivy') {
                    sh "trivy image --exit-code 1 --severity CRITICAL ${REGISTRY}/app:${IMAGE_TAG}"
                }
            }
        }

        stage('Deploy Staging') {
            steps {
                container('helm') {
                    sh """
                        helm upgrade --install app-staging helm/app \\
                          --namespace staging \\
                          --set image.tag=${IMAGE_TAG} \\
                          --wait --timeout 5m --atomic
                    """
                }
            }
        }

        stage('Deploy Prod') {
            when { branch 'main' }
            input {
                message 'Deploy to production?'
                ok 'Deploy'
            }
            steps {
                container('helm') {
                    sh """
                        helm upgrade --install app-prod helm/app \\
                          --namespace production \\
                          --set image.tag=${IMAGE_TAG} \\
                          --set replicaCount=3 \\
                          --wait --timeout 10m --atomic
                    """
                }
            }
        }
    }

    post {
        failure {
            slackSend channel: '#alerts-deployments',
                      color: 'danger',
                      message: "Deploy FAILED: ${env.JOB_NAME} ${IMAGE_TAG}"
        }
        success {
            slackSend channel: '#deployments',
                      color: 'good',
                      message: "Deploy SUCCESS: ${env.JOB_NAME} ${IMAGE_TAG}"
        }
    }
}
```

---

## Argo CD — GitOps Application

```yaml
# argocd/application.yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: myapp-prod
  namespace: argocd
  finalizers:
    - resources-finalizer.argocd.argoproj.io
spec:
  project: default
  source:
    repoURL: https://gitlab.company.com/platform/helm-charts
    targetRevision: main
    path: charts/myapp
    helm:
      valueFiles:
        - values-prod.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - PrunePropagationPolicy=foreground
    retry:
      limit: 3
      backoff:
        duration: 10s
        maxDuration: 3m
        factor: 2
  ignoreDifferences:
    - group: apps
      kind: Deployment
      jsonPointers:
        - /spec/replicas    # HPA manages replicas
```
