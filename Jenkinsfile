pipeline {
  agent {
    kubernetes {
      label "ci-${env.BUILD_NUMBER}"
      defaultContainer 'jnlp'
      yaml """
apiVersion: v1
kind: Pod
spec:
  restartPolicy: Never
  serviceAccountName: jenkins
  volumes:
  - name: kaniko-docker-config
    emptyDir: {}
  containers:
  - name: git
    image: alpine/git:2.45.2
    command: ["/bin/sh","-c"]
    args: ["sleep 3600"]
    tty: true
  - name: awscli
    image: amazon/aws-cli:2.15.57
    command: ["/bin/sh","-c"]
    args: ["sleep 3600"]
    tty: true
    volumeMounts:
    - name: kaniko-docker-config
      mountPath: /kaniko/.docker
  - name: kaniko
    image: gcr.io/kaniko-project/executor:v1.23.2
    command: ["/busybox/sh","-c"]
    args: ["sleep 3600"]
    tty: true
    volumeMounts:
    - name: kaniko-docker-config
      mountPath: /kaniko/.docker
  - name: kubectl
    image: bitnami/kubectl:1.30.4
    command: ["/bin/sh","-c"]
    args: ["sleep 3600"]
    tty: true
"""
    }
  }

  options { timestamps() }

  environment {
    // You can also define these in the Jenkins job config instead of here.
    // AWS_REGION = "eu-west-1"
    // ECR_REPO = "ecr-foundation"
    // K8S_DEPLOYMENT_NAMESPACE = "jenkins"
    // K8S_DEPLOYMENT_NAME = "demo-app"
    // K8S_CONTAINER_NAME = "app"
  }

  stages {
    stage('Checkout') {
      steps {
        container('git') {
          sh '''
            set -euo pipefail
            rm -rf src
            git clone --depth 1 "$GIT_URL" src
            cd src
            git rev-parse --short HEAD > ../.gitsha
          '''
        }
        script {
          env.GIT_SHA = sh(script: "cat .gitsha", returnStdout: true).trim()
          echo "GIT_SHA=${env.GIT_SHA}"
        }
      }
    }

    stage('Prepare ECR auth (for Kaniko)') {
      steps {
        container('awscli') {
          sh '''
            set -euo pipefail
            : "${AWS_REGION:?AWS_REGION missing}"
            : "${ECR_REPO:?ECR_REPO missing}"

            ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
            ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
            echo "${ECR_REGISTRY}" > .ecr_registry

            TOKEN=$(aws ecr get-login-password --region "${AWS_REGION}")
            AUTH=$(printf "AWS:%s" "${TOKEN}" | base64 | tr -d '\n')

            cat > /kaniko/.docker/config.json <<EOF
            {
              "auths": {
                "${ECR_REGISTRY}": { "auth": "${AUTH}" }
              }
            }
EOF
            echo "Prepared Kaniko docker config for ${ECR_REGISTRY}"
          '''
        }
      }
    }

    stage('Build & Push (Kaniko)') {
      steps {
        container('kaniko') {
          script {
            def registry = sh(script: "cat .ecr_registry", returnStdout: true).trim()
            if (!registry) { error("Missing .ecr_registry") }

            def imageRepo = "${registry}/${env.ECR_REPO}"
            def tagSha = "${env.GIT_SHA}"

            sh """
              set -euo pipefail
              /kaniko/executor \
                --context=dir://src \
                --dockerfile=src/Dockerfile \
                --destination=${imageRepo}:${tagSha} \
                --destination=${imageRepo}:latest \
                --cache=true
            """

            env.IMAGE_URI = "${imageRepo}:${tagSha}"
            echo "Pushed: ${env.IMAGE_URI}"
          }
        }
      }
    }

    stage('Deploy (kubectl set image)') {
      steps {
        container('kubectl') {
          sh '''
            set -euo pipefail
            : "${K8S_DEPLOYMENT_NAMESPACE:?K8S_DEPLOYMENT_NAMESPACE missing}"
            : "${K8S_DEPLOYMENT_NAME:?K8S_DEPLOYMENT_NAME missing}"
            : "${K8S_CONTAINER_NAME:?K8S_CONTAINER_NAME missing}"

            kubectl -n "${K8S_DEPLOYMENT_NAMESPACE}" set image deployment/"${K8S_DEPLOYMENT_NAME}" \
              "${K8S_CONTAINER_NAME}"="${IMAGE_URI}"

            kubectl -n "${K8S_DEPLOYMENT_NAMESPACE}" rollout status deployment/"${K8S_DEPLOYMENT_NAME}" --timeout=5m
          '''
        }
      }
    }
  }
}
